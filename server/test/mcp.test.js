import assert from "node:assert/strict";
import { after, before, describe, it } from "node:test";
import { authorizeClient, bootstrapOwner, exchangeCode, mcpCall, startServer } from "./support.mjs";

async function callTool(ctx, token, name, args, id = 7) {
  const response = await mcpCall(ctx, {
    token,
    method: "tools/call",
    params: { name, arguments: args },
    id,
  });
  assert.equal(response.status, 200, response.text);
  const result = response.json.result;
  const payload = result.structuredContent ?? null;
  return { isError: result.isError, text: result.content[0].text, payload, result };
}

describe("MCP 协议", () => {
  let ctx;
  before(async () => {
    ctx = await startServer();
  });
  after(async () => {
    await ctx.close();
  });

  it("initialize 返回协议版本、能力，以及内嵌的 skill 说明", async () => {
    const response = await mcpCall(ctx, {
      method: "initialize",
      params: {
        protocolVersion: "2025-06-18",
        capabilities: {},
        clientInfo: { name: "test-client", version: "1" },
      },
    });
    assert.equal(response.status, 200);
    const { result } = response.json;
    assert.equal(result.protocolVersion, "2025-06-18");
    assert.equal(result.serverInfo.name, "thread-pocket");
    assert.deepEqual(result.capabilities.tools, { listChanged: false });
    assert.ok(result.instructions.length > 1000, "instructions 就是 skill 描述本身");
    assert.ok(result.instructions.includes("收件箱"), "包含归类与收录约定");
    assert.ok(result.instructions.includes("resolve_thread"));
    assert.ok(result.instructions.includes("不要编造"));
    assert.ok(result.instructions.includes("revision"));
  });

  it("协议版本协商：不认识的版本回落到服务端支持的最新版", async () => {
    const response = await mcpCall(ctx, {
      method: "initialize",
      params: { protocolVersion: "1999-01-01" },
    });
    assert.equal(response.json.result.protocolVersion, "2025-06-18");
  });

  it("tools/list 给出完整定义与只读标记", async () => {
    const response = await mcpCall(ctx, { method: "tools/list" });
    const tools = response.json.result.tools;
    const names = tools.map((tool) => tool.name);
    for (const expected of ["resolve_thread", "get_thread", "upsert_entries", "append_log", "write_note", "list_overview", "search"]) {
      assert.ok(names.includes(expected), `缺少工具 ${expected}`);
    }
    for (const tool of tools) {
      assert.ok(tool.description.length > 20, `${tool.name} 需要可读的描述`);
      assert.ok(tool.inputSchema.type === "object");
      assert.equal(typeof tool.annotations.readOnlyHint, "boolean");
    }
    const readOnly = tools.filter((tool) => tool.annotations.readOnlyHint).map((tool) => tool.name);
    assert.deepEqual(readOnly.sort(), ["get_thread", "list_domains", "list_overview", "list_threads", "search"]);
    assert.equal(tools.find((tool) => tool.name === "delete_entry").annotations.destructiveHint, true);
  });

  it("通知不返回响应体", async () => {
    const response = await mcpCall(ctx, { method: "notifications/initialized" });
    assert.equal(response.status, 202);
    assert.equal(response.text, "");
  });

  it("非法请求给出 JSON-RPC 错误", async () => {
    const unknown = await mcpCall(ctx, { method: "resources/list" });
    assert.equal(unknown.json.error.code, -32601);

    const missing = await mcpCall(ctx, { method: "tools/call", params: {} });
    assert.equal(missing.json.error.code, -32602);

    const batch = await ctx.request("/mcp", {
      method: "POST",
      body: [{ jsonrpc: "2.0", id: 1, method: "ping" }],
    });
    assert.equal(batch.status, 400);
    assert.equal(batch.json.error.code, -32600);

    const broken = await ctx.request("/mcp", {
      method: "POST",
      body: undefined,
      headers: { "content-type": "application/json" },
    });
    assert.equal(broken.status, 200, "空请求体按无效 JSON-RPC 处理");
    assert.equal(broken.json.error.code, -32600);
  });

  it("GET 返回 405、DELETE 返回 204（无状态实现）", async () => {
    const get = await ctx.request("/mcp");
    assert.equal(get.status, 405);
    assert.ok(get.headers.get("allow").includes("POST"));
    const del = await ctx.request("/mcp", { method: "DELETE" });
    assert.equal(del.status, 204);
  });
});

