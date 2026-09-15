import assert from "node:assert/strict";
import { after, before, describe, it } from "node:test";
import { listen } from "../src/server.js";
import { seed } from "../src/seed.js";
import { createRepository } from "../src/repo.js";
import { openDatabase } from "../src/db.js";
import { addDays, toDateKey } from "../src/util.js";

let app;
let base;

async function api(path, options = {}) {
  const res = await fetch(`${base}${path}`, {
    headers: { "content-type": "application/json", ...(options.headers ?? {}) },
    method: options.method ?? "GET",
    body: options.body ? JSON.stringify(options.body) : undefined,
  });
  const text = await res.text();
  return { status: res.status, body: text ? JSON.parse(text) : null };
}

before(async () => {
  app = await listen({ port: 0, host: "127.0.0.1", dbFile: ":memory:", logger: { error() {} } });
  base = `http://127.0.0.1:${app.server.address().port}`;
  seed(app.db);
});

after(async () => {
  await app.close();
});

describe("服务与元信息", () => {
  it("健康检查可用", async () => {
    const { status, body } = await api("/health");
    assert.equal(status, 200);
    assert.equal(body.status, "ok");
  });

  it("元信息暴露类型定义", async () => {
    const { body } = await api("/api/v1/meta");
    assert.deepEqual(body.item_kinds, ["task", "event", "direction", "wait"]);
    assert.ok(body.capabilities.includes("views"));
  });

  it("初始即带有 Domain 与收件箱", async () => {
    const { body } = await api("/api/v1/domains");
    assert.ok(body.domains.length >= 3);
    const inboxes = (await api("/api/v1/threads")).body.threads.filter((t) => t.is_inbox);
    assert.equal(inboxes.length, body.domains.length);
  });

  it("未知接口返回 404，方法不匹配返回 405", async () => {
    assert.equal((await api("/api/v1/nope")).status, 404);
    assert.equal((await api("/api/v1/snapshot", { method: "DELETE" })).status, 405);
  });
});

describe("Domain 与 Thread", () => {
  let domainId;
  let threadId;

  it("可以创建 Domain 并自动带上收集箱", async () => {
    const created = await api("/api/v1/domains", { method: "POST", body: { name: "测试领域", color: "rose" } });
    assert.equal(created.status, 201);
    domainId = created.body.domain.id;
    const threads = (await api(`/api/v1/threads?domain_id=${domainId}`)).body.threads;
    assert.equal(threads.length, 1);
    assert.equal(threads[0].is_inbox, true);
  });

  it("可以创建 Thread，并在日志里留下记录", async () => {
    const created = await api("/api/v1/threads", {
      method: "POST",
      body: { domain_id: domainId, title: "装修预算", summary: "先确认总预算。" },
    });
    assert.equal(created.status, 200);
    threadId = created.body.thread.id;
    const bundle = (await api(`/api/v1/threads/${threadId}`)).body;
    assert.equal(bundle.thread.summary, "先确认总预算。");
    assert.equal(bundle.logs[0].action, "thread.created");
  });

  it("更新当前描述会写入日志，并保留变化前后", async () => {
    await api(`/api/v1/threads/${threadId}`, { method: "PATCH", body: { summary: "预算已确认 30 万。" } });
    const bundle = (await api(`/api/v1/threads/${threadId}`)).body;
    assert.equal(bundle.thread.summary, "预算已确认 30 万。");
    const entry = bundle.logs.find((log) => log.action === "thread.summary");
    assert.equal(entry.meta.from, "先确认总预算。");
    assert.equal(entry.meta.to, "预算已确认 30 万。");
  });

  it("拒绝非法状态", async () => {
    const res = await api(`/api/v1/threads/${threadId}`, { method: "PATCH", body: { status: "bogus" } });
    assert.equal(res.status, 400);
  });

  it("归档、回收与恢复各自记录日志", async () => {
    await api(`/api/v1/threads/${threadId}`, { method: "PATCH", body: { archived: true } });
    let bundle = (await api(`/api/v1/threads/${threadId}`)).body;
    assert.equal(bundle.thread.archived, true);
    assert.ok(bundle.logs.some((log) => log.action === "thread.archived"));
    await api(`/api/v1/threads/${threadId}`, { method: "PATCH", body: { archived: false, trashed: true } });
    bundle = (await api(`/api/v1/threads/${threadId}`)).body;
    assert.ok(bundle.thread.trashed_at);
    const active = (await api(`/api/v1/threads?domain_id=${domainId}`)).body.threads;
    assert.equal(active.length, 1, "回收站里的 Thread 不进入默认列表");
    await api(`/api/v1/threads/${threadId}`, { method: "PATCH", body: { trashed: false } });
    assert.equal((await api(`/api/v1/threads?domain_id=${domainId}`)).body.threads.length, 2);
  });
});

