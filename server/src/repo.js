import {
  CLOSED_ITEM_STATUSES,
  ITEM_KINDS,
  THREAD_STATUSES,
  badRequest,
  bool,
  conflict,
  HttpError,
  newId,
  notFound,
  nowIso,
  parseJson,
} from "./util.js";
import { withTransaction } from "./db.js";

export function serializeDomain(row) {
  return {
    id: row.id,
    name: row.name,
    color: row.color,
    icon: row.icon ?? null,
    position: row.position,
    archived: bool(row.archived),
    created_at: row.created_at,
    updated_at: row.updated_at,
  };
}

export function serializeThread(row) {
  const counts = row.open_tasks === undefined
    ? undefined
    : {
        open_tasks: row.open_tasks ?? 0,
        open_events: row.open_events ?? 0,
        open_directions: row.open_directions ?? 0,
        open_waits: row.open_waits ?? 0,
        open_blocked: row.open_blocked ?? 0,
        done_items: row.done_items ?? 0,
      };
  return {
    id: row.id,
    domain_id: row.domain_id,
    title: row.title,
    summary: row.summary ?? "",
    status: row.status,
    is_inbox: bool(row.is_inbox),
    position: row.position,
    revision: row.revision ?? 1,
    archived: row.archived_at !== null && row.archived_at !== undefined,
    archived_at: row.archived_at ?? null,
    trashed_at: row.trashed_at ?? null,
    created_at: row.created_at,
    updated_at: row.updated_at,
    counts,
  };
}

export function serializeItem(row) {
  return {
    id: row.id,
    thread_id: row.thread_id,
    kind: row.kind,
    title: row.title,
    status: row.status,
    detail: row.detail ?? null,
    plan_date: row.plan_date ?? null,
    due_date: row.due_date ?? null,
    start_at: row.start_at ?? null,
    end_at: row.end_at ?? null,
    follow_up_date: row.follow_up_date ?? null,
    blocked: bool(row.blocked),
    blocker_reason: row.blocker_reason ?? null,
    source_id: row.source_id ?? null,
    position: row.position,
    created_at: row.created_at,
    updated_at: row.updated_at,
    closed_at: row.closed_at ?? null,
  };
}

export function serializeNote(row) {
  if (!row) return { thread_id: null, content: "", updated_at: null };
  return { thread_id: row.thread_id, content: row.content ?? "", updated_at: row.updated_at };
}

export function serializeLog(row) {
  return {
    id: row.id,
    thread_id: row.thread_id,
    kind: row.kind,
    action: row.action,
    text: row.text,
    meta: parseJson(row.meta, null),
    actor: row.actor,
    created_at: row.created_at,
  };
}

const THREAD_SELECT = `
select t.*,
  (select count(*) from items i where i.thread_id = t.id and i.kind = 'task' and i.status = 'open') as open_tasks,
  (select count(*) from items i where i.thread_id = t.id and i.kind = 'event' and i.status = 'open') as open_events,
  (select count(*) from items i where i.thread_id = t.id and i.kind = 'direction' and i.status = 'open') as open_directions,
  (select count(*) from items i where i.thread_id = t.id and i.kind = 'wait' and i.status = 'open') as open_waits,
  (select count(*) from items i where i.thread_id = t.id and i.status = 'open' and i.blocked = 1) as open_blocked,
  (select count(*) from items i where i.thread_id = t.id and i.status in ('done','resolved','converted')) as done_items
from threads t
`;

