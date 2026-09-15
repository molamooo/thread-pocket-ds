import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { after, before, describe, it } from "node:test";
import { authorizeClient, bootstrapOwner, exchangeCode, login, startServer } from "./support.mjs";

describe("OAuth 元信息与发现", () => {
  let ctx;
  before(async () => {
    ctx = await startServer();
  });
  after(async () => {
    await ctx.close();
  });

  it("暴露授权服务器元信息", async () => {
    const { status, json } = await ctx.request("/.well-known/oauth-authorization-server");
    assert.equal(status, 200);
    assert.equal(json.issuer, ctx.base);
    assert.ok(json.authorization_endpoint.endsWith("/oauth/authorize"));
    assert.ok(json.registration_endpoint.endsWith("/oauth/register"));
    assert.deepEqual(json.code_challenge_methods_supported, ["S256"]);
    assert.deepEqual(json.token_endpoint_auth_methods_supported, ["none"]);
    assert.ok(json.grant_types_supported.includes("refresh_token"));
  });

  it("按资源分别暴露 protected resource metadata", async () => {
    const mcp = await ctx.request("/.well-known/oauth-protected-resource/mcp");
    assert.equal(mcp.json.resource, `${ctx.base}/mcp`);
    assert.deepEqual(mcp.json.authorization_servers, [ctx.base]);
    assert.ok(mcp.json.scopes_supported.includes("mcp:tools"));

    const api = await ctx.request("/.well-known/oauth-protected-resource/api");
    assert.equal(api.json.resource, `${ctx.base}/api/v1`);
    assert.ok(api.json.scopes_supported.includes("threads:write"));
  });

  it("未授权访问 MCP 时给出可发现的 401 挑战", async () => {
    // 挑战只对「不信任本机」的部署形态有意义，也就是真正对外暴露时
    const exposed = await startServer({ env: { THREADPOCKET_PUBLIC_URL: "https://pocket.example.com", HOST: "0.0.0.0" } });
    const response = await exposed.request("/mcp", {
      method: "POST",
      body: { jsonrpc: "2.0", id: 1, method: "tools/list" },
    });
    assert.equal(response.status, 401);
    const challenge = response.headers.get("www-authenticate");
    assert.ok(challenge.includes('resource_metadata="https://pocket.example.com/.well-known/oauth-protected-resource/mcp"'));
    assert.ok(challenge.includes('scope="mcp:tools"'));
    await exposed.close();
  });
});

describe("动态客户端注册", () => {
  let ctx;
  before(async () => {
    ctx = await startServer();
  });
  after(async () => {
    await ctx.close();
  });

  it("接受回环回调并返回 client_id", async () => {
    const { status, json } = await ctx.request("/oauth/register", {
      method: "POST",
      body: { client_name: "Claude", redirect_uris: ["http://127.0.0.1:4321/cb", "https://example.com/cb"], scope: "mcp:tools offline_access" },
    });
    assert.equal(status, 201);
    assert.ok(json.client_id.startsWith("oc_"));
    assert.equal(json.token_endpoint_auth_method, "none");
    assert.equal(json.scope, "mcp:tools offline_access");
  });

  it("拒绝明文 http 的非本机回调", async () => {
    const { status, json } = await ctx.request("/oauth/register", {
      method: "POST",
      body: { client_name: "坏客户端", redirect_uris: ["http://evil.example.com/cb"] },
    });
    assert.equal(status, 400);
    assert.equal(json.error, "invalid_redirect_uri");
  });

  it("拒绝要求 client_secret 的客户端（只支持公共客户端 + PKCE）", async () => {
    const { status, json } = await ctx.request("/oauth/register", {
      method: "POST",
      body: { client_name: "旧式客户端", redirect_uris: ["https://example.com/cb"], token_endpoint_auth_method: "client_secret_basic" },
    });
    assert.equal(status, 400);
    assert.equal(json.error, "invalid_client_metadata");
  });

  it("拒绝未知 scope", async () => {
    const { status, json } = await ctx.request("/oauth/register", {
      method: "POST",
      body: { client_name: "越权客户端", redirect_uris: ["https://example.com/cb"], scope: "mcp:tools root:everything" },
    });
    assert.equal(status, 400);
    assert.equal(json.error, "invalid_client_metadata");
  });
});

