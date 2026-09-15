import {
  ACCESS_TOKEN_TTL_SECONDS,
  ALL_SCOPES,
  APP_DEFAULT_SCOPES,
  MCP_DEFAULT_SCOPES,
  SCOPE_DEFINITIONS,
  isLoopbackHost,
  normalizeScopes,
} from "./config.js";
import { randomId, verifyPkce } from "./crypto.js";
import { bearerToken, readCookie, sessionCookieName } from "./guard.js";
import {
  consentPage,
  connectionsPage,
  escapeHtml,
  loginPage,
  messagePage,
  setupPage,
} from "./pages.js";

const PASSWORD_MIN_LENGTH = 12;
const RATE_LIMITS = {
  login: { limit: 10, window: 300 },
  setup: { limit: 5, window: 600 },
  register: { limit: 20, window: 600 },
  token: { limit: 60, window: 300 },
};

function json(status, payload, headers = {}) {
  return {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...headers },
    body: JSON.stringify(payload, null, 2),
  };
}

function html(status, body, headers = {}) {
  return {
    status,
    headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store", ...headers },
    body,
  };
}

function redirect(location, headers = {}) {
  return { status: 302, headers: { location, "cache-control": "no-store", ...headers }, body: "" };
}

function oauthError(status, error, description, headers = {}) {
  return json(status, { error, error_description: description }, headers);
}

/** 回调地址规则：HTTPS，或本机回环（RFC 8252）。回环地址忽略端口，方便桌面端使用随机端口。 */
function isAllowedRedirect(uri) {
  let parsed;
  try {
    parsed = new URL(uri);
  } catch {
    return false;
  }
  if (parsed.hash) return false;
  if (parsed.protocol === "https:") return true;
  if (parsed.protocol === "http:" && isLoopbackHost(parsed.hostname)) return true;
  // 原生应用的私有 scheme（如 com.example.app:/callback），拒绝 Web 协议以免被当成开放跳转
  const scheme = parsed.protocol.replace(/:$/, "").toLowerCase();
  if (["http", "https", "javascript", "data", "file", "blob"].includes(scheme)) return false;
  return /^[a-z][a-z0-9+.-]*$/.test(scheme);
}

function sameRedirectUri(requested, registered) {
  if (requested === registered) return true;
  try {
    const a = new URL(requested);
    const b = new URL(registered);
    if (a.protocol !== b.protocol || a.hostname !== b.hostname || a.pathname !== b.pathname || a.search !== b.search) {
      return false;
    }
    // 回环地址：仅端口不同视为同一个回调（RFC 8252 §7.3）
    return isLoopbackHost(a.hostname) && isLoopbackHost(b.hostname);
  } catch {
    return false;
  }
}