export function createRepository(db) {
  const q = {
    domainById: db.prepare("select * from domains where id = ?"),
    domainsAll: db.prepare("select * from domains order by position asc, created_at asc"),
    domainInsert: db.prepare(
      "insert into domains (id, name, color, icon, position, archived, created_at, updated_at) values (?,?,?,?,?,?,?,?)",
    ),
    domainMaxPosition: db.prepare("select coalesce(max(position), -1) as p from domains"),
    domainUpdate: db.prepare(
      "update domains set name = ?, color = ?, icon = ?, position = ?, archived = ?, updated_at = ? where id = ?",
    ),
    domainDelete: db.prepare("delete from domains where id = ?"),

    threadById: db.prepare(`${THREAD_SELECT} where t.id = ?`),
    threadInsert: db.prepare(
      "insert into threads (id, domain_id, title, summary, status, is_inbox, position, created_at, updated_at) values (?,?,?,?,?,?,?,?,?)",
    ),
    threadMaxPosition: db.prepare("select coalesce(max(position), -1) as p from threads where domain_id = ?"),
    threadTouch: db.prepare("update threads set updated_at = ?, revision = revision + 1 where id = ?"),
    threadRevision: db.prepare("select revision from threads where id = ?"),
    threadDelete: db.prepare("delete from threads where id = ?"),
    threadByDomain: db.prepare(`${THREAD_SELECT} where t.domain_id = ? order by t.position asc, t.created_at asc`),

    itemsByThread: db.prepare("select * from items where thread_id = ? order by position asc, created_at asc"),
    itemById: db.prepare("select * from items where id = ?"),
    itemInsert: db.prepare(`
      insert into items (id, thread_id, kind, title, status, detail, plan_date, due_date, start_at, end_at,
        follow_up_date, blocked, blocker_reason, source_id, position, created_at, updated_at, closed_at)
      values (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`),
    itemMaxPosition: db.prepare("select coalesce(max(position), -1) as p from items where thread_id = ?"),
    itemUpdate: db.prepare(`
      update items set thread_id = ?, kind = ?, title = ?, status = ?, detail = ?, plan_date = ?, due_date = ?,
        start_at = ?, end_at = ?, follow_up_date = ?, blocked = ?, blocker_reason = ?, source_id = ?,
        position = ?, updated_at = ?, closed_at = ? where id = ?`),
    itemDelete: db.prepare("delete from items where id = ?"),
    itemsAll: db.prepare("select * from items order by position asc, created_at asc"),

    noteByThread: db.prepare("select * from notes where thread_id = ?"),
    noteUpsert: db.prepare(`
      insert into notes (thread_id, content, updated_at) values (?,?,?)
      on conflict(thread_id) do update set content = excluded.content, updated_at = excluded.updated_at`),

    logInsert: db.prepare(
      "insert into log_entries (id, thread_id, kind, action, text, meta, actor, created_at) values (?,?,?,?,?,?,?,?)",
    ),
    logsByThread: db.prepare(
      "select * from log_entries where thread_id = ? order by created_at desc, rowid desc limit ?",
    ),
    logsAll: db.prepare("select * from log_entries order by created_at desc, rowid desc limit ?"),
    logDelete: db.prepare("delete from log_entries where id = ?"),
  };

  function getDomainOrThrow(id) {
    const row = q.domainById.get(id);
    if (!row) throw notFound("Domain 不存在");
    return row;
  }

  function getThreadRowOrThrow(id) {
    const row = q.threadById.get(id);
    if (!row) throw notFound("Thread 不存在");
    return row;
  }

  function getItemOrThrow(id) {
    const row = q.itemById.get(id);
    if (!row) throw notFound("事项不存在");
    return row;
  }

  function addLog(threadId, { kind = "operation", action, text, meta = null, actor = "user", at = null }) {
    q.logInsert.run(newId("lg"), threadId, kind, action, text, meta ? JSON.stringify(meta) : null, actor, at ?? nowIso());
  }

  function touch(threadId, stamp = nowIso()) {
    q.threadTouch.run(stamp, threadId);
    return stamp;
  }

  function revisionOf(threadId) {
    return q.threadRevision.get(threadId)?.revision ?? null;
  }

  /**
   * 乐观并发：Agent 读取 Thread 后必须带上当时的 revision。
   * 期间若有人改过，就抛出冲突，让调用方先重新读取再决定，避免覆盖别人的修改。
   */
  function assertRevision(threadId, expected) {
    if (expected === null || expected === undefined) return;
    const current = revisionOf(threadId);
    if (current === null) throw notFound("Thread 不存在");
    if (Number(expected) !== Number(current)) {
      throw new HttpError(
        409,
        `Thread 已被修改（当前 revision ${current}，请求基于 ${expected}）`,
        "revision_conflict",
        { current_revision: current, expected_revision: Number(expected) },
      );
    }
  }

  function threadBundle(id) {
    const row = getThreadRowOrThrow(id);
    const found = q.itemsByThread.all(id).map(serializeItem);
    const open = found.filter((item) => item.status === "open");
    const closed = found
      .filter((item) => item.status !== "open")
      .sort((a, b) => (b.closed_at ?? "").localeCompare(a.closed_at ?? ""));
    return {
      thread: serializeThread(row),
      items: { open, closed },
      note: serializeNote(q.noteByThread.get(id)),
      logs: q.logsByThread.all(id, 200).map(serializeLog),
    };
  }

  /* ---------------------------------- domains --------------------------------- */

  function listDomains({ includeArchived = false } = {}) {
    return q.domainsAll
      .all()
      .map(serializeDomain)
      .filter((domain) => includeArchived || !domain.archived);
  }

  function createDomain(input) {
    const stamp = nowIso();
    const id = newId("dm");
    const position = (q.domainMaxPosition.get().p ?? -1) + 1;
    q.domainInsert.run(id, input.name, input.color ?? "blue", input.icon ?? null, position, 0, stamp, stamp);
    const threadId = newId("th");
    q.threadInsert.run(
      threadId,
      id,
      "收件箱",
      "先收下来，稍后整理归属。",
      "active",
      1,
      0,
      stamp,
      stamp,
    );
    return serializeDomain(q.domainById.get(id));
  }

  function updateDomain(id, patch) {
    const row = getDomainOrThrow(id);
    const next = {
      name: patch.name ?? row.name,
      color: patch.color ?? row.color,
      icon: patch.icon === undefined ? row.icon : patch.icon,
      position: patch.position ?? row.position,
      archived: patch.archived === undefined ? row.archived : patch.archived ? 1 : 0,
    };
    q.domainUpdate.run(next.name, next.color, next.icon, next.position, next.archived, nowIso(), id);
    return serializeDomain(q.domainById.get(id));
  }

  function deleteDomain(id) {
    getDomainOrThrow(id);
    q.domainDelete.run(id);
  }

  /* ---------------------------------- threads --------------------------------- */

  function filterThreads(rows, { include = "active", status, q: search }) {
    const needle = search ? search.trim().toLowerCase() : null;
    return rows.filter((row) => {
      const thread = serializeThread(row);
      if (include === "active" && thread.trashed_at) return false;
      if (include === "archived" && !thread.archived_at) return false;
      if (include === "trashed" && !thread.trashed_at) return false;
      if (status && thread.status !== status) return false;
      if (needle) {
        const haystack = `${thread.title} ${thread.summary}`.toLowerCase();
        if (!haystack.includes(needle)) return false;
      }
      return true;
    });
  }

  function listThreads({ include = "active", status = null, domainId = null, search = null } = {}) {
    let rows;
    if (domainId) {
      getDomainOrThrow(domainId);
      rows = q.threadByDomain.all(domainId);
    } else {
      rows = db.prepare(`${THREAD_SELECT} order by t.position asc, t.created_at asc`).all();
    }
    return filterThreads(rows, { include, status, q: search }).map(serializeThread);
  }

  function createThread(input) {
    const domain = getDomainOrThrow(input.domainId);
    const stamp = nowIso();
    const id = newId("th");
    const position = (q.threadMaxPosition.get(domain.id).p ?? -1) + 1;
    const title = input.title;
    const isInbox = input.isInbox ? 1 : 0;
    q.threadInsert.run(
      id,
      domain.id,
      title,
      input.summary ?? "",
      input.status ?? "active",
      isInbox,
      position,
      stamp,
      stamp,
    );
    if (isInbox) {
      q.logInsert.run(newId("lg"), id, "operation", "thread.created", "建立了这条收集箱。", null, "user", stamp);
    } else {
      addLog(id, { action: "thread.created", text: `建立 Thread「${title}」。`, at: stamp });
    }
    return serializeThread(q.threadById.get(id));
  }

  function updateThread(id, patch) {
    const row = getThreadRowOrThrow(id);
    const stamp = nowIso();
    const next = {
      domain_id: patch.domainId ?? row.domain_id,
      title: patch.title ?? row.title,
      summary: patch.summary ?? row.summary,
      status: patch.status ?? row.status,
      is_inbox: patch.isInbox === undefined ? row.is_inbox : patch.isInbox ? 1 : 0,
      position: patch.position ?? row.position,
      archived_at: patch.archived === undefined ? row.archived_at : patch.archived ? stamp : null,
      trashed_at: patch.trashed === undefined ? row.trashed_at : patch.trashed ? stamp : null,
    };
    if (patch.domainId) getDomainOrThrow(patch.domainId);
    if (next.status !== row.status) {
      if (!THREAD_STATUSES.includes(next.status)) {
        throw badRequest(`Thread 状态需要是 ${THREAD_STATUSES.join(" / ")} 之一`);
      }
    }
    db.prepare(
      `update threads set domain_id = ?, title = ?, summary = ?, status = ?, is_inbox = ?, position = ?,
        archived_at = ?, trashed_at = ?, updated_at = ? where id = ?`,
    ).run(
      next.domain_id,
      next.title,
      next.summary,
      next.status,
      next.is_inbox,
      next.position,
      next.archived_at,
      next.trashed_at,
      stamp,
      id,
    );

    if (patch.summary !== undefined && patch.summary !== row.summary) {
      addLog(id, { action: "thread.summary", text: "更新了当前描述。", meta: { from: row.summary, to: next.summary }, at: stamp });
    }
    if (next.status !== row.status) {
      addLog(id, {
        action: "thread.status",
        text: `状态调整为「${statusLabel(next.status)}」。`,
        meta: { from: row.status, to: next.status },
        at: stamp,
      });
    }
    if (next.domain_id !== row.domain_id) {
      const domainName = q.domainById.get(next.domain_id)?.name ?? "";
      addLog(id, { action: "thread.domain", text: `归属调整到「${domainName}」。`, at: stamp });
    }
    if (next.archived_at && !row.archived_at) {
      addLog(id, { action: "thread.archived", text: "归档了这条 Thread。", at: stamp });
    }
    if (row.archived_at && !next.archived_at) {
      addLog(id, { action: "thread.unarchived", text: "从归档中恢复。", at: stamp });
    }
    if (next.trashed_at && !row.trashed_at) {
      addLog(id, { action: "thread.trashed", text: "移入回收站。", at: stamp });
    }
    if (row.trashed_at && !next.trashed_at) {
      addLog(id, { action: "thread.restored", text: "从回收站恢复。", at: stamp });
    }
    return serializeThread(q.threadById.get(id));
  }

  function deleteThread(id) {
    getThreadRowOrThrow(id);
    db.prepare("delete from threads where id = ?").run(id);
  }

  /* ----------------------------------- items ---------------------------------- */

  function normalizeItem(row) {
    const closed = CLOSED_ITEM_STATUSES.includes(row.status);
    return {
      thread_id: row.thread_id,
      kind: row.kind,
      title: row.title,
      status: row.status,
      detail: row.detail,
      plan_date: row.plan_date,
      due_date: row.due_date,
      start_at: row.start_at,
      end_at: row.end_at,
      follow_up_date: row.follow_up_date,
      blocked: row.blocked,
      blocker_reason: row.blocker_reason,
      source_id: row.source_id,
      position: row.position,
      closed_at: closed ? (row.closed_at ?? nowIso()) : null,
    };
  }

  function createItem(threadId, input) {
    getThreadRowOrThrow(threadId);
    if (!ITEM_KINDS.includes(input.kind)) {
      throw badRequest(`事项类型需要是 ${ITEM_KINDS.join(" / ")} 之一`);
    }
    const stamp = nowIso();
    const defaultPrefix = input.kind === "task" ? "tk" : input.kind === "event" ? "ev" : input.kind === "wait" ? "wt" : "dr";
    let id;
    if (input.id !== undefined && input.id !== null) {
      id = String(input.id).trim();
      if (!/^[A-Za-z0-9_-]{3,64}$/.test(id)) {
        throw badRequest("事项 id 只能包含字母、数字、下划线和连字符，长度 3–64");
      }
      if (q.itemById.get(id)) throw conflict(`事项 id 已存在：${id}`);
    } else {
      id = newId(defaultPrefix);
    }
    const position = (q.itemMaxPosition.get(threadId).p ?? -1) + 1;
    const row = {
      thread_id: threadId,
      kind: input.kind,
      title: input.title,
      status: input.status ?? "open",
      detail: input.detail ?? null,
      plan_date: input.planDate ?? null,
      due_date: input.dueDate ?? null,
      start_at: input.startAt ?? null,
      end_at: input.endAt ?? null,
      follow_up_date: input.followUpDate ?? null,
      blocked: input.blocked ? 1 : 0,
      blocker_reason: input.blockerReason ?? null,
      source_id: input.sourceId ?? null,
      position,
    };
    const normalized = normalizeItem(row);
    q.itemInsert.run(
      id,
      normalized.thread_id,
      normalized.kind,
      normalized.title,
      normalized.status,
      normalized.detail,
      normalized.plan_date,
      normalized.due_date,
      normalized.start_at,
      normalized.end_at,
      normalized.follow_up_date,
      normalized.blocked,
      normalized.blocker_reason,
      normalized.source_id,
      normalized.position,
      stamp,
      stamp,
      normalized.closed_at,
    );
    touch(threadId, stamp);
    addLog(threadId, {
      action: "item.created",
      text: `新增${kindLabel(input.kind)}：${input.title}`,
      meta: { itemId: id, kind: input.kind },
      actor: input.actor ?? "user",
      at: stamp,
    });
    return serializeItem(q.itemById.get(id));
  }

  function updateItem(id, patch, { actor = "user" } = {}) {
    const row = getItemOrThrow(id);
    const stamp = nowIso();
    const next = {
      thread_id: patch.threadId ?? row.thread_id,
      kind: patch.kind ?? row.kind,
      title: patch.title ?? row.title,
      status: patch.status ?? row.status,
      detail: patch.detail === undefined ? row.detail : patch.detail,
      plan_date: patch.planDate === undefined ? row.plan_date : patch.planDate,
      due_date: patch.dueDate === undefined ? row.due_date : patch.dueDate,
      start_at: patch.startAt === undefined ? row.start_at : patch.startAt,
      end_at: patch.endAt === undefined ? row.end_at : patch.endAt,
      follow_up_date: patch.followUpDate === undefined ? row.follow_up_date : patch.followUpDate,
      blocked: patch.blocked === undefined ? row.blocked : patch.blocked ? 1 : 0,
      blocker_reason: patch.blockerReason === undefined ? row.blocker_reason : patch.blockerReason,
      source_id: patch.sourceId === undefined ? row.source_id : patch.sourceId,
      position: patch.position ?? row.position,
    };
    if (!ITEM_KINDS.includes(next.kind)) throw badRequest("事项类型不合法");
    if (next.thread_id !== row.thread_id) {
      getThreadRowOrThrow(next.thread_id);
      next.position = (q.itemMaxPosition.get(next.thread_id).p ?? -1) + 1;
    }
    if (next.status !== row.status && !["open", ...CLOSED_ITEM_STATUSES].includes(next.status)) {
      throw badRequest("事项状态不合法");
    }
    const normalized = normalizeItem({ ...next, closed_at: next.status === row.status ? row.closed_at : null });
    q.itemUpdate.run(
      normalized.thread_id,
      normalized.kind,
      normalized.title,
      normalized.status,
      normalized.detail,
      normalized.plan_date,
      normalized.due_date,
      normalized.start_at,
      normalized.end_at,
      normalized.follow_up_date,
      normalized.blocked,
      normalized.blocker_reason,
      normalized.source_id,
      normalized.position,
      stamp,
      normalized.closed_at,
      id,
    );
    touch(row.thread_id, stamp);
    if (next.thread_id !== row.thread_id) touch(next.thread_id, stamp);
    recordItemDiff(row, next, { actor, at: stamp });
    return serializeItem(q.itemById.get(id));
  }

  function recordItemDiff(before, after, { actor, at }) {
    if (after.thread_id !== before.thread_id) {
      const target = q.threadById.get(after.thread_id);
      addLog(before.thread_id, {
        action: "item.moved",
        text: `「${before.title}」移动到 ${target?.title ?? "其他 Thread"}。`,
        meta: { itemId: before.id, toThreadId: after.thread_id },
        actor,
        at,
      });
      addLog(after.thread_id, {
        action: "item.received",
        text: `从其他 Thread 移入：${after.title}`,
        meta: { itemId: before.id },
        actor,
        at,
      });
    }
    if (after.status !== before.status) {
      const label = statusLabel(after.status);
      const action =
        after.status === "open" ? "item.reopened" : after.status === "resolved" ? "item.resolved" : after.status === "cancelled" ? "item.cancelled" : after.status === "abandoned" ? "item.abandoned" : "item.done";
      addLog(after.thread_id, {
        action,
        text: `${label}${kindLabel(after.kind)}：${after.title}`,
        meta: { itemId: before.id, from: before.status, to: after.status },
        actor,
        at,
      });
    }
    const dateChanges = [];
    for (const [field, label] of [
      ["plan_date", "计划日"],
      ["due_date", "截止日"],
      ["follow_up_date", "跟进日"],
      ["start_at", "开始"],
      ["end_at", "结束"],
    ]) {
      if ((before[field] ?? null) !== (after[field] ?? null)) {
        dateChanges.push(`${label} ${before[field] ?? "无"} → ${after[field] ?? "无"}`);
      }
    }
    if (dateChanges.length > 0) {
      addLog(after.thread_id, {
        action: "item.rescheduled",
        text: `改期「${after.title}」：${dateChanges.join("，")}`,
        meta: { itemId: before.id },
        actor,
        at,
      });
    }
    if (after.title !== before.title && after.status === before.status && dateChanges.length === 0) {
      addLog(after.thread_id, {
        action: "item.renamed",
        text: `重命名为：${after.title}`,
        meta: { itemId: before.id, from: before.title },
        actor,
        at,
      });
    }
  }

  function deleteItem(id) {
    const row = getItemOrThrow(id);
    q.itemDelete.run(id);
    touch(row.thread_id);
    addLog(row.thread_id, { action: "item.deleted", text: `删除了${kindLabel(row.kind)}：${row.title}` });
  }

  /**
   * 批量写入：Agent 常用的一次性提交多个条目。
   * 整批在同一个事务里完成，要么全部成功，要么全部不生效。
   */
  function upsertEntries(threadId, entries, { expectedRevision = null, actor = "agent", order = null } = {}) {
    getThreadRowOrThrow(threadId);
    return withTransaction(db, () => {
      assertRevision(threadId, expectedRevision);
      const written = [];
      for (const entry of entries) {
        const existing = entry.id ? q.itemById.get(entry.id) : null;
        if (existing && existing.thread_id !== threadId) {
          throw conflict(`事项 ${entry.id} 属于其他 Thread，请使用 move_entry`);
        }
        if (existing) {
          const patch = {};
          for (const key of [
            "kind",
            "title",
            "detail",
            "planDate",
            "dueDate",
            "startAt",
            "endAt",
            "followUpDate",
            "blocked",
            "blockerReason",
            "status",
          ]) {
            if (entry[key] !== undefined) patch[key] = entry[key];
          }
          written.push(updateItem(existing.id, patch, { actor }));
        } else {
          written.push(createItem(threadId, { ...entry, actor }));
        }
      }
      if (Array.isArray(order) && order.length > 0) {
        order.forEach((itemId, index) => {
          const row = q.itemById.get(itemId);
          if (!row) throw badRequest(`排序里包含不存在的事项：${itemId}`);
          if (row.thread_id !== threadId) throw badRequest(`排序里的事项不属于该 Thread：${itemId}`);
          db.prepare("update items set position = ? where id = ?").run(index, itemId);
        });
        touch(threadId);
      }
      return { entries: written, bundle: threadBundle(threadId) };
    });
  }

  /** 探索方向 → 待办：保留来源，方向标记为已转化。 */
  function convertDirection(id, { title = null, planDate = null, dueDate = null } = {}) {
    const row = getItemOrThrow(id);
    if (row.kind !== "direction") throw conflict("只有探索方向可以转成行动");
    if (row.status !== "open") throw conflict("这条探索方向已经结束");
    return withTransaction(db, () => {
      const task = createItem(row.thread_id, {
        kind: "task",
        title: title ?? row.title,
        planDate,
        dueDate,
        sourceId: row.id,
      });
      updateItem(row.id, { status: "converted" });
      addLog(row.thread_id, {
        action: "direction.converted",
        text: `探索方向转为待办：${task.title}`,
        meta: { directionId: row.id, itemId: task.id },
      });
      return { direction: serializeItem(q.itemById.get(row.id)), task, threadId: row.thread_id };
    });
  }

  function listItems({ threadId = null, kind = null, statuses = ["open"] } = {}) {
    const rows = threadId ? q.itemsByThread.all(threadId) : q.itemsAll.all();
    const wanted = new Set(statuses);
    return rows
      .map(serializeItem)
      .filter((item) => (kind ? item.kind === kind : true))
      .filter((item) => (statuses.length === 0 ? true : wanted.has(item.status)));
  }

  /* ----------------------------------- notes ---------------------------------- */

  function getNote(threadId) {
    getThreadRowOrThrow(threadId);
    return serializeNote(q.noteByThread.get(threadId));
  }

  function saveNote(threadId, content, { actor = "user" } = {}) {
    getThreadRowOrThrow(threadId);
    const stamp = nowIso();
    q.noteUpsert.run(threadId, content ?? "", stamp);
    touch(threadId, stamp);
    return serializeNote(q.noteByThread.get(threadId));
  }

  /* ----------------------------------- logs ----------------------------------- */

  function addProgressNote(threadId, text, { actor = "user", meta = null, kind = "progress", occurredAt = null } = {}) {
    getThreadRowOrThrow(threadId);
    // 历史补记：日志用发生时间，但 Thread 的更新时间仍然是「现在」，
    // 否则一条旧日志会把整条线索排到列表很后面。
    addLog(threadId, { kind, action: "progress.note", text, meta, actor, at: occurredAt ?? nowIso() });
    touch(threadId);
    return q.logsByThread.all(threadId, 200).map(serializeLog);
  }

  function listLogs(threadId, limit = 200) {
    getThreadRowOrThrow(threadId);
    return q.logsByThread.all(threadId, limit).map(serializeLog);
  }

  function deleteLog(id) {
    q.logDelete.run(id);
  }

  /* --------------------------------- snapshot --------------------------------- */

  function snapshot({ includeTrashed = true } = {}) {
    const domains = q.domainsAll.all().map(serializeDomain);
    const threads = db
      .prepare(`${THREAD_SELECT} order by t.position asc, t.created_at asc`)
      .all()
      .map(serializeThread)
      .filter((thread) => includeTrashed || !thread.trashed_at);
    const visible = new Set(threads.map((thread) => thread.id));
    const items = q.itemsAll.all().map(serializeItem).filter((item) => visible.has(item.thread_id));
    const notes = db.prepare("select * from notes").all().map(serializeNote).filter((note) => visible.has(note.thread_id));
    const logs = q.logsAll.all(500).map(serializeLog).filter((log) => visible.has(log.thread_id));
    return { domains, threads, items, notes, logs, server_time: nowIso() };
  }

  function search(term, { limit = 60 } = {}) {
    const needle = term.trim().toLowerCase();
    if (!needle) return { threads: [], items: [] };
    const threads = db
      .prepare(`${THREAD_SELECT} order by t.updated_at desc`)
      .all()
      .map(serializeThread)
      .filter((thread) => !thread.trashed_at)
      .filter((thread) => `${thread.title} ${thread.summary}`.toLowerCase().includes(needle))
      .slice(0, limit);
    const items = q.itemsAll
      .all()
      .map(serializeItem)
      .filter((item) => `${item.title} ${item.detail ?? ""}`.toLowerCase().includes(needle))
      .slice(0, limit);
    return { threads, items };
  }

  return {
    db,
    listDomains,
    createDomain,
    updateDomain,
    deleteDomain,
    listThreads,
    threadBundle,
    createThread,
    updateThread,
    deleteThread,
    createItem,
    updateItem,
    deleteItem,
    upsertEntries,
    convertDirection,
    listItems,
    getNote,
    saveNote,
    addProgressNote,
    listLogs,
    addLog,
    deleteLog,
    snapshot,
    search,
    revisionOf,
    assertRevision,
    getThreadRowOrThrow,
    getItemOrThrow,
    getDomainOrThrow,
  };
}

export function statusLabel(status) {
  return (
    {
      open: "重新打开",
      done: "已完成",
      cancelled: "已取消",
      resolved: "已解除",
      abandoned: "已放弃",
      converted: "已转化",
      active: "进行中",
      waiting: "等待中",
      paused: "暂停",
      completed: "完成",
    }[status] ?? status
  );
}

export function kindLabel(kind) {
  return (
    {
      task: "待办",
      event: "固定日程",
      direction: "探索方向",
      wait: "等待",
    }[kind] ?? "事项"
  );
}
export { withTransaction };
