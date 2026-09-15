import {
  ITEM_KINDS,
  THREAD_STATUSES,
  badRequest,
  optionalBool,
  optionalDateKey,
  optionalDateTime,
  optionalString,
  pickEnum,
  requireString,
} from "./util.js";
import { createRouter } from "./http.js";

export const API_VERSION = "1.0.0";

function itemPayload(body) {
  if (body.kind !== undefined) pickEnum(body.kind, "kind", ITEM_KINDS);
  return {
    kind: body.kind,
    title: body.title === undefined ? null : requireString(body.title, "title", { max: 500 }),
    detail: optionalString(body.detail ?? null, "detail", { max: 8000 }),
    planDate: optionalDateKey(body.plan_date, "plan_date"),
    dueDate: optionalDateKey(body.due_date, "due_date"),
    startAt: optionalDateTime(body.start_at, "start_at"),
    endAt: optionalDateTime(body.end_at, "end_at"),
    followUpDate: optionalDateKey(body.follow_up_date, "follow_up_date"),
    blocked: optionalBool(body.blocked, "blocked"),
    blockerReason: optionalString(body.blocker_reason ?? null, "blocker_reason", { max: 2000 }),
    status: body.status === undefined ? null : pickEnum(body.status, "status", [
      "open",
      "done",
      "cancelled",
      "resolved",
      "abandoned",
      "converted",
    ]),
  };
}

function withoutNulls(object) {
  return Object.fromEntries(Object.entries(object).filter(([, value]) => value !== null && value !== undefined));
}

function threadIdParam(params) {
  return params.id;
}