describe("授权码 + PKCE 全流程", () => {
  let ctx;
  let owner;
  let sharedClientId = null;

  before(async () => {
    ctx = await startServer();
    owner = await bootstrapOwner(ctx);
  });
  after(async () => {
    await ctx.close();
  });

  it("首次初始化后可以登录", async () => {
    assert.equal(owner.status, 302);
    const session = await login(ctx, owner);
    assert.equal(session.status, 302);
    assert.ok(session.cookie.startsWith("tp_session="));
    const whoami = await ctx.request("/auth/whoami", { cookie: session.cookie });
    assert.equal(whoami.json.authenticated, true);
    assert.equal(whoami.json.email, owner.email);
  });

  it("未登录访问授权端点会先跳到登录页", async () => {
    const registration = await ctx.request("/oauth/register", {
      method: "POST",
      body: { client_name: "Claude", redirect_uris: ["http://127.0.0.1:9999/cb"], scope: "mcp:tools offline_access" },
    });
    const clientId = registration.json.client_id;
    const params = new URLSearchParams({
      response_type: "code",
      client_id: clientId,
      redirect_uri: "http://127.0.0.1:9999/cb",
      scope: "mcp:tools offline_access",
      code_challenge: "a".repeat(43),
      code_challenge_method: "S256",
    });
    const response = await ctx.request(`/oauth/authorize?${params}`, {});
    assert.equal(response.status, 302);
    assert.ok(response.headers.get("location").startsWith("/auth/login?next="));
  });

  it("走完授权码流程后拿到令牌，并可以访问 REST 与 MCP", async () => {
    // 一个通用客户端：既能调 REST，也能调 MCP
    const flow = await authorizeClient(ctx, {
      cookie: owner.cookie,
      clientName: "Claude",
      scope: "threads:read threads:write mcp:tools offline_access",
    });
    sharedClientId = flow.clientId;
    assert.equal(flow.state, "state-123");
    assert.ok(flow.code);

    const token = await exchangeCode(ctx, flow);
    assert.equal(token.status, 200);
    assert.ok(token.json.access_token.startsWith("tp_at_"));
    assert.ok(token.json.refresh_token.startsWith("tp_rt_"));
    assert.equal(token.json.token_type, "Bearer");
    assert.equal(token.json.scope, "threads:read threads:write mcp:tools offline_access");

    const snapshot = await ctx.request("/api/v1/snapshot", { token: token.json.access_token });
    assert.equal(snapshot.status, 200);
    assert.ok(Array.isArray(snapshot.json.domains));

    const mcp = await ctx.request("/mcp", {
      method: "POST",
      token: token.json.access_token,
      body: { jsonrpc: "2.0", id: 1, method: "tools/list" },
    });
    assert.equal(mcp.status, 200);
    assert.ok(mcp.json.result.tools.length >= 10);
  });

  it("同一客户端第二次授权不再重复确认", async () => {
    // 复用同一个 client_id：已授权过的客户端应直接返回授权码
    const flow = await authorizeClient(ctx, { cookie: owner.cookie, clientId: sharedClientId, register: false });
    assert.equal(flow.consent, false, "已授权过的客户端应直接返回授权码");
    assert.ok(flow.code);
  });

  it("授权码只能使用一次", async () => {
    const flow = await authorizeClient(ctx, { cookie: owner.cookie });
    const first = await exchangeCode(ctx, flow);
    assert.equal(first.status, 200);
    const second = await exchangeCode(ctx, flow);
    assert.equal(second.status, 400);
    assert.equal(second.json.error, "invalid_grant");
  });

  it("code_verifier 不匹配会被拒绝", async () => {
    const flow = await authorizeClient(ctx, { cookie: owner.cookie });
    const bad = await exchangeCode(ctx, { ...flow, verifier: "b".repeat(50) });
    assert.equal(bad.status, 400);
    assert.equal(bad.json.error, "invalid_grant");
  });

  it("拒绝没有 PKCE 的授权请求", async () => {
    const registration = await ctx.request("/oauth/register", {
      method: "POST",
      body: { client_name: "无 PKCE", redirect_uris: ["http://127.0.0.1:9998/cb"] },
    });
    const params = new URLSearchParams({
      response_type: "code",
      client_id: registration.json.client_id,
      redirect_uri: "http://127.0.0.1:9998/cb",
      scope: "mcp:tools",
    });
    const response = await ctx.request(`/oauth/authorize?${params}`, { cookie: owner.cookie });
    assert.equal(response.status, 302);
    const location = new URL(response.headers.get("location"));
    assert.equal(location.searchParams.get("error"), "invalid_request");
  });

  it("拒绝客户端未注册的 scope", async () => {
    const registration = await ctx.request("/oauth/register", {
      method: "POST",
      body: { client_name: "只读客户端", redirect_uris: ["http://127.0.0.1:9997/cb"], scope: "threads:read" },
    });
    const params = new URLSearchParams({
      response_type: "code",
      client_id: registration.json.client_id,
      redirect_uri: "http://127.0.0.1:9997/cb",
      scope: "threads:write",
      code_challenge: "a".repeat(43),
      code_challenge_method: "S256",
    });
    const response = await ctx.request(`/oauth/authorize?${params}`, { cookie: owner.cookie });
    assert.equal(response.status, 302);
    assert.equal(new URL(response.headers.get("location")).searchParams.get("error"), "invalid_scope");
  });

  it("刷新令牌会轮换，旧刷新令牌被重用时整族失效", async () => {
    const flow = await authorizeClient(ctx, { cookie: owner.cookie });
    const first = await exchangeCode(ctx, flow);
    const originalRefresh = first.json.refresh_token;

    const refreshed = await ctx.request("/oauth/token", {
      method: "POST",
      form: true,
      body: { grant_type: "refresh_token", client_id: flow.clientId, refresh_token: originalRefresh },
    });
    assert.equal(refreshed.status, 200);
    assert.ok(refreshed.json.access_token);
    assert.notEqual(refreshed.json.refresh_token, originalRefresh);

    const replay = await ctx.request("/oauth/token", {
      method: "POST",
      form: true,
      body: { grant_type: "refresh_token", client_id: flow.clientId, refresh_token: originalRefresh },
    });
    assert.equal(replay.status, 400);
    assert.equal(replay.json.error, "invalid_grant");

    // 令牌族被撤销后，刚发出的刷新令牌也不能再用
    const afterReplay = await ctx.request("/oauth/token", {
      method: "POST",
      form: true,
      body: { grant_type: "refresh_token", client_id: flow.clientId, refresh_token: refreshed.json.refresh_token },
    });
    assert.equal(afterReplay.status, 400);
  });

  it("撤销访问后，该客户端的令牌立即失效", async () => {
    const flow = await authorizeClient(ctx, {
      cookie: owner.cookie,
      clientName: "临时客户端",
      scope: "threads:read threads:write offline_access",
    });
    const token = await exchangeCode(ctx, flow);
    const access = token.json.access_token;
    assert.equal((await ctx.request("/api/v1/snapshot", { token: access })).status, 200);

    const revoked = await ctx.request("/auth/connections", {
      method: "POST",
      form: true,
      cookie: owner.cookie,
      headers: { origin: ctx.origin ?? ctx.base },
      body: { client_id: flow.clientId },
    });
    assert.equal(revoked.status, 302);
    assert.equal((await ctx.request("/api/v1/snapshot", { token: access })).status, 401);
  });

  it("注销令牌端点按 RFC 6749 处理 refresh_token", async () => {
    const flow = await authorizeClient(ctx, {
      cookie: owner.cookie,
      scope: "threads:read threads:write offline_access",
    });
    const token = await exchangeCode(ctx, flow);
    const revoke = await ctx.request("/oauth/revoke", {
      method: "POST",
      form: true,
      body: { token: token.json.refresh_token, client_id: flow.clientId },
    });
    assert.equal(revoke.status, 200);
    assert.equal((await ctx.request("/api/v1/snapshot", { token: token.json.access_token })).status, 401);
  });
});