describe("四类事项", () => {
  let domainId;
  let threadId;
  const today = toDateKey();

  before(async () => {
    const domain = await api("/api/v1/domains", { method: "POST", body: { name: "事项领域" } });
    domainId = domain.body.domain.id;
    const thread = await api("/api/v1/threads", {
      method: "POST",
      body: { domain_id: domainId, title: "厨房方案", summary: "先比价。" },
    });
    threadId = thread.body.thread.id;
  });

  it("可以创建待办、日程、探索方向与等待", async () => {
    const task = await api(`/api/v1/threads/${threadId}/items`, {
      method: "POST",
      body: { kind: "task", title: "核对报价中的增项", due_date: addDays(today, 2), plan_date: today },
    });
    assert.equal(task.status, 200);
    await api(`/api/v1/threads/${threadId}/items`, {
      method: "POST",
      body: { kind: "event", title: "现场量房", start_at: `${today}T10:00:00.000Z`, end_at: `${today}T11:30:00.000Z` },
    });
    await api(`/api/v1/threads/${threadId}/items`, {
      method: "POST",
      body: { kind: "direction", title: "探索开放式厨房的可行性" },
    });
    await api(`/api/v1/threads/${threadId}/items`, {
      method: "POST",
      body: { kind: "wait", title: "等设计师提供修订图", follow_up_date: addDays(today, 1) },
    });
    const bundle = (await api(`/api/v1/threads/${threadId}`)).body;
    assert.equal(bundle.items.open.length, 4);
    assert.equal(bundle.thread.counts.open_tasks, 1);
    assert.equal(bundle.thread.counts.open_events, 1);
    assert.equal(bundle.thread.counts.open_directions, 1);
    assert.equal(bundle.thread.counts.open_waits, 1);
  });

  it("探索方向不进入行动视图", async () => {
    const view = (await api(`/api/v1/views/actions?domain_id=${domainId}`)).body;
    const kinds = view.groups.flatMap((group) => group.items.map((item) => item.kind));
    assert.ok(!kinds.includes("direction"));
    assert.ok(!kinds.includes("wait"));
    assert.equal(kinds.length, 2);
  });

  it("完成待办会记录日志、离开未结束列表", async () => {
    const bundle = (await api(`/api/v1/threads/${threadId}`)).body;
    const task = bundle.items.open.find((item) => item.kind === "task");
    const patched = await api(`/api/v1/items/${task.id}`, { method: "PATCH", body: { status: "done" } });
    assert.equal(patched.status, 200);
    assert.equal(patched.body.item.status, "done");
    assert.ok(patched.body.bundle.logs.some((log) => log.action === "item.done"));
    assert.equal(patched.body.bundle.thread.counts.open_tasks, 0);
  });

  it("改期会留下可读的日志", async () => {
    const bundle = (await api(`/api/v1/threads/${threadId}`)).body;
    const event = bundle.items.open.find((item) => item.kind === "event");
    const patched = await api(`/api/v1/items/${event.id}`, {
      method: "PATCH",
      body: { start_at: `${addDays(today, 3)}T09:00:00.000Z` },
    });
    const reschedule = patched.body.bundle.logs.find((log) => log.action === "item.rescheduled");
    assert.ok(reschedule.text.includes("开始"));
  });

  it("探索方向可以转成待办并保留来源", async () => {
    const bundle = (await api(`/api/v1/threads/${threadId}`)).body;
    const direction = bundle.items.open.find((item) => item.kind === "direction");
    const converted = await api(`/api/v1/items/${direction.id}/convert`, { method: "POST", body: {} });
    assert.equal(converted.status, 200);
    assert.equal(converted.body.direction.status, "converted");
    assert.equal(converted.body.task.source_id, direction.id);
    assert.equal(converted.body.task.kind, "task");
  });

  it("事项可以在 Thread 之间移动，两端都有日志", async () => {
    const target = await api("/api/v1/threads", {
      method: "POST",
      body: { domain_id: domainId, title: "家具采购" },
    });
    const bundle = (await api(`/api/v1/threads/${threadId}`)).body;
    const item = bundle.items.open.find((entry) => entry.kind === "wait");
    const moved = await api(`/api/v1/items/${item.id}/move`, { method: "POST", body: { thread_id: target.body.thread.id } });
    assert.equal(moved.status, 200);
    assert.ok(moved.body.bundle.logs.some((log) => log.action === "item.received"));
    assert.ok(moved.body.from.logs.some((log) => log.action === "item.moved"));
    assert.equal(moved.body.bundle.items.open.length, 1);
  });

  it("非法类型与非法日期被拒绝", async () => {
    const badKind = await api(`/api/v1/threads/${threadId}/items`, { method: "POST", body: { kind: "todo", title: "x" } });
    assert.equal(badKind.status, 400);
    const badDate = await api(`/api/v1/threads/${threadId}/items`, {
      method: "POST",
      body: { kind: "task", title: "x", due_date: "2026-13-45" },
    });
    assert.equal(badDate.status, 400);
    const missingThread = await api("/api/v1/threads/th_missing/items", { method: "POST", body: { kind: "task", title: "x" } });
    assert.equal(missingThread.status, 404);
  });
});