export function createApi({ repo, views, onMutate = null }) {
  const router = createRouter();
  const mutate = (result) => {
    if (onMutate) onMutate();
    return result;
  };

  router.get("/health", () => ({ status: "ok", service: "thread-pocket", server_time: new Date().toISOString() }));
  router.get("/api/v1/meta", () => ({
    service: "thread-pocket",
    api_version: API_VERSION,
    capabilities: [
      "domains",
      "threads",
      "items",
      "notes",
      "logs",
      "views",
      "search",
      "snapshot",
    ],
    item_kinds: ITEM_KINDS,
    thread_statuses: THREAD_STATUSES,
    server_time: new Date().toISOString(),
  }));

  /* --------------------------------- domains --------------------------------- */

  router.get("/api/v1/domains", (ctx) => ({
    domains: repo.listDomains({ includeArchived: ctx.query.include_archived === "1" }),
  }));

  router.post("/api/v1/domains", (ctx) =>
    mutate({
      domain: repo.createDomain({
        name: requireString(ctx.body.name, "name", { max: 80 }),
        color: ctx.body.color ?? undefined,
        icon: ctx.body.icon ?? undefined,
      }),
    }),
  );

  router.patch("/api/v1/domains/:id", (ctx) =>
    mutate({
      domain: repo.updateDomain(ctx.params.id, {
        name: ctx.body.name === undefined ? undefined : requireString(ctx.body.name, "name", { max: 80 }),
        color: ctx.body.color ?? undefined,
        icon: ctx.body.icon === undefined ? undefined : ctx.body.icon,
        position: ctx.body.position ?? undefined,
        archived: optionalBool(ctx.body.archived, "archived") ?? undefined,
      }),
    }),
  );

  router.delete("/api/v1/domains/:id", (ctx) => {
    repo.deleteDomain(ctx.params.id);
    mutate(null);
    return { deleted: true };
  });

  /* --------------------------------- threads --------------------------------- */

  router.get("/api/v1/threads", (ctx) => ({
    threads: repo.listThreads({
      include: ctx.query.include ?? "active",
      status: ctx.query.status ?? null,
      domainId: ctx.query.domain_id ?? null,
      search: ctx.query.q ?? null,
    }),
  }));

  router.post("/api/v1/threads", (ctx) =>
    mutate({
      thread: repo.createThread({
        domainId: requireString(ctx.body.domain_id, "domain_id"),
        title: requireString(ctx.body.title, "title", { max: 200 }),
        summary: optionalString(ctx.body.summary ?? "", "summary", { max: 4000 }) ?? "",
        status: ctx.body.status ?? undefined,
        isInbox: Boolean(ctx.body.is_inbox),
      }),
    }),
  );

  router.get("/api/v1/threads/:id", (ctx) => repo.threadBundle(threadIdParam(ctx.params)));

  router.get("/api/v1/threads/:id/scope", (ctx) => views.threadScope(ctx.params.id, ctx.query.scope ?? "all"));

  router.patch("/api/v1/threads/:id", (ctx) => {
    const patch = withoutNulls({
      title: ctx.body.title === undefined ? undefined : requireString(ctx.body.title, "title", { max: 200 }),
      summary: ctx.body.summary === undefined ? undefined : (optionalString(ctx.body.summary, "summary", { max: 4000 }) ?? ""),
      status: ctx.body.status === undefined ? undefined : pickEnum(ctx.body.status, "status", THREAD_STATUSES),
      domainId: ctx.body.domain_id ?? undefined,
      position: ctx.body.position ?? undefined,
      archived: optionalBool(ctx.body.archived, "archived") ?? undefined,
      trashed: optionalBool(ctx.body.trashed, "trashed") ?? undefined,
      isInbox: ctx.body.is_inbox === undefined ? undefined : Boolean(ctx.body.is_inbox),
    });
    const thread = repo.updateThread(ctx.params.id, patch);
    return mutate({ thread, bundle: repo.threadBundle(ctx.params.id) });
  });

  router.post("/api/v1/threads/:id/archive", (ctx) => {
    const archived = ctx.query.value === undefined ? true : ctx.query.value !== "0";
    return mutate({ thread: repo.updateThread(ctx.params.id, { archived }) });
  });

  router.post("/api/v1/threads/:id/trash", (ctx) => {
    const trashed = ctx.query.value === undefined ? true : ctx.query.value !== "0";
    return mutate({ thread: repo.updateThread(ctx.params.id, { trashed }) });
  });

  router.delete("/api/v1/threads/:id", (ctx) => {
    if (ctx.query.hard === "1") {
      repo.deleteThread(ctx.params.id);
    } else {
      repo.updateThread(ctx.params.id, { trashed: true });
    }
    mutate(null);
    return { deleted: true, hard: ctx.query.hard === "1" };
  });

  /* ---------------------------------- items ---------------------------------- */

  router.post("/api/v1/threads/:id/items", (ctx) => {
    const payload = itemPayload(ctx.body);
    if (!payload.kind) throw badRequest("缺少字段 kind");
    if (!payload.title) throw badRequest("缺少字段 title");
    const item = repo.createItem(ctx.params.id, withoutNulls(payload));
    return mutate({ item, bundle: repo.threadBundle(ctx.params.id) });
  });

  router.patch("/api/v1/items/:id", (ctx) => {
    const existing = repo.getItemOrThrow(ctx.params.id);
    const patch = withoutNulls({
      ...itemPayload(ctx.body),
      threadId: ctx.body.thread_id ?? undefined,
      position: ctx.body.position ?? undefined,
    });
    const item = repo.updateItem(ctx.params.id, patch);
    return mutate({
      item,
      bundle: repo.threadBundle(item.thread_id),
      previous_thread_id: existing.thread_id,
    });
  });

  router.post("/api/v1/items/:id/move", (ctx) => {
    const threadId = requireString(ctx.body.thread_id, "thread_id");
    const existing = repo.getItemOrThrow(ctx.params.id);
    const item = repo.updateItem(ctx.params.id, { threadId });
    return mutate({
      item,
      from: repo.threadBundle(existing.thread_id),
      bundle: repo.threadBundle(threadId),
      previous_thread_id: existing.thread_id,
    });
  });

  router.post("/api/v1/items/:id/convert", (ctx) => {
    const result = repo.convertDirection(ctx.params.id, {
      title: ctx.body.title === undefined ? null : requireString(ctx.body.title, "title", { max: 500 }),
      planDate: optionalDateKey(ctx.body.plan_date, "plan_date"),
      dueDate: optionalDateKey(ctx.body.due_date, "due_date"),
    });
    return mutate({ ...result, bundle: repo.threadBundle(result.threadId) });
  });

  router.delete("/api/v1/items/:id", (ctx) => {
    const existing = repo.getItemOrThrow(ctx.params.id);
    repo.deleteItem(ctx.params.id);
    return mutate({ deleted: true, bundle: repo.threadBundle(existing.thread_id) });
  });

  router.get("/api/v1/items", (ctx) => ({
    items: repo.listItems({
      threadId: ctx.query.thread_id ?? null,
      kind: ctx.query.kind ?? null,
      statuses: ctx.query.status ? ctx.query.status.split(",") : ["open"],
    }),
  }));

  /* ---------------------------------- notes ---------------------------------- */

  router.get("/api/v1/threads/:id/note", (ctx) => ({ note: repo.getNote(ctx.params.id) }));

  router.put("/api/v1/threads/:id/note", (ctx) => {
    const content = optionalString(ctx.body.content ?? "", "content", { max: 200000 }) ?? "";
    return mutate({ note: repo.saveNote(ctx.params.id, content) });
  });

  /* ---------------------------------- logs ----------------------------------- */

  router.get("/api/v1/threads/:id/logs", (ctx) => ({
    logs: repo.listLogs(ctx.params.id, Number(ctx.query.limit ?? 200) || 200),
  }));

  router.post("/api/v1/threads/:id/logs", (ctx) => {
    const text = requireString(ctx.body.text, "text", { max: 4000 });
    const kind = ctx.body.kind === "operation" ? "operation" : "progress";
    const logs = repo.addProgressNote(ctx.params.id, text, { kind, actor: ctx.body.actor ?? "user" });
    return mutate({ logs });
  });

  router.delete("/api/v1/logs/:id", (ctx) => {
    repo.deleteLog(ctx.params.id);
    return { deleted: true };
  });

  /* ---------------------------------- views ---------------------------------- */

  router.get("/api/v1/views/today", (ctx) =>
    views.todayView({
      domainId: ctx.query.domain_id ?? null,
      includeWaits: ctx.query.include_waits === "1",
      includePastEvents: ctx.query.include_past_events !== "0",
    }),
  );

  router.get("/api/v1/views/actions", (ctx) =>
    views.actionsView({
      domainId: ctx.query.domain_id ?? null,
      dates: ctx.query.dates ?? "all",
      range: ctx.query.range ?? "any",
    }),
  );

  router.get("/api/v1/views/inbox", (ctx) => views.inboxView({ domainId: ctx.query.domain_id ?? null }));

  /* -------------------------------- workspace -------------------------------- */

  router.get("/api/v1/snapshot", () => repo.snapshot());

  router.get("/api/v1/search", (ctx) => {
    const q = ctx.query.q ?? "";
    if (!q.trim()) return { q, threads: [], items: [] };
    return { q, ...repo.search(q) };
  });

  router.get("/api/v1/overview", (ctx) => {
    const domainId = ctx.query.domain_id ?? null;
    return {
      today: views.todayView({ domainId }),
      actions: views.actionsView({ domainId }),
      inbox: views.inboxView({ domainId }),
    };
  });

  return router;
}