export function createAuthRoutes({ store, config, logger = console }) {
  /** 对外可见的 origin：优先显式配置，否则用请求自身的（仅本机开发场景）。 */
  function originOf(req) {
    if (config.publicOrigin) return config.publicOrigin;
    const proto = req.headers["x-forwarded-proto"]?.split(",")[0]?.trim()
      || (req.socket.encrypted ? "https" : "http");
    const host = req.headers["x-forwarded-host"]?.split(",")[0]?.trim() || req.headers.host;
    if (!host || !isLoopbackHost(host.split(":")[0])) {
      const port = req.socket.localPort ?? 8787;
      return `http://127.0.0.1:${port}`;
    }
    return `${proto}://${host}`;
  }

  const secureCookies = () => Boolean(config.publicOrigin?.startsWith("https://"));

  function cookieHeader(token, maxAge) {
    const parts = [
      `${sessionCookieName(secureCookies())}=${encodeURIComponent(token)}`,
      "Path=/",
      "HttpOnly",
      "SameSite=Lax",
    ];
    if (secureCookies()) parts.push("Secure");
    parts.push(`Max-Age=${maxAge}`);
    return parts.join("; ");
  }

  function clearCookieHeader() {
    return cookieHeader("", 0);
  }

  function currentUser(req) {
    const cookie = readCookie(req, sessionCookieName(secureCookies()));
    return cookie ? store.sessionUser(cookie) : null;
  }

  /**
   * 「只有本机能访问」的部署：绑定在回环地址，且请求也来自回环。
   * 这种部署下初始化账号不需要额外凭证——远程攻击者根本到不了这个页面；
   * 一旦绑定到对外地址，初始化就必须用启动时打印的一次性链接。
   */
  function isLocalOnlyRequest(req) {
    const host = req.headers.host?.split(":")[0] ?? "";
    return config.bindIsLoopback && isLoopbackHost(host);
  }

  /** 浏览器可见的写操作要求同源，cookie 鉴权天然带 CSRF 风险。 */
  function sameOrigin(req) {
    const requestOrigin = req.headers.origin;
    if (!requestOrigin) return true;
    return requestOrigin === originOf(req);
  }

  function clientIp(req) {
    return (
      req.headers["x-forwarded-for"]?.split(",")[0]?.trim()
      || req.socket.remoteAddress
      || "unknown"
    );
  }

  function rateLimited(req, bucket) {
    const rule = RATE_LIMITS[bucket];
    if (!rule) return false;
    return !store.hitRateLimit(`${bucket}:${clientIp(req)}`, rule.limit, rule.window);
  }

  function findClient(clientId) {
    return clientId ? store.getClient(clientId) : null;
  }

  /**
   * 解析客户端。除了动态注册，还支持「客户端元数据文档」（CIMD）：
   * client_id 本身是一个 HTTPS 文档地址，服务端读取后即时登记。
   * 只有明确列在 THREADPOCKET_CIMD_HOSTS 里的主机才会被读取，避免被当作 SSRF 跳板。
   */
  async function resolveClient(clientId) {
    if (!clientId) return null;
    const existing = findClient(clientId);
    if (existing) return existing;
    let url;
    try {
      url = new URL(clientId);
    } catch {
      return null;
    }
    if (url.protocol !== "https:") return null;
    if (!config.cimdHosts.includes(url.hostname.toLowerCase())) return null;
    try {
      const response = await fetch(url, {
        redirect: "error",
        signal: AbortSignal.timeout(8000),
        headers: { accept: "application/json" },
      });
      if (!response.ok) return null;
      const raw = await response.text();
      if (raw.length > 64 * 1024) return null;
      const document = JSON.parse(raw);
      if (document.client_id !== clientId) return null;
      const redirectUris = Array.isArray(document.redirect_uris) ? document.redirect_uris.map(String) : [];
      if (redirectUris.length === 0 || redirectUris.some((uri) => !isAllowedRedirect(uri))) return null;
      const scopes = normalizeScopes(document.scope, MCP_DEFAULT_SCOPES).filter((scope) => ALL_SCOPES.includes(scope));
      const client = store.upsertClient({
        id: clientId,
        name: (document.client_name ?? url.hostname).toString().slice(0, 120),
        redirectUris,
        scopes: scopes.length > 0 ? scopes : MCP_DEFAULT_SCOPES,
        source: "cimd",
        metadataUrl: clientId,
      });
      logger.log?.(`[thread-pocket] 通过客户端元数据文档登记 ${client.name}`);
      return client;
    } catch (error) {
      logger.warn?.(`[thread-pocket] 读取客户端元数据失败：${error.message}`);
      return null;
    }
  }

  function matchRedirect(client, redirectUri) {
    return client.redirect_uris.some((registered) => sameRedirectUri(redirectUri, registered));
  }

  function allowedScopes(client) {
    return client.scopes.length > 0 ? client.scopes : MCP_DEFAULT_SCOPES;
  }

  /* ----------------------------- 元信息文档 ------------------------------ */

  function authorizationServerMetadata(req) {
    const origin = originOf(req);
    return {
      issuer: origin,
      authorization_endpoint: `${origin}/oauth/authorize`,
      token_endpoint: `${origin}/oauth/token`,
      registration_endpoint: `${origin}/oauth/register`,
      revocation_endpoint: `${origin}/oauth/revoke`,
      introspection_endpoint: `${origin}/oauth/introspect`,
      scopes_supported: ALL_SCOPES,
      response_types_supported: ["code"],
      response_modes_supported: ["query"],
      grant_types_supported: ["authorization_code", "refresh_token"],
      token_endpoint_auth_methods_supported: ["none"],
      revocation_endpoint_auth_methods_supported: ["none"],
      code_challenge_methods_supported: ["S256"],
      service_documentation: `${origin}/`,
      ui_locales_supported: ["zh-CN", "en"],
    };
  }

  function protectedResourceMetadata(req, resource) {
    const origin = originOf(req);
    const path = resource === "mcp" ? "/mcp" : "/api/v1";
    const scopes = resource === "mcp" ? ["mcp:tools", "offline_access"] : ["threads:read", "threads:write", "offline_access"];
    return {
      resource: `${origin}${path}`,
      authorization_servers: [origin],
      scopes_supported: scopes,
      bearer_methods_supported: ["header"],
      resource_name: resource === "mcp" ? "Thread Pocket MCP" : "Thread Pocket API",
      resource_documentation: `${origin}/`,
    };
  }

  /* --------------------------- 动态客户端注册 ---------------------------- */

  function registerClient(req, body) {
    if (rateLimited(req, "register")) {
      return oauthError(429, "temporarily_unavailable", "注册过于频繁，请稍后再试");
    }
    const redirectUris = Array.isArray(body.redirect_uris) ? body.redirect_uris.map(String) : [];
    if (redirectUris.length === 0) {
      return oauthError(400, "invalid_redirect_uri", "redirect_uris 不能为空");
    }
    if (redirectUris.length > 10) {
      return oauthError(400, "invalid_redirect_uri", "redirect_uris 最多 10 个");
    }
    const bad = redirectUris.find((uri) => !isAllowedRedirect(uri));
    if (bad) {
      return oauthError(400, "invalid_redirect_uri", `不允许的回调地址：${bad}`);
    }
    const authMethod = body.token_endpoint_auth_method ?? "none";
    if (authMethod !== "none") {
      return oauthError(
        400,
        "invalid_client_metadata",
        "本服务只支持公共客户端（token_endpoint_auth_method=none），请使用 PKCE",
      );
    }
    const scopes = normalizeScopes(body.scope, MCP_DEFAULT_SCOPES);
    const unknown = String(body.scope ?? "")
      .split(/[\s,]+/)
      .filter(Boolean)
      .filter((scope) => !ALL_SCOPES.includes(scope));
    if (unknown.length > 0) {
      return oauthError(400, "invalid_client_metadata", `不支持的 scope：${unknown.join(", ")}`);
    }
    const client = store.upsertClient({
      id: `oc_${randomId(12)}`,
      name: (body.client_name ?? "未命名客户端").toString().slice(0, 120),
      redirectUris,
      scopes: scopes.length > 0 ? scopes : MCP_DEFAULT_SCOPES,
      source: "dcr",
    });
    logger.log?.(`[thread-pocket] 注册 OAuth 客户端 ${client.name} (${client.id})`);
    return json(
      201,
      {
        client_id: client.id,
        client_name: client.name,
        redirect_uris: client.redirect_uris,
        grant_types: ["authorization_code", "refresh_token"],
        response_types: ["code"],
        token_endpoint_auth_method: "none",
        scope: client.scopes.join(" "),
        client_id_issued_at: Math.floor(Date.parse(client.created_at) / 1000),
      },
    );
  }

  /* ------------------------------- 授权端点 ------------------------------- */

  /** 校验授权请求；成功返回规范化对象，失败返回 { error, description }。 */
  function parseAuthorizationRequest(source, client, origin) {
    const redirectUri = source.redirect_uri;
    if (!redirectUri) return { error: "invalid_request", description: "缺少 redirect_uri", client };
    if (!matchRedirect(client, redirectUri)) {
      return { error: "invalid_request", description: "redirect_uri 与注册信息不匹配", client };
    }

    const responseType = source.response_type ?? "code";
    if (responseType !== "code") {
      return { error: "unsupported_response_type", description: "只支持 response_type=code", client, redirectUri };
    }

    const requested = normalizeScopes(source.scope, source.scope ? [] : allowedScopes(client));
    if (requested.length === 0) {
      return { error: "invalid_scope", description: "没有可用的 scope", client, redirectUri };
    }
    const overreach = requested.filter((scope) => !allowedScopes(client).includes(scope));
    if (overreach.length > 0) {
      return {
        error: "invalid_scope",
        description: `客户端未注册的 scope：${overreach.join(", ")}`,
        client,
        redirectUri,
      };
    }

    const codeChallenge = source.code_challenge;
    const method = source.code_challenge_method ?? "S256";
    if (!codeChallenge) {
      return { error: "invalid_request", description: "缺少 code_challenge（必须使用 PKCE）", client, redirectUri };
    }
    if (method !== "S256") {
      return { error: "invalid_request", description: "只支持 code_challenge_method=S256", client, redirectUri };
    }
    if (typeof codeChallenge !== "string" || !/^[A-Za-z0-9\-._~]{43,128}$/.test(codeChallenge)) {
      return { error: "invalid_request", description: "code_challenge 格式不合法", client, redirectUri };
    }

    const resource = source.resource ? String(source.resource) : null;
    if (resource) {
      let parsedResource;
      try {
        parsedResource = new URL(resource);
      } catch {
        return { error: "invalid_target", description: "resource 不是合法 URL", client, redirectUri };
      }
      const known = [`${origin}/mcp`, `${origin}/api/v1`, `${origin}/`];
      if (!known.includes(resource) && parsedResource.origin !== origin) {
        return { error: "invalid_target", description: "resource 不属于本服务", client, redirectUri };
      }
    }

    return {
      client,
      clientId: client.id,
      redirectUri,
      scopes: requested,
      state: source.state ? String(source.state) : null,
      codeChallenge,
      codeChallengeMethod: method,
      resource,
    };
  }

  function redirectWithError(redirectUri, error, description, state) {
    const url = new URL(redirectUri);
    url.searchParams.set("error", error);
    if (description) url.searchParams.set("error_description", description);
    if (state) url.searchParams.set("state", state);
    return redirect(url.toString());
  }

  async function authorizeGet(req, query) {
    const client = await resolveClient(query.client_id ? String(query.client_id) : null);
    if (!client) {
      return html(
        400,
        messagePage({
          title: "未知的客户端",
          message: query.client_id
            ? `无法识别 client_id：${query.client_id}。请确认该客户端已完成注册。`
            : "授权请求缺少 client_id。",
          tone: "error",
        }),
      );
    }
    const parsed = parseAuthorizationRequest(query, client, originOf(req));
    if (parsed.error) {
      if (parsed.redirectUri && parsed.client) {
        return redirectWithError(parsed.redirectUri, parsed.error, parsed.description, query.state);
      }
      return html(400, messagePage({ title: "授权请求无效", message: parsed.description, tone: "error" }));
    }

    const user = currentUser(req);
    if (!user) {
      const next = `${req.url ?? "/oauth/authorize"}`;
      return redirect(`/auth/login?next=${encodeURIComponent(next)}`);
    }

    const consent = store.consentFor(parsed.clientId, user.id);
    const covered = consent && parsed.scopes.every((scope) => consent.scopes.includes(scope));
    if (covered) {
      store.recordConsent(parsed.clientId, user.id, Array.from(new Set([...consent.scopes, ...parsed.scopes])));
      store.touchClient(parsed.clientId);
      return issueCodeRedirect(parsed, user);
    }

    return html(
      200,
      consentPage({
        request: parsed,
        clientName: parsed.client.name,
        clientId: parsed.clientId,
      }),
    );
  }

  function issueCodeRedirect(parsed, user) {
    const code = store.createCode({
      clientId: parsed.clientId,
      userId: user.id,
      redirectUri: parsed.redirectUri,
      scopes: parsed.scopes,
      codeChallenge: parsed.codeChallenge,
      method: parsed.codeChallengeMethod,
      resource: parsed.resource,
    });
    const url = new URL(parsed.redirectUri);
    url.searchParams.set("code", code);
    if (parsed.state) url.searchParams.set("state", parsed.state);
    return redirect(url.toString());
  }

  async function authorizePost(req, form) {
    if (!sameOrigin(req)) {
      return html(403, messagePage({ title: "请求被拒绝", message: "跨站提交不被允许。", tone: "error" }));
    }
    const user = currentUser(req);
    if (!user) {
      return redirect(`/auth/login?next=${encodeURIComponent("/oauth/authorize")}`);
    }
    const client = await resolveClient(form.client_id ? String(form.client_id) : null);
    if (!client) {
      return html(400, messagePage({ title: "未知的客户端", message: "无法识别该客户端。", tone: "error" }));
    }
    const parsed = parseAuthorizationRequest(form, client, originOf(req));
    if (parsed.error) {
      if (parsed.redirectUri && parsed.client) {
        return redirectWithError(parsed.redirectUri, parsed.error, parsed.description, form.state);
      }
      return html(400, messagePage({ title: "授权请求无效", message: parsed.description, tone: "error" }));
    }
    if (form.decision !== "allow") {
      return redirectWithError(parsed.redirectUri, "access_denied", "用户拒绝了授权", parsed.state);
    }
    const existing = store.consentFor(parsed.clientId, user.id);
    store.recordConsent(
      parsed.clientId,
      user.id,
      Array.from(new Set([...(existing?.scopes ?? []), ...parsed.scopes])),
    );
    store.touchClient(parsed.clientId);
    return issueCodeRedirect(parsed, user);
  }

  /* -------------------------------- 令牌端点 -------------------------------- */

  function tokenResponse({ clientId, userId, scopes, familyId = null, previousRefresh = null }) {
    const access = store.issueTokens({ clientId, userId, scopes, familyId, kind: "access" });
    const body = {
      access_token: access.token,
      token_type: "Bearer",
      expires_in: access.expires_in,
      scope: scopes.join(" "),
    };
    if (scopes.includes("offline_access")) {
      const refresh = store.issueTokens({
        clientId,
        userId,
        scopes,
        familyId: access.family,
        kind: "refresh",
      });
      body.refresh_token = refresh.token;
      body.refresh_token_expires_in = refresh.expires_in;
      if (previousRefresh) store.markReplaced(previousRefresh, refresh.token);
    }
    return body;
  }

  function token(req, body) {
    if (rateLimited(req, "token")) {
      return oauthError(429, "temporarily_unavailable", "请求过于频繁");
    }
    const grantType = body.grant_type;
    const clientId = body.client_id;

    if (grantType === "authorization_code") {
      const record = body.code ? store.consumeCode(String(body.code)) : null;
      if (!record || record.expired || record.reused) {
        return oauthError(400, "invalid_grant", record?.reused ? "授权码已被使用" : "授权码无效或已过期");
      }
      if (clientId && record.client_id !== clientId) {
        return oauthError(400, "invalid_grant", "授权码与客户端不匹配");
      }
      if (body.redirect_uri && !sameRedirectUri(String(body.redirect_uri), record.redirect_uri)) {
        return oauthError(400, "invalid_grant", "redirect_uri 与授权请求不一致");
      }
      if (!verifyPkce(String(body.code_verifier ?? ""), record.code_challenge, record.code_challenge_method)) {
        return oauthError(400, "invalid_grant", "code_verifier 校验失败");
      }
      store.touchClient(record.client_id);
      return json(200, tokenResponse({
        clientId: record.client_id,
        userId: record.user_id,
        scopes: record.scopes,
      }));
    }

    if (grantType === "refresh_token") {
      const raw = body.refresh_token ? String(body.refresh_token) : "";
      const record = raw ? store.findToken(raw) : null;
      if (!record || record.kind !== "refresh") {
        return oauthError(400, "invalid_grant", "refresh_token 无效");
      }
      if (!record.active) {
        // 已撤销或已过期的刷新令牌被再次使用：整个令牌族作废，防止令牌被重放。
        store.revokeFamily(record.family_id);
        return oauthError(400, "invalid_grant", "refresh_token 已失效，请重新授权");
      }
      if (clientId && record.client_id !== clientId) {
        return oauthError(400, "invalid_grant", "refresh_token 与客户端不匹配");
      }
      const user = store.getUser(record.user_id);
      if (!user) return oauthError(400, "invalid_grant", "账号不存在");
      store.revokeToken(raw);
      store.touchClient(record.client_id);
      return json(200, tokenResponse({
        clientId: record.client_id,
        userId: record.user_id,
        scopes: record.scopes,
        familyId: record.family_id,
        previousRefresh: raw,
      }));
    }

    return oauthError(400, "unsupported_grant_type", `不支持的 grant_type：${grantType ?? "（缺失）"}`);
  }

  /* ---------------------------- 登录 / 初始化页面 --------------------------- */

  function setupGet(req, query) {
    if (store.initialized()) {
      return html(
        409,
        messagePage({
          title: "已经初始化",
          message: "这个部署已经存在账号，请直接登录。",
          actions: `<a class="foot" href="/auth/login">去登录</a>`,
        }),
      );
    }
    const embedded = isLocalOnlyRequest(req);
    // 链接里的凭证通常在 # 之后，服务端读不到；这里只负责把页面渲染出来，
    // 真正的校验在 POST。允许无凭证渲染是安全的：页面本身不含任何数据，
    // 提交仍需正确的一次性凭证，且 setup 端点有按 IP 的限流。
    const token = String(query.token ?? "");
    return html(200, setupPage({ token, embedded }));
  }

  function setupPost(req, body) {
    if (rateLimited(req, "setup")) {
      return html(429, messagePage({ title: "过于频繁", message: "请稍后再试。", tone: "error" }));
    }
    if (!sameOrigin(req)) {
      return html(403, messagePage({ title: "请求被拒绝", message: "跨站提交不被允许。", tone: "error" }));
    }
    if (store.initialized()) {
      return html(409, messagePage({ title: "已经初始化", message: "请直接登录。", tone: "error" }));
    }
    const embedded = isLocalOnlyRequest(req);
    if (!embedded && !store.verifySetupToken(String(body.token ?? ""))) {
      return html(
        403,
        messagePage({
          title: "凭证无效或缺失",
          message:
            "初始化需要启动时打印的一次性链接（凭证在链接的 # 之后，请完整复制）。也可在服务器上运行 npm run setup:link 重新获取。",
          tone: "error",
        }),
      );
    }
    const email = String(body.email ?? "").trim();
    const password = String(body.password ?? "");
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
      return html(400, setupPage({ token: body.token, embedded, error: "邮箱格式不正确" }));
    }
    if (password.length < PASSWORD_MIN_LENGTH) {
      return html(400, setupPage({ token: body.token, embedded, error: `密码至少 ${PASSWORD_MIN_LENGTH} 位` }));
    }
    const user = store.createUser({ email, password });
    store.clearSetupToken();
    const session = store.createSession(user.id, req.headers["user-agent"]);
    logger.log?.(`[thread-pocket] 已创建账号 ${user.email}`);
    return redirect("/auth/connections", { "set-cookie": cookieHeader(session.token, session.expires_in) });
  }

  function loginGet(req, query) {
    if (!store.initialized()) {
      return redirect("/auth/setup");
    }
    const next = typeof query.next === "string" && query.next.startsWith("/") ? query.next : "/";
    return html(200, loginPage({ next }));
  }

  function loginPost(req, body) {
    if (rateLimited(req, "login")) {
      return html(429, loginPage({ next: String(body.next ?? "/"), error: "尝试过于频繁，请稍后再试" }));
    }
    if (!sameOrigin(req)) {
      return html(403, messagePage({ title: "请求被拒绝", message: "跨站提交不被允许。", tone: "error" }));
    }
    const user = store.authenticate(body.email, body.password);
    const next = typeof body.next === "string" && body.next.startsWith("/") ? body.next : "/";
    if (!user) {
      logger.warn?.(`[thread-pocket] 登录失败：${String(body.email ?? "").slice(0, 120)}`);
      return html(401, loginPage({ next, error: "邮箱或密码不正确" }));
    }
    const session = store.createSession(user.id, req.headers["user-agent"]);
    return redirect(next, { "set-cookie": cookieHeader(session.token, session.expires_in) });
  }

  function logoutPost(req) {
    const cookie = readCookie(req, sessionCookieName(secureCookies()));
    if (cookie) store.deleteSession(cookie);
    return redirect("/", { "set-cookie": clearCookieHeader() });
  }

  function connectionsGet(req) {
    const user = currentUser(req);
    if (!user) return redirect("/auth/login?next=%2Fauth%2Fconnections");
    return html(
      200,
      connectionsPage({ user, consents: store.listConsents(user.id), clients: store.listClients() }),
    );
  }

  function connectionsPost(req, body) {
    if (!sameOrigin(req)) {
      return html(403, messagePage({ title: "请求被拒绝", message: "跨站提交不被允许。", tone: "error" }));
    }
    const user = currentUser(req);
    if (!user) return redirect("/auth/login?next=%2Fauth%2Fconnections");
    const clientId = String(body.client_id ?? "");
    if (clientId) {
      store.revokeClientForUser(clientId, user.id);
      logger.log?.(`[thread-pocket] 撤销了客户端 ${clientId} 的访问`);
    }
    return redirect("/auth/connections");
  }

  /* --------------------------------- 分发 ---------------------------------- */

  const routes = [
    ["GET", "/.well-known/oauth-authorization-server", (ctx) => json(200, authorizationServerMetadata(ctx.req))],
    ["GET", "/.well-known/oauth-protected-resource", (ctx) => json(200, protectedResourceMetadata(ctx.req, "api"))],
    ["GET", "/.well-known/oauth-protected-resource/api", (ctx) => json(200, protectedResourceMetadata(ctx.req, "api"))],
    ["GET", "/.well-known/oauth-protected-resource/mcp", (ctx) => json(200, protectedResourceMetadata(ctx.req, "mcp"))],
    ["GET", "/.well-known/mcp", (ctx) => json(200, protectedResourceMetadata(ctx.req, "mcp"))],
    ["POST", "/oauth/register", (ctx) => registerClient(ctx.req, ctx.body)],
    ["GET", "/oauth/authorize", (ctx) => authorizeGet(ctx.req, ctx.query)],
    ["POST", "/oauth/authorize", (ctx) => authorizePost(ctx.req, ctx.body)],
    ["POST", "/oauth/token", (ctx) => token(ctx.req, ctx.body)],
    ["POST", "/oauth/revoke", (ctx) => {
      const value = String(ctx.body.token ?? "");
      if (value) store.revokeToken(value);
      return json(200, { ok: true });
    }],
    ["POST", "/oauth/introspect", (ctx) => {
      const allowed =
        config.staticKey
          ? bearerToken(ctx.req) && bearerToken(ctx.req) === config.staticKey
          : isLoopbackHost(String(ctx.req.socket.remoteAddress ?? "").replace(/^::ffff:/, ""));
      if (!allowed) return oauthError(401, "invalid_client", "introspect 仅限本机或静态密钥");
      const value = String(ctx.body.token ?? "");
      const record = value ? store.findToken(value) : null;
      if (!record?.active) return json(200, { active: false });
      return json(200, {
        active: true,
        scope: record.scopes.join(" "),
        client_id: record.client_id,
        sub: record.user_id,
        token_type: "Bearer",
        exp: Math.floor(Date.parse(record.expires_at) / 1000),
        iat: Math.floor(Date.parse(record.created_at) / 1000),
      });
    }],
    ["GET", "/auth/setup", (ctx) => setupGet(ctx.req, ctx.query)],
    ["POST", "/auth/setup", (ctx) => setupPost(ctx.req, ctx.body)],
    ["GET", "/auth/login", (ctx) => loginGet(ctx.req, ctx.query)],
    ["POST", "/auth/login", (ctx) => loginPost(ctx.req, ctx.body)],
    ["POST", "/auth/logout", (ctx) => logoutPost(ctx.req)],
    ["GET", "/auth/connections", (ctx) => connectionsGet(ctx.req)],
    ["POST", "/auth/connections", (ctx) => connectionsPost(ctx.req, ctx.body)],
    ["GET", "/auth/whoami", (ctx) => {
      const user = currentUser(ctx.req);
      if (!user) return json(401, { authenticated: false });
      return json(200, { authenticated: true, email: user.email, name: user.name, scopes: ALL_SCOPES });
    }],
  ];

  const table = new Map(routes.map(([method, path, handler]) => [`${method} ${path}`, handler]));

  return {
    routes: table,
    handles(method, pathname) {
      return table.has(`${method} ${pathname}`);
    },
    handle(method, pathname, ctx) {
      const handler = table.get(`${method} ${pathname}`);
      if (!handler) return null;
      return handler(ctx);
    },
    originOf,
    currentUser,
    authorizationServerMetadata,
    protectedResourceMetadata,
    appDefaultScopes: APP_DEFAULT_SCOPES,
    mcpDefaultScopes: MCP_DEFAULT_SCOPES,
    scopeDefinitions: SCOPE_DEFINITIONS,
    accessTokenTtl: ACCESS_TOKEN_TTL_SECONDS,
  };
}

export { escapeHtml };