describe("笔记与日志", () => {
  let threadId;

  before(async () => {
    const snapshot = (await api("/api/v1/snapshot")).body;
    threadId = snapshot.threads.find((t) => !t.is_inbox).id;
  });

  it("笔记可以读取、覆写，并且每个 Thread 只有一份", async () => {
    const before = (await api(`/api/v1/threads/${threadId}/note`)).body.note;
    assert.ok(typeof before.content === "string");
    await api(`/api/v1/threads/${threadId}/note`, { method: "PUT", body: { content: "尺寸、链接和没想清楚的问题" } });
    const after = (await api(`/api/v1/threads/${threadId}/note`)).body.note;
    assert.equal(after.content, "尺寸、链接和没想清楚的问题");
    assert.ok(after.updated_at);
  });

  it("记录一条进展会出现在日志顶部，标记为主要权重", async () => {
    const res = await api(`/api/v1/threads/${threadId}/logs`, { method: "POST", body: { text: "排除了方案 A，因为通道宽度不足。" } });
    assert.equal(res.status, 200);
    assert.equal(res.body.logs[0].kind, "progress");
    assert.equal(res.body.logs[0].text, "排除了方案 A，因为通道宽度不足。");
  });

  it("日志是时间顺序，操作记录权重更弱", async () => {
    const logs = (await api(`/api/v1/threads/${threadId}/logs`)).body.logs;
    assert.ok(logs.length >= 2);
    assert.ok(logs.some((log) => log.kind === "operation"));
    for (let i = 1; i < logs.length; i += 1) {
      assert.ok(logs[i - 1].created_at >= logs[i].created_at);
    }
  });
});