describe("MCP 工具：Agent 的常规工作流", () => {
  let ctx;
  let domainId;
  let threadId;

  before(async () => {
    ctx = await startServer();
    // 用 REST 建立一条已有线索，模拟"人已经在用"的工作区
    const domains = await ctx.request("/api/v1/domains");
    domainId = domains.json.domains[0].id;
    const thread = await ctx.request("/api/v1/threads", {
      method: "POST",
      body: { domain_id: domainId, title: "厨房方案", summary: "已确定方案 B。" },
    });
    threadId = thread.json.thread.id;
  });
  after(async () => {
    await ctx.close();
  });

  it("resolve_thread 对同名 Domain 落到收件箱，可重复调用且不重复创建", async () => {
    const first = await callTool(ctx, null, "resolve_thread", { topic: "装修", create_if_missing: true });
    assert.equal(first.isError, false);
    assert.equal(first.payload.created, true);
    assert.equal(first.payload.thread.is_inbox, true);
    assert.equal(first.payload.matched_by, "created_domain");

    const second = await callTool(ctx, null, "resolve_thread", { topic: "装修", create_if_missing: true });
    assert.equal(second.payload.thread.thread_id, first.payload.thread.thread_id);
    assert.equal(second.payload.matched_by, "inbox");
    assert.equal(second.payload.created, false);
  });

  it("resolve_thread 能找到同名线索，而不是退回收件箱", async () => {
    const found = await callTool(ctx, null, "resolve_thread", { topic: "厨房方案" });
    assert.equal(found.payload.matched_by, "thread");
    assert.equal(found.payload.thread.thread_id, threadId);
  });

  it("resolve_thread(thread_title) 在指定 Domain 下新建线索", async () => {
    const created = await callTool(ctx, null, "resolve_thread", {
      topic: "装修",
      thread_title: "选材",
      create_if_missing: true,
    });
    assert.equal(created.payload.created, true);
    assert.equal(created.payload.thread.title, "选材");
  });

  it("upsert_entries 批量写入并返回新 revision", async () => {
    const before = await callTool(ctx, null, "get_thread", { thread_id: threadId });
    const revision = before.payload.thread.revision;

    const written = await callTool(ctx, null, "upsert_entries", {
      thread_id: threadId,
      expected_revision: revision,
      entries: [
        { id: "entry_quote", kind: "task", title: "核对报价中的增项", due_date: "2026-09-18", plan_date: "2026-09-16" },
        { id: "entry_wait", kind: "wait", title: "等设计师提供修订图", follow_up_date: "2026-09-17" },
        { id: "entry_idea", kind: "direction", title: "探索开放式厨房的可行性" },
        { id: "entry_measure", kind: "event", title: "现场量房", start_at: "2026-09-17T10:00:00.000Z", end_at: "2026-09-17T11:30:00.000Z" },
      ],
    });
    assert.equal(written.isError, false);
    assert.equal(written.payload.written.length, 4);
    assert.equal(written.payload.written[0].kind, "task");
    assert.ok(written.payload.revision > revision);
    assert.equal(written.payload.entries.length, 4);
  });

  it("整批写入是原子的：其中一条失败则全部不生效", async () => {
    const before = await callTool(ctx, null, "get_thread", { thread_id: threadId });
    const failed = await callTool(ctx, null, "upsert_entries", {
      thread_id: threadId,
      expected_revision: before.payload.thread.revision,
      entries: [
        { id: "entry_ok", kind: "task", title: "这条不该被写入" },
        { id: "entry_bad", kind: "不存在的类型", title: "坏数据" },
      ],
    });
    assert.equal(failed.isError, true);
    const after = await callTool(ctx, null, "get_thread", { thread_id: threadId });
    assert.ok(!after.payload.entries.some((entry) => entry.id === "entry_ok"));
  });

  it("revision 过期时拒绝写入并提示先重新读取", async () => {
    const stale = await callTool(ctx, null, "upsert_entries", {
      thread_id: threadId,
      expected_revision: 1,
      entries: [{ id: "entry_new", kind: "task", title: "基于旧版本" }],
    });
    assert.equal(stale.isError, true);
    assert.ok(stale.text.includes("revision_conflict"));
    assert.ok(stale.text.includes("重新 get_thread"));
  });

  it("更新条目：改期与完成", async () => {
    const done = await callTool(ctx, null, "update_entry", {
      entry_id: "entry_quote",
      entry: { status: "done" },
    });
    assert.equal(done.payload.entry.status, "done");

    const rescheduled = await callTool(ctx, null, "update_entry", {
      entry_id: "entry_wait",
      entry: { follow_up_date: "2026-09-19" },
    });
    assert.equal(rescheduled.payload.entry.follow_up_date, "2026-09-19");
  });

  it("当前描述会写入日志，日志记录用户给出的时间", async () => {
    const updated = await callTool(ctx, null, "update_thread", {
      thread_id: threadId,
      summary: "方案 B 已定，等修订图后核对预算。",
    });
    assert.equal(updated.payload.thread.summary, "方案 B 已定，等修订图后核对预算。");
    const summaryLog = updated.payload.logs.find((log) => log.text.includes("更新了当前描述"));
    assert.ok(summaryLog, "应自动记录当前描述的修改");

    const logged = await callTool(ctx, null, "append_log", {
      thread_id: threadId,
      text: "排除了方案 A，因为通道宽度不足。",
      occurred_at: "2026-09-15T02:00:00.000Z",
      actor: "claude",
    });
    assert.equal(logged.isError, false);
    const backfilled = logged.payload.logs.find((log) => log.text === "排除了方案 A，因为通道宽度不足。");
    assert.ok(backfilled, "补记的日志应该写入");
    assert.equal(backfilled.actor, "claude");
    assert.equal(backfilled.at, "2026-09-15T02:00:00.000Z");
    // 补记历史时间不会插到最新位置：日志按写入顺序，而不是按补记的时间重排
    assert.equal(logged.payload.logs[0].text, "更新了当前描述。");
  });

  it("笔记可读写且是一份完整覆盖", async () => {
    await callTool(ctx, null, "write_note", { thread_id: threadId, content: "- 台面 600\n- 通道 ≥ 900" });
    const read = await callTool(ctx, null, "get_thread", { thread_id: threadId });
    assert.equal(read.payload.note, "- 台面 600\n- 通道 ≥ 900");
  });

  it("条目可以在线索之间移动", async () => {
    const target = await callTool(ctx, null, "create_thread", { title: "家具采购", domain: "装修" });
    const targetId = target.payload.thread.thread_id;
    const moved = await callTool(ctx, null, "move_entry", { entry_id: "entry_idea", thread_id: targetId });
    assert.equal(moved.payload.to.entries.some((entry) => entry.id === "entry_idea"), true);
    assert.ok(moved.payload.from.logs.some((log) => log.text.includes("移动到")));
  });

  it("总览与搜索都能读到刚写入的内容", async () => {
    const today = await callTool(ctx, null, "list_overview", { view: "today" });
    assert.equal(today.payload.view, "today");
    assert.ok(Array.isArray(today.payload.groups));

    const actions = await callTool(ctx, null, "list_overview", { view: "actions" });
    const threadGroup = actions.payload.groups.find((group) => group.thread_id === threadId);
    assert.ok(threadGroup, "行动视图应包含这条线索");

    const inbox = await callTool(ctx, null, "list_overview", { view: "inbox" });
    assert.ok(inbox.payload.total >= 0);

    const found = await callTool(ctx, null, "search", { query: "家具采购" });
    assert.ok(found.payload.threads.some((thread) => thread.title === "家具采购"));
  });

  it("删除条目后不再出现在未结束列表", async () => {
    const removed = await callTool(ctx, null, "delete_entry", { entry_id: "entry_measure" });
    assert.equal(removed.payload.deleted, "entry_measure");
    const after = await callTool(ctx, null, "get_thread", { thread_id: threadId });
    assert.ok(!after.payload.entries.some((entry) => entry.id === "entry_measure"));
  });

  it("工具错误以 isError 返回，而不是协议错误", async () => {
    const missing = await callTool(ctx, null, "get_thread", {});
    assert.equal(missing.isError, true);
    assert.ok(missing.text.includes("缺少参数 thread_id"));

    const unknownThread = await callTool(ctx, null, "get_thread", { thread_id: "th_不存在" });
    assert.equal(unknownThread.isError, true);
    assert.ok(unknownThread.text.includes("Thread 不存在"));

    const badDate = await callTool(ctx, null, "upsert_entries", {
      thread_id: threadId,
      entries: [{ id: "entry_x", kind: "task", title: "x", due_date: "2026/09/18" }],
    });
    assert.equal(badDate.isError, true);
    assert.ok(badDate.text.includes("YYYY-MM-DD"));
  });

  it("未知工具给出可用工具清单", async () => {
    const response = await callTool(ctx, null, "不存在的工具", {});
    assert.equal(response.isError, true);
    assert.ok(response.text.includes("upsert_entries"));
  });
});