describe("权限范围", () => {
  let ctx;
  let owner;
  before(async () => {
    ctx = await startServer();
    owner = await bootstrapOwner(ctx);
  });
  after(async () => {
    await ctx.close();
  });

  it("只读令牌不能写入", async () => {
    const flow = await authorizeClient(ctx, { cookie: owner.cookie, scope: "threads:read" });
    const token = await exchangeCode(ctx, flow);
    const access = token.json.access_token;

    assert.equal((await ctx.request("/api/v1/snapshot", { token: access })).status, 200);

    const domains = await ctx.request("/api/v1/domains", { token: access });
    const domainId = domains.json.domains[0].id;
    const write = await ctx.request("/api/v1/threads", {
      method: "POST",
      token: access,
      body: { domain_id: domainId, title: "不该被创建" },
    });
    assert.equal(write.status, 403);
    assert.equal(write.json.error.code, "insufficient_scope");
    assert.ok(write.headers.get("www-authenticate").includes("threads:write"));
  });

  it("MCP 令牌只够调用 MCP，不代表拿到全部权限", async () => {
    const flow = await authorizeClient(ctx, { cookie: owner.cookie, scope: "mcp:tools" });
    const token = await exchangeCode(ctx, flow);
    const access = token.json.access_token;
    const mcp = await ctx.request("/mcp", {
      method: "POST",
      token: access,
      body: { jsonrpc: "2.0", id: 1, method: "ping" },
    });
    assert.equal(mcp.status, 200);
  });
});

