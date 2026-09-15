import { ITEM_KINDS, isDateKey, isDateTime } from "../util.js";

const ITEM_STATUSES = ["open", "done", "cancelled", "resolved", "abandoned"];
const THREAD_STATUSES = ["active", "waiting", "paused", "completed"];

export class ToolError extends Error {
  constructor(message, details = null) {
    super(message);
    this.name = "ToolError";
    this.details = details;
  }
}

function requireArg(args, name, { max = 4000 } = {}) {
  const value = args?.[name];
  if (value === undefined || value === null || String(value).trim() === "") {
    throw new ToolError(`缺少参数 ${name}`);
  }
  if (String(value).length > max) throw new ToolError(`参数 ${name} 过长（上限 ${max} 字符）`);
  return String(value).trim();
}

function optionalArg(args, name, { max = 4000 } = {}) {
  const value = args?.[name];
  if (value === undefined || value === null) return null;
  const text = String(value);
  if (text.length > max) throw new ToolError(`参数 ${name} 过长（上限 ${max} 字符）`);
  return text;
}

function optionalDate(value, field) {
  if (value === undefined || value === null || value === "") return undefined;
  if (!isDateKey(String(value))) throw new ToolError(`${field} 需要是 YYYY-MM-DD 日期，收到：${value}`);
  return String(value);
}

function optionalIso(value, field) {
  if (value === undefined || value === null || value === "") return undefined;
  if (!isDateTime(String(value))) throw new ToolError(`${field} 需要是带时区的 ISO 时间，收到：${value}`);
  return new Date(String(value)).toISOString();
}

function optionalArray(value, field, max) {
  if (value === undefined || value === null) return undefined;
  if (!Array.isArray(value)) throw new ToolError(`${field} 需要是数组`);
  if (value.length > max) throw new ToolError(`${field} 一次最多 ${max} 条`);
  return value;
}

/** MCP 条目 → 仓库层字段。只转换明确给出的字段，未给出的保持原值。 */
function toRepoEntry(entry, { requireKind }) {
  if (!entry || typeof entry !== "object" || Array.isArray(entry)) {
    throw new ToolError("entries 里每一项都需要是对象");
  }
  const id = entry.id === undefined ? undefined : requireArg(entry, "id", { max: 64 });
  const kind = entry.kind === undefined ? undefined : requireArg(entry, "kind", { max: 20 });
  if (requireKind && !kind) throw new ToolError("新条目必须带 kind：task / event / direction / wait");
  if (kind !== undefined && !ITEM_KINDS.includes(kind)) {
    throw new ToolError(`kind 需要是 ${ITEM_KINDS.join(" / ")}，收到：${kind}`);
  }
  const status = entry.status === undefined ? undefined : String(entry.status);
  if (status !== undefined && !ITEM_STATUSES.includes(status)) {
    throw new ToolError(`status 需要是 ${ITEM_STATUSES.join(" / ")}，收到：${status}`);
  }
  const payload = {
    id,
    kind,
    status,
    title: entry.title === undefined ? undefined : requireArg(entry, "title", { max: 500 }),
    detail: entry.detail === undefined ? undefined : optionalArg(entry, "detail", { max: 8000 }),
    planDate: optionalDate(entry.plan_date, "plan_date"),
    dueDate: optionalDate(entry.due_date, "due_date"),
    startAt: optionalIso(entry.start_at, "start_at"),
    endAt: optionalIso(entry.end_at, "end_at"),
    followUpDate: optionalDate(entry.follow_up_date, "follow_up_date"),
    blocked: entry.blocked === undefined ? undefined : Boolean(entry.blocked),
    blockerReason: entry.blocker_reason === undefined ? undefined : optionalArg(entry, "blocker_reason", { max: 2000 }),
  };
  for (const key of Object.keys(payload)) {
    if (payload[key] === undefined) delete payload[key];
  }
  // detail / blocker_reason 允许显式清空
  if (entry.detail === "") payload.detail = "";
  if (entry.blocker_reason === "") payload.blockerReason = "";
  if (Object.keys(payload).length === 0) throw new ToolError("条目里没有可写入的字段");
  return payload;
}