describe("MCP 鉴权", () => {
  let ctx;
  let owner;

  before(async () => {
    ctx = await startServer({ env: { THREADPOCKET_PUBLIC_URL: "https://pocket.example.com", HOST: "0.0.0.0" } });
    owner = await bootstrapOwner(ctx);
  });
  after(async () => {
    await ctx.close();
  });

  it("没有令牌时 401，并带上资源元信息用于自动发现", async () => {
    const response = await mcpCall(ctx, { method: "tools/list" });
    assert.equal(response.status, 401);
    assert.ok(response.headers.get("www-authenticate").includes("oauth-protected-resource/mcp"));
  });

  it("只有 threads:read 的令牌不能调用 MCP 工具", async () => {
    const flow = await authorizeClient(ctx, { cookie: owner.cookie, scope: "threads:read" });
    const token = await exchangeCode(ctx, flow);
    const response = await mcpCall(ctx, { token: token.json.access_token, method: "tools/list" });
    assert.equal(response.status, 403);
    assert.ok(response.headers.get("www-authenticate").includes("mcp:tools"));
  });

  it("带 mcp:tools 的令牌可以正常调用", async () => {
    const flow = await authorizeClient(ctx, { cookie: owner.cookie });
    const token = await exchangeCode(ctx, flow);
    const list = await mcpCall(ctx, { token: token.json.access_token, method: "tools/list" });
    assert.equal(list.status, 200);

    const created = await callTool(ctx, token.json.access_token, "create_thread", {
      title: "公网部署后的第一条线索",
    });
    assert.equal(created.isError, false);
    assert.equal(created.payload.thread.title, "公网部署后的第一条线索");
  });

  it("失效令牌返回 invalid_token 而不是回落成本机豁免", async () => {
    const flow = await authorizeClient(ctx, { cookie: owner.cookie });
    const token = await exchangeCode(ctx, flow);
    await ctx.request("/oauth/revoke", {
      method: "POST",
      form: true,
      body: { token: token.json.access_token },
    });
    const response = await mcpCall(ctx, { token: token.json.access_token, method: "tools/list" });
    assert.equal(response.status, 401);
    assert.ok(response.headers.get("www-authenticate").includes("invalid_token"));
  });
});