describe("总览视图", () => {
  let domainId;
  const today = toDateKey();

  before(async () => {
    const domain = await api("/api/v1/domains", { method: "POST", body: { name: "总览领域" } });
    domainId = domain.body.domain.id;
    const thread = await api("/api/v1/threads", {
      method: "POST",
      body: { domain_id: domainId, title: "总览线索", summary: "覆盖四种分组。" },
    });
    const id = thread.body.thread.id;
    await api(`/api/v1/threads/${id}/items`, {
      method: "POST",
      body: { kind: "task", title: "今天要做的事", plan_date: today },
    });
    await api(`/api/v1/threads/${id}/items`, {
      method: "POST",
      body: { kind: "task", title: "已经逾期的事", due_date: addDays(today, -3) },
    });
    await api(`/api/v1/threads/${id}/items`, {
      method: "POST",
      body: { kind: "task", title: "计划日已过的事", plan_date: addDays(today, -2) },
    });
    await api(`/api/v1/threads/${id}/items`, {
      method: "POST",
      body: {
        kind: "event",
        title: "昨天结束的日程",
        start_at: `${addDays(today, -1)}T01:00:00.000Z`,
        end_at: `${addDays(today, -1)}T02:00:00.000Z`,
      },
    });
    await api(`/api/v1/threads/${id}/items`, {
      method: "POST",
      body: { kind: "task", title: "没有日期的待办" },
    });
    await api(`/api/v1/threads/${id}/items`, {
      method: "POST",
      body: { kind: "wait", title: "今天要跟进的等待", follow_up_date: today },
    });
  });

  it("今天视图按关注原因分组，且同一事项只出现一次", async () => {
    const view = (await api(`/api/v1/views/today?domain_id=${domainId}`)).body;
    const keys = view.groups.map((group) => group.key);
    assert.ok(keys.includes("today"));
    assert.ok(keys.includes("overdue"));
    assert.ok(keys.includes("to_reschedule"));
    assert.ok(keys.includes("past_events"));

    const ids = view.groups.flatMap((group) => group.entries.map((entry) => entry.item.id));
    assert.equal(ids.length, new Set(ids).size, "同一事项不应重复出现");

    const overdue = view.groups.find((group) => group.key === "overdue");
    assert.equal(overdue.entries[0].item.title, "已经逾期的事");
    assert.equal(overdue.entries[0].thread.title, "总览线索");
  });

  it("等待默认不进入今天，可以按需包含", async () => {
    const plain = (await api(`/api/v1/views/today?domain_id=${domainId}`)).body;
    assert.ok(!plain.groups.some((group) => group.key === "follow_ups"));
    const withWaits = (await api(`/api/v1/views/today?domain_id=${domainId}&include_waits=1`)).body;
    const followUps = withWaits.groups.find((group) => group.key === "follow_ups");
    assert.equal(followUps.count, 1);
  });

  it("行动视图支持有时间 / 无时间 / 近期筛选", async () => {
    const all = (await api(`/api/v1/views/actions?domain_id=${domainId}`)).body;
    assert.equal(all.total, 5, "待办 4 条 + 日程 1 条");

    const without = (await api(`/api/v1/views/actions?domain_id=${domainId}&dates=without`)).body;
    assert.equal(without.total, 1);
    assert.equal(without.groups[0].items[0].title, "没有日期的待办");

    const withDates = (await api(`/api/v1/views/actions?domain_id=${domainId}&dates=with`)).body;
    assert.equal(withDates.total, 4);

    const upcoming = (await api(`/api/v1/views/actions?domain_id=${domainId}&range=upcoming7`)).body;
    assert.ok(upcoming.total <= withDates.total);
    assert.ok(upcoming.groups.flatMap((g) => g.items).every((item) => (item.plan_date ?? item.due_date ?? item.start_at) >= today));
  });

  it("收件箱聚合多个 Domain 的收集内容", async () => {
    const inboxThread = (await api(`/api/v1/threads?domain_id=${domainId}`)).body.threads.find((t) => t.is_inbox);
    await api(`/api/v1/threads/${inboxThread.id}/items`, {
      method: "POST",
      body: { kind: "task", title: "收下来还没整理的事" },
    });
    const inbox = (await api("/api/v1/views/inbox")).body;
    assert.ok(inbox.total >= 1);
    const group = inbox.groups.find((entry) => entry.thread.id === inboxThread.id);
    assert.ok(group);
    assert.equal(group.domain.name, "总览领域");
    assert.ok(group.items.every((item) => item.status === "open"));
  });

  it("搜索同时覆盖 Thread 与事项", async () => {
    const res = (await api("/api/v1/search?q=逾期")).body;
    assert.ok(res.items.some((item) => item.title.includes("逾期")));
    const threadHit = (await api("/api/v1/search?q=总览线索")).body;
    assert.equal(threadHit.threads[0].title, "总览线索");
  });

  it("快照包含全部实体，供客户端首屏使用", async () => {
    const snapshot = (await api("/api/v1/snapshot")).body;
    assert.ok(snapshot.domains.length > 0);
    assert.ok(snapshot.threads.length > 0);
    assert.ok(snapshot.items.length > 0);
    assert.ok(Array.isArray(snapshot.logs));
    assert.ok(snapshot.server_time);
  });
});

describe("鉴权", () => {
  it("配置令牌后，无令牌请求被拒绝，带令牌通过", async () => {
    const secured = await listen({ port: 0, host: "127.0.0.1", dbFile: ":memory:", apiKey: "secret-token", logger: { error() {} } });
    const securedBase = `http://127.0.0.1:${secured.server.address().port}`;
    try {
      const health = await fetch(`${securedBase}/health`);
      assert.equal(health.status, 200, "健康检查不需要令牌");
      const denied = await fetch(`${securedBase}/api/v1/snapshot`);
      assert.equal(denied.status, 401);
      const allowed = await fetch(`${securedBase}/api/v1/snapshot`, { headers: { authorization: "Bearer secret-token" } });
      assert.equal(allowed.status, 200);
    } finally {
      await secured.close();
    }
  });
});

describe("持久化", () => {
  it("数据写入 sqlite 文件后可以重新打开", async () => {
    const db = openDatabase(":memory:");
    const repo = createRepository(db);
    const domain = repo.createDomain({ name: "持久化" });
    const thread = repo.createThread({ domainId: domain.id, title: "写盘" });
    repo.createItem(thread.id, { kind: "task", title: "落库的待办" });
    const bundle = repo.threadBundle(thread.id);
    assert.equal(bundle.items.open[0].title, "落库的待办");
    db.close();
  });
});