function summarizeThread(thread) {
  const counts = thread.counts ?? null;
  const openItems = counts
    ? counts.open_tasks + counts.open_events + counts.open_directions + counts.open_waits
    : undefined;
  return {
    thread_id: thread.id,
    title: thread.title,
    domain_id: thread.domain_id,
    status: thread.status,
    is_inbox: thread.is_inbox,
    summary: thread.summary,
    revision: thread.revision,
    open_items: openItems,
    counts,
    pinned: Boolean(thread.pinned_at),
    archived: thread.archived,
    trashed: Boolean(thread.trashed_at),
    updated_at: thread.updated_at,
  };
}

function summarizeEntry(item) {
  return {
    id: item.id,
    kind: item.kind,
    title: item.title,
    status: item.status,
    detail: item.detail,
    plan_date: item.plan_date,
    due_date: item.due_date,
    start_at: item.start_at,
    end_at: item.end_at,
    follow_up_date: item.follow_up_date,
    blocked: item.blocked,
    blocker_reason: item.blocker_reason,
    source_id: item.source_id,
    thread_id: item.thread_id,
    updated_at: item.updated_at,
  };
}

function threadContext(bundle, { logLimit = 20 } = {}) {
  return {
    thread: summarizeThread(bundle.thread),
    entries: bundle.items.open.map(summarizeEntry),
    closed_entries: bundle.items.closed.slice(0, 30).map(summarizeEntry),
    closed_count: bundle.items.closed.length,
    note: bundle.note.content,
    logs: bundle.logs.slice(0, logLimit).map((log) => ({
      at: log.created_at,
      kind: log.kind,
      text: log.text,
      actor: log.actor,
    })),
  };
}

const ENTRY_SCHEMA = {
  type: "object",
  additionalProperties: false,
  properties: {
    id: { type: "string", description: "稳定 id：更新已有条目时复用原 id，新建时自己生成（3–64 位字母数字下划线连字符）" },
    kind: { type: "string", enum: ITEM_KINDS, description: "task 待办 / event 固定日程 / direction 探索方向 / wait 等待" },
    title: { type: "string", description: "简短、独立可懂，不必依赖上下文" },
    status: { type: "string", enum: ITEM_STATUSES, description: "open 未结束 / done 已完成 / resolved 等待已解除 / cancelled 已取消 / abandoned 方向已放弃" },
    detail: { type: "string", description: "可选说明或判断依据；传空字符串可清空" },
    plan_date: { type: "string", description: "计划执行日 YYYY-MM-DD（过期显示为待重新安排）" },
    due_date: { type: "string", description: "截止日 YYYY-MM-DD（过期才是逾期）" },
    start_at: { type: "string", description: "固定日程开始时间，带时区的 ISO 时间" },
    end_at: { type: "string", description: "固定日程结束时间，可选" },
    follow_up_date: { type: "string", description: "等待的跟进日 YYYY-MM-DD" },
    blocked: { type: "boolean", description: "待办是否被卡住（与「等待外部结果」不同）" },
    blocker_reason: { type: "string", description: "卡在哪里" },
  },
};