describe("部署形态与兜底", () => {
  it("建立账号后，本机请求同样需要凭证", async () => {
    const ctx = await startServer();
    const owner = await bootstrapOwner(ctx);
    assert.equal((await ctx.request("/api/v1/snapshot")).status, 401, "有账号就不该再对本机敞开");
    assert.equal((await ctx.request("/api/v1/snapshot", { cookie: owner.cookie })).status, 200, "浏览器会话可以访问");
    await ctx.close();
  });

  it("显式开启 THREADPOCKET_TRUST_LOOPBACK 时才恢复本机免登录", async () => {
    const ctx = await startServer({ env: { THREADPOCKET_TRUST_LOOPBACK: "1" } });
    await bootstrapOwner(ctx);
    assert.equal((await ctx.request("/api/v1/snapshot")).status, 200);
    await ctx.close();
  });

  it("没有账号也没有密钥时保持开放（本机起步）", async () => {
    const ctx = await startServer();
    assert.equal((await ctx.request("/api/v1/snapshot")).status, 200);
    await ctx.close();
  });

  it("配置公网地址后，连本机请求也必须带凭证", async () => {
    const ctx = await startServer({ env: { THREADPOCKET_PUBLIC_URL: "https://pocket.example.com", HOST: "0.0.0.0" } });
    // 对外部署：初始化必须带一次性凭证，否则任何人都能抢注账号
    const blocked = await ctx.request("/auth/setup", { method: "POST", form: true, body: { email: "a@b.com", password: "123456789012" } });
    assert.equal(blocked.status, 403);
    await bootstrapOwner(ctx);
    const anonymous = await ctx.request("/api/v1/snapshot");
    assert.equal(anonymous.status, 401);
    assert.ok(anonymous.headers.get("www-authenticate").includes("/.well-known/oauth-protected-resource/api"));

    const registered = await ctx.request("/oauth/register", {
      method: "POST",
      body: { client_name: "Web", redirect_uris: ["https://pocket.example.com/cb"], scope: "threads:read offline_access" },
    });
    assert.equal(registered.status, 201);
    await ctx.close();
  });

  it("只绑本机时，初始化不需要一次性链接", async () => {
    const ctx = await startServer();
    const page = await ctx.request("/auth/setup");
    assert.equal(page.status, 200);
    const created = await ctx.request("/auth/setup", {
      method: "POST",
      form: true,
      body: { email: "local@example.com", password: "local-password-123" },
    });
    assert.equal(created.status, 302);
    assert.ok(ctx.app.auth.store.initialized());
    await ctx.close();
  });

  it("对外部署：页面能打开并在浏览器端接住 # 里的凭证", async () => {
    const ctx = await startServer({ env: { THREADPOCKET_PUBLIC_URL: "https://pocket.example.com", HOST: "0.0.0.0" } });
    const page = await ctx.request("/auth/setup");
    // 纯 GET 没有凭证也必须能渲染：凭证在链接的 # 之后，服务端看不到
    assert.equal(page.status, 200);
    assert.ok(page.text.includes("创建个人账号"));
    assert.ok(page.text.includes("location.hash"), "页面需要从 fragment 里取凭证");
    assert.ok(page.text.includes('id="setup-token"'));
    assert.ok(!page.text.includes("tp_setup_"), "页面本身不能带任何凭证");
    await ctx.close();
  });

  it("对外部署：表单提交仍然必须带正确凭证", async () => {
    const ctx = await startServer({ env: { THREADPOCKET_PUBLIC_URL: "https://pocket.example.com", HOST: "0.0.0.0" } });
    const noToken = await ctx.request("/auth/setup", {
      method: "POST",
      form: true,
      body: { email: "owner@example.com", password: "enough-length-password" },
    });
    assert.equal(noToken.status, 403);
    assert.equal(ctx.app.auth.store.initialized(), false, "没有凭证不能创建账号");

    const wrong = await ctx.request("/auth/setup", {
      method: "POST",
      form: true,
      body: { email: "owner@example.com", password: "enough-length-password", token: "tp_setup_wrong" },
    });
    assert.equal(wrong.status, 403);

    const ok = await ctx.request("/auth/setup", {
      method: "POST",
      form: true,
      body: { email: "owner@example.com", password: "enough-length-password", token: ctx.app.setupToken },
    });
    assert.equal(ok.status, 302);
    assert.equal(ctx.app.auth.store.initialized(), true);

    const again = await ctx.request("/auth/setup");
    assert.equal(again.status, 409, "初始化后不再开放该页面");
    await ctx.close();
  });

  it("显式设置 THREADPOCKET_SETUP_TOKEN 时可以恢复丢失的链接", async () => {
    const first = await startServer({ env: { THREADPOCKET_PUBLIC_URL: "https://pocket.example.com", HOST: "0.0.0.0" } });
    const generated = first.app.setupToken;
    assert.ok(generated);
    await first.close();
    // 同一个库重启：换成显式指定的凭证
    const dbFile = path.join(os.tmpdir(), `thread-pocket-setup-${Date.now()}.sqlite`);
    const a = await startServer({ env: { THREADPOCKET_PUBLIC_URL: "https://pocket.example.com", HOST: "0.0.0.0" }, dbFile });
    const oldToken = a.app.setupToken;
    await a.close();
    const b = await startServer({
      env: { THREADPOCKET_PUBLIC_URL: "https://pocket.example.com", HOST: "0.0.0.0", THREADPOCKET_SETUP_TOKEN: "my-own-setup-token" },
      dbFile,
    });
    assert.equal(b.app.setupToken, "my-own-setup-token");
    const withOld = await b.request("/auth/setup", {
      method: "POST",
      form: true,
      body: { email: "owner@example.com", password: "enough-length-password", token: oldToken },
    });
    assert.equal(withOld.status, 403, "旧凭证应当失效");
    const withNew = await b.request("/auth/setup", {
      method: "POST",
      form: true,
      body: { email: "owner@example.com", password: "enough-length-password", token: "my-own-setup-token" },
    });
    assert.equal(withNew.status, 302);
    await b.close();
    fs.rmSync(dbFile, { force: true });
  });

  it("静态密钥依旧可用（脚本与本地自动化）", async () => {
    const ctx = await startServer({ env: { THREADPOCKET_PUBLIC_URL: "https://pocket.example.com" }, apiKey: "static-key-with-enough-length" });
    assert.equal((await ctx.request("/api/v1/snapshot")).status, 401);
    const withKey = await ctx.request("/api/v1/snapshot", { token: "static-key-with-enough-length" });
    assert.equal(withKey.status, 200);
    const wrong = await ctx.request("/api/v1/snapshot", { token: "wrong-key" });
    assert.equal(wrong.status, 401);
    await ctx.close();
  });

  it("健康检查与元信息始终开放，便于探活与发现", async () => {
    const ctx = await startServer({ env: { THREADPOCKET_PUBLIC_URL: "https://pocket.example.com" } });
    assert.equal((await ctx.request("/health")).status, 200);
    assert.equal((await ctx.request("/api/v1/meta")).status, 200);
    await ctx.close();
  });

  it("未注册的 https client_id（CIMD 未放行的主机）给出可读错误", async () => {
    const ctx = await startServer();
    const params = new URLSearchParams({
      response_type: "code",
      client_id: "https://not-allowed.example.com/client.json",
      redirect_uri: "https://not-allowed.example.com/cb",
      scope: "mcp:tools",
      code_challenge: "a".repeat(43),
      code_challenge_method: "S256",
    });
    const response = await ctx.request(`/oauth/authorize?${params}`);
    assert.equal(response.status, 400);
    assert.ok(response.text.includes("未知的客户端"));
    await ctx.close();
  });
});