export function createTools({ repo, views }) {
  function findThreadByTitle(title, domainId) {
    const needle = title.trim().toLowerCase();
    return (
      repo
        .listThreads({ include: "active", domainId: domainId ?? null })
        .find((thread) => thread.title.trim().toLowerCase() === needle) ?? null
    );
  }

  function findDomainByTitle(name) {
    const needle = name.trim().toLowerCase();
    return repo.listDomains({ includeArchived: true }).find((domain) => domain.name.trim().toLowerCase() === needle) ?? null;
  }

  function inboxOf(domainId) {
    return repo.listThreads({ include: "active", domainId }).find((thread) => thread.is_inbox) ?? null;
  }

  function resolveDomain(value) {
    if (!value) return null;
    const byId = repo.listDomains({ includeArchived: true }).find((domain) => domain.id === value);
    return byId ?? findDomainByTitle(String(value));
  }

  return [
    {
      name: "list_domains",
      title: "列出关注范围",
      description: "列出所有 Domain（工作、生活、学习…），每个 Domain 都带一条承担临时收纳职责的收件箱 Thread。",
      inputSchema: { type: "object", additionalProperties: false, properties: {} },
      annotations: { readOnlyHint: true, openWorldHint: false },
      handler: () => ({
        domains: repo.listDomains({ includeArchived: true }).map((domain) => {
          const inbox = inboxOf(domain.id);
          return {
            domain_id: domain.id,
            name: domain.name,
            archived: domain.archived,
            inbox_thread_id: inbox?.id ?? null,
            thread_count: repo.listThreads({ include: "active", domainId: domain.id }).length,
          };
        }),
      }),
    },

    {
      name: "list_threads",
      title: "查找线索",
      description:
        "按关键词、Domain、状态查找 Thread。返回分页结果与总数；需要完整上下文时再用 get_thread。不要用返回结果的第一条来代替明确的解析。",
      inputSchema: {
        type: "object",
        additionalProperties: false,
        properties: {
          query: { type: "string", description: "在标题与当前描述里搜索关键词" },
          domain: { type: "string", description: "Domain 名称或 id，限定范围" },
          status: { type: "string", enum: THREAD_STATUSES, description: "Thread 整体状态" },
          include: { type: "string", enum: ["active", "archived", "trashed", "all"], description: "默认 active（日常视野）" },
          limit: { type: "number", description: "默认 20，最多 100" },
          offset: { type: "number", description: "默认 0" },
        },
      },
      annotations: { readOnlyHint: true, openWorldHint: false },
      handler: (args) => {
        const domain = resolveDomain(optionalArg(args, "domain"));
        if (optionalArg(args, "domain") && !domain) {
          throw new ToolError(`找不到 Domain：${args.domain}`);
        }
        const limit = Math.min(Math.max(Number(args?.limit ?? 20) || 20, 1), 100);
        const offset = Math.max(Number(args?.offset ?? 0) || 0, 0);
        const all = repo.listThreads({
          include: optionalArg(args, "include") ?? "active",
          status: optionalArg(args, "status"),
          domainId: domain?.id ?? null,
          search: optionalArg(args, "query"),
        });
        const slice = all.slice(offset, offset + limit);
        return {
          total: all.length,
          has_more: offset + slice.length < all.length,
          next_offset: offset + slice.length < all.length ? offset + slice.length : null,
          threads: slice.map((thread) => ({
            ...summarizeThread(thread),
            domain_name: repo.listDomains({ includeArchived: true }).find((item) => item.id === thread.domain_id)?.name ?? null,
          })),
        };
      },
    },

    {
      name: "resolve_thread",
      title: "解析线索 / 收件箱",
      description:
        "把用户口中的主题解析成确切的 Thread。顺序：该 Domain 下同名 Thread → 同名 Domain 的收件箱 →（允许时）新建同名 Domain 并返回其收件箱。用户只说主题时用它，不要从 list_threads 里挑第一条。",
      inputSchema: {
        type: "object",
        additionalProperties: false,
        required: ["topic"],
        properties: {
          topic: { type: "string", description: "用户提到的主题，例如「装修」「厨房方案」" },
          domain: { type: "string", description: "已知的 Domain 名称或 id，可缩小解析范围" },
          create_if_missing: { type: "boolean", description: "默认 true：找不到时新建 Domain 与其收件箱" },
          thread_title: { type: "string", description: "已知的具体线索名，例如「选材」；只在指定 Domain 下查找或新建" },
        },
      },
      annotations: { readOnlyHint: false, idempotentHint: true, openWorldHint: false },
      handler: (args) => {
        const topic = requireArg(args, "topic", { max: 200 });
        const domainHint = optionalArg(args, "domain");
        const threadTitle = optionalArg(args, "thread_title");
        const createIfMissing = args?.create_if_missing !== false;
        const domain = resolveDomain(domainHint);
        if (domainHint && !domain) throw new ToolError(`找不到 Domain：${domainHint}`);

        if (threadTitle) {
          const existing = findThreadByTitle(threadTitle, domain?.id ?? null);
          if (existing) {
            return { matched_by: "thread_title", created: false, ...threadContext(repo.threadBundle(existing.id)) };
          }
          if (!createIfMissing) return { matched_by: null, created: false, thread: null };
          let target = domain;
          if (!target) {
            const byTopic = findDomainByTitle(topic);
            target = byTopic ?? repo.createDomain({ name: topic });
          }
          const created = repo.createThread({ domainId: target.id, title: threadTitle });
          return { matched_by: "created", created: true, ...threadContext(repo.threadBundle(created.id)) };
        }

        const directThread = findThreadByTitle(topic, domain?.id ?? null);
        if (directThread) {
          return { matched_by: "thread", created: false, ...threadContext(repo.threadBundle(directThread.id)) };
        }

        const topicDomain = domain ?? findDomainByTitle(topic);
        if (topicDomain) {
          const inbox = inboxOf(topicDomain.id);
          if (inbox) {
            return { matched_by: "inbox", created: false, ...threadContext(repo.threadBundle(inbox.id)) };
          }
          if (createIfMissing) {
            const created = repo.createThread({ domainId: topicDomain.id, title: "收件箱", summary: "先收下来，稍后整理归属。", isInbox: true });
            return { matched_by: "created_inbox", created: true, ...threadContext(repo.threadBundle(created.id)) };
          }
        }

        if (!createIfMissing) return { matched_by: null, created: false, thread: null };
        const createdDomain = repo.createDomain({ name: topic });
        const inbox = inboxOf(createdDomain.id);
        return { matched_by: "created_domain", created: true, ...threadContext(repo.threadBundle(inbox.id)) };
      },
    },

    {
      name: "get_thread",
      title: "读取线索上下文",
      description:
        "读取一条 Thread 的完整上下文：当前描述、未结束条目、已结束条目、自由笔记与最近日志，并返回 revision。写入前先读它，并记下 revision。",
      inputSchema: {
        type: "object",
        additionalProperties: false,
        required: ["thread_id"],
        properties: {
          thread_id: { type: "string", description: "Thread id" },
          log_limit: { type: "number", description: "返回的日志条数，默认 20" },
        },
      },
      annotations: { readOnlyHint: true, openWorldHint: false },
      handler: (args) =>
        threadContext(repo.threadBundle(requireArg(args, "thread_id")), {
          logLimit: Math.min(Math.max(Number(args?.log_limit ?? 20) || 20, 0), 200),
        }),
    },

    {
      name: "create_thread",
      title: "新建线索",
      description: "在指定 Domain 下新建一条 Thread。只有在确实需要一条独立线索时使用；临时收录请用 resolve_thread 进收件箱。",
      inputSchema: {
        type: "object",
        additionalProperties: false,
        required: ["title"],
        properties: {
          title: { type: "string", description: "线索标题" },
          domain: { type: "string", description: "Domain 名称或 id；省略时用第一个 Domain" },
          summary: { type: "string", description: "当前描述（可选，一两句话交代现状）" },
        },
      },
      annotations: { readOnlyHint: false, openWorldHint: false },
      handler: (args) => {
        const domainArg = optionalArg(args, "domain");
        const domain = domainArg ? resolveDomain(domainArg) : repo.listDomains()[0];
        if (!domain) throw new ToolError(domainArg ? `找不到 Domain：${domainArg}` : "工作区里还没有 Domain，请先创建一个");
        const thread = repo.createThread({
          domainId: domain.id,
          title: requireArg(args, "title", { max: 200 }),
          summary: optionalArg(args, "summary", { max: 4000 }) ?? "",
        });
        return threadContext(repo.threadBundle(thread.id));
      },
    },

    {
      name: "update_thread",
      title: "更新线索",
      description:
        "更新标题、当前描述、整体状态、归属 Domain、置顶，或归档 / 取消归档。当前描述的修改会在日志里留下前后值。",
      inputSchema: {
        type: "object",
        additionalProperties: false,
        required: ["thread_id"],
        properties: {
          thread_id: { type: "string" },
          title: { type: "string" },
          summary: { type: "string", description: "此刻成立的结论，一两句话；不是清单" },
          status: { type: "string", enum: THREAD_STATUSES, description: "进行中 / 等待中 / 暂停 / 完成" },
          domain: { type: "string", description: "移动到的 Domain 名称或 id" },
          pinned: { type: "boolean", description: "置顶会把它排到线索列表最前，与是否完成无关" },
          archived: { type: "boolean", description: "归档表示暂时移出日常视野，与是否完成无关" },
          expected_revision: { type: "number", description: "可选：读到的 revision，不一致时拒绝写入" },
        },
      },
      annotations: { readOnlyHint: false, idempotentHint: false, openWorldHint: false },
      handler: (args) => {
        const threadId = requireArg(args, "thread_id");
        repo.assertRevision(threadId, args?.expected_revision);
        const patch = {};
        if (args?.title !== undefined) patch.title = requireArg(args, "title", { max: 200 });
        if (args?.summary !== undefined) patch.summary = optionalArg(args, "summary", { max: 4000 }) ?? "";
        if (args?.status !== undefined) {
          const status = String(args.status);
          if (!THREAD_STATUSES.includes(status)) throw new ToolError(`status 需要是 ${THREAD_STATUSES.join(" / ")}`);
          patch.status = status;
        }
        if (args?.domain !== undefined) {
          const domain = resolveDomain(String(args.domain));
          if (!domain) throw new ToolError(`找不到 Domain：${args.domain}`);
          patch.domainId = domain.id;
        }
        if (args?.pinned !== undefined) patch.pinned = Boolean(args.pinned);
        if (args?.archived !== undefined) patch.archived = Boolean(args.archived);
        if (Object.keys(patch).length === 0) throw new ToolError("没有需要更新的字段");
        repo.updateThread(threadId, patch);
        return threadContext(repo.threadBundle(threadId));
      },
    },

    {
      name: "upsert_entries",
      title: "批量写入条目",
      description:
        "一次提交 1–200 条条目（待办 / 固定日程 / 探索方向 / 等待），整批在同一个事务里完成：要么全部成功，要么全部不生效。已存在的 id 会被更新，未给出的字段保持原值，其他条目不受影响。",
      inputSchema: {
        type: "object",
        additionalProperties: false,
        required: ["thread_id", "entries"],
        properties: {
          thread_id: { type: "string" },
          entries: { type: "array", minItems: 1, maxItems: 200, items: ENTRY_SCHEMA },
          order: { type: "array", items: { type: "string" }, description: "可选：给出全部条目 id 以重排顺序" },
          expected_revision: { type: "number", description: "读到的 revision；不一致时返回 409，先重新读取再决定" },
          actor: { type: "string", description: "记录者标识，默认 agent" },
        },
      },
      annotations: { readOnlyHint: false, idempotentHint: false, openWorldHint: false },
      handler: (args) => {
        const threadId = requireArg(args, "thread_id");
        const entries = optionalArray(args?.entries, "entries", 200) ?? [];
        if (entries.length === 0) throw new ToolError("entries 不能为空");
        const mapped = entries.map((entry) => toRepoEntry(entry, { requireKind: !entry.id }));
        const ids = mapped.map((entry) => entry.id).filter(Boolean);
        if (new Set(ids).size !== ids.length) throw new ToolError("entries 里有重复的 id");
        const result = repo.upsertEntries(threadId, mapped, {
          expectedRevision: args?.expected_revision ?? null,
          actor: optionalArg(args, "actor") ?? "agent",
          order: optionalArray(args?.order, "order", 500) ?? null,
        });
        return {
          written: result.entries.map(summarizeEntry),
          revision: result.bundle.thread.revision,
          thread: summarizeThread(result.bundle.thread),
          entries: result.bundle.items.open.map(summarizeEntry),
        };
      },
    },

    {
      name: "update_entry",
      title: "更新单个条目",
      description: "更新一条条目的字段（改标题、改期、完成、解除等待、标记受阻等）。未给出的字段保持原值。",
      inputSchema: {
        type: "object",
        additionalProperties: false,
        required: ["entry_id"],
        properties: {
          entry_id: { type: "string" },
          expected_revision: { type: "number" },
          entry: { ...ENTRY_SCHEMA, description: "要更新的字段" },
        },
      },
      annotations: { readOnlyHint: false, idempotentHint: false, openWorldHint: false },
      handler: (args) => {
        const entryId = requireArg(args, "entry_id");
        const existing = repo.getItemOrThrow(entryId);
        repo.assertRevision(existing.thread_id, args?.expected_revision);
        const patch = toRepoEntry(args?.entry ?? {}, { requireKind: false });
        delete patch.id;
        const item = repo.updateItem(entryId, patch, { actor: "agent" });
        const bundle = repo.threadBundle(existing.thread_id);
        return { entry: summarizeEntry(item), revision: bundle.thread.revision, thread: summarizeThread(bundle.thread) };
      },
    },

    {
      name: "delete_entry",
      title: "删除条目",
      description: "删除一条条目。已结束但仍想保留回顾的条目应保留，不要删除。",
      inputSchema: {
        type: "object",
        additionalProperties: false,
        required: ["entry_id"],
        properties: { entry_id: { type: "string" }, expected_revision: { type: "number" } },
      },
      annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
      handler: (args) => {
        const entryId = requireArg(args, "entry_id");
        const existing = repo.getItemOrThrow(entryId);
        repo.assertRevision(existing.thread_id, args?.expected_revision);
        repo.deleteItem(entryId);
        const bundle = repo.threadBundle(existing.thread_id);
        return { deleted: entryId, revision: bundle.thread.revision };
      },
    },

    {
      name: "move_entry",
      title: "移动条目",
      description: "把一条条目移动到另一条 Thread。保留类型、状态与日期；源与目标 Thread 都会留下日志。",
      inputSchema: {
        type: "object",
        additionalProperties: false,
        required: ["entry_id", "thread_id"],
        properties: { entry_id: { type: "string" }, thread_id: { type: "string" } },
      },
      annotations: { readOnlyHint: false, idempotentHint: false, openWorldHint: false },
      handler: (args) => {
        const entryId = requireArg(args, "entry_id");
        const targetId = requireArg(args, "thread_id");
        const existing = repo.getItemOrThrow(entryId);
        repo.updateItem(entryId, { threadId: targetId }, { actor: "agent" });
        return {
          moved: entryId,
          from: threadContext(repo.threadBundle(existing.thread_id)),
          to: threadContext(repo.threadBundle(targetId)),
        };
      },
    },

    {
      name: "append_log",
      title: "记录日志",
      description:
        "记录已经发生的事情：结果、决策、证据、判断变化。操作类记录（新增、完成、改期）由服务端自动写入，不要重复记录。",
      inputSchema: {
        type: "object",
        additionalProperties: false,
        required: ["thread_id", "text"],
        properties: {
          thread_id: { type: "string" },
          text: { type: "string", description: "发生了什么、判断怎么变了；可以是多段 Markdown" },
          occurred_at: { type: "string", description: "已知发生时间时给出带时区的 ISO 时间" },
          actor: { type: "string", description: "记录者标识，默认 agent" },
        },
      },
      annotations: { readOnlyHint: false, openWorldHint: false },
      handler: (args) => {
        const threadId = requireArg(args, "thread_id");
        const text = requireArg(args, "text", { max: 8000 });
        const occurredAt = optionalIso(args?.occurred_at, "occurred_at");
        repo.addLog(threadId, {
          kind: "progress",
          action: "progress.note",
          text,
          actor: optionalArg(args, "actor") ?? "agent",
          at: occurredAt ?? undefined,
        });
        repo.getThreadRowOrThrow(threadId);
        const bundle = repo.threadBundle(threadId);
        return {
          revision: bundle.thread.revision,
          logs: bundle.logs.slice(0, 10).map((log) => ({
            at: log.created_at,
            kind: log.kind,
            text: log.text,
            actor: log.actor,
          })),
        };
      },
    },

    {
      name: "write_note",
      title: "写入自由笔记",
      description:
        "覆盖这条 Thread 的唯一一份自由笔记（Markdown）。写之前先读，保留用户原有的随手记录，不要为了填空而重写。传空字符串表示清空。",
      inputSchema: {
        type: "object",
        additionalProperties: false,
        required: ["thread_id", "content"],
        properties: {
          thread_id: { type: "string" },
          content: { type: "string", description: "完整的新内容，会覆盖旧内容" },
        },
      },
      annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
      handler: (args) => {
        const threadId = requireArg(args, "thread_id");
        const content = optionalArg(args, "content", { max: 200000 }) ?? "";
        const note = repo.saveNote(threadId, content, { actor: "agent" });
        return { thread_id: threadId, note: note.content, updated_at: note.updated_at, revision: repo.revisionOf(threadId) };
      },
    },

    {
      name: "list_overview",
      title: "读取总览",
      description:
        "跨 Thread 的行动入口。view=today 返回今天安排、逾期、待重新安排与需要确认结果的过往日程；view=actions 返回未结束的待办与日程（按 Thread 分组）；view=inbox 返回各收集箱里还没整理的内容。",
      inputSchema: {
        type: "object",
        additionalProperties: false,
        properties: {
          view: { type: "string", enum: ["today", "actions", "inbox"], description: "默认 today" },
          domain: { type: "string", description: "限定某个 Domain" },
          dates: { type: "string", enum: ["all", "with", "without"], description: "actions 视图：全部 / 有时间 / 无时间" },
          range: { type: "string", enum: ["any", "upcoming7"], description: "actions 视图：不限时间 / 近 7 天" },
        },
      },
      annotations: { readOnlyHint: true, openWorldHint: false },
      handler: (args) => {
        const domainArg = optionalArg(args, "domain");
        const domain = domainArg ? resolveDomain(domainArg) : null;
        if (domainArg && !domain) throw new ToolError(`找不到 Domain：${domainArg}`);
        const domainId = domain?.id ?? null;
        const view = optionalArg(args, "view") ?? "today";
        if (view === "actions") {
          const result = views.actionsView({
            domainId,
            dates: optionalArg(args, "dates") ?? "all",
            range: optionalArg(args, "range") ?? "any",
          });
          return {
            view,
            total: result.total,
            groups: result.groups.map((group) => ({
              thread_id: group.thread.id,
              thread_title: group.thread.title,
              is_inbox: Boolean(group.thread.is_inbox),
              entries: group.items.map(summarizeEntry),
            })),
          };
        }
        if (view === "inbox") {
          const result = views.inboxView({ domainId });
          return {
            view,
            total: result.total,
            groups: result.groups.map((group) => ({
              thread_id: group.thread.id,
              thread_title: group.thread.title,
              domain_name: group.domain?.name ?? null,
              entries: group.items.map(summarizeEntry),
            })),
          };
        }
        const result = views.todayView({ domainId, includeWaits: args?.include_waits === true });
        return {
          view: "today",
          date: result.today,
          groups: result.groups.map((group) => ({
            key: group.key,
            title: group.title,
            count: group.count,
            entries: group.entries.map((entry) => ({
              thread_id: entry.item.thread_id,
              thread_title: entry.thread?.title ?? null,
              ...summarizeEntry(entry.item),
            })),
          })),
        };
      },
    },

    {
      name: "search",
      title: "搜索",
      description: "在全部 Thread 的标题与当前描述、以及所有条目的标题里搜索关键词。",
      inputSchema: {
        type: "object",
        additionalProperties: false,
        required: ["query"],
        properties: { query: { type: "string" }, limit: { type: "number", description: "默认 20" } },
      },
      annotations: { readOnlyHint: true, openWorldHint: false },
      handler: (args) => {
        const query = requireArg(args, "query", { max: 200 });
        const limit = Math.min(Math.max(Number(args?.limit ?? 20) || 20, 1), 100);
        const result = repo.search(query, { limit });
        return {
          query,
          threads: result.threads.map(summarizeThread),
          entries: result.items.map((item) => ({
            ...summarizeEntry(item),
            thread_title: repo.getThreadRowOrThrow(item.thread_id).title,
          })),
        };
      },
    },
  ];
}
