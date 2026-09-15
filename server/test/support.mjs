import { createServer } from "../src/server.js";

const quietLogger = { log() {}, warn() {}, error() {} };

/** 起一个测试服务；env 用来模拟不同的部署形态。 */
export async function startServer({ env = {}, dbFile = ":memory:", apiKey = null } = {}) {
  const app = createServer({ dbFile, apiKey, env: { ...env }, logger: quietLogger });
  await new Promise((resolve) => app.server.listen(0, "127.0.0.1", resolve));
  const port = app.server.address().port;
  const base = `http://127.0.0.1:${port}`;

  async function request(path, { method = "GET", body, token, headers = {}, form = false, cookie } = {}) {
    const init = { method, headers: { ...headers }, redirect: "manual" };
    if (body !== undefined) {
      if (form) {
        init.headers["content-type"] = "application/x-www-form-urlencoded";
        init.body = new URLSearchParams(body).toString();
      } else {
        init.headers["content-type"] = "application/json";
        init.body = JSON.stringify(body);
      }
    }
    if (token) init.headers.authorization = `Bearer ${token}`;
    if (cookie) init.headers.cookie = cookie;
    const response = await fetch(`${base}${path}`, init);
    const text = await response.text();
    let json = null;
    try {
      json = text ? JSON.parse(text) : null;
    } catch {
      json = null;
    }
    return { status: response.status, headers: response.headers, text, json };
  }

  const origin = env.THREADPOCKET_PUBLIC_URL ?? base;
  return { app, base, origin, request, port, close: () => app.close() };
}

export async function bootstrapOwner(ctx, { email = "owner@example.com", password = "correct-horse-battery" } = {}) {
  const token = ctx.app.setupToken;
  const created = await ctx.request("/auth/setup", {
    method: "POST",
    form: true,
    body: { email, password, token: token ?? "" },
  });
  const cookie = created.headers.getSetCookie?.()[0] ?? created.headers.get("set-cookie") ?? "";
  return { email, password, cookie: cookie.split(";")[0], status: created.status, location: created.headers.get("location") };
}

export async function login(ctx, { email = "owner@example.com", password = "correct-horse-battery" } = {}) {
  const response = await ctx.request("/auth/login", { method: "POST", form: true, body: { email, password } });
  const cookie = response.headers.getSetCookie?.()[0] ?? response.headers.get("set-cookie") ?? "";
  return { status: response.status, cookie: cookie.split(";")[0], location: response.headers.get("location") };
}

/** 走一遍动态注册 + PKCE 授权，拿到 access/refresh token。 */
export async function authorizeClient(ctx, {
  cookie,
  redirectUri = "http://127.0.0.1:53682/callback",
  scope = "mcp:tools offline_access",
  clientName = "测试客户端",
  register = true,
  clientId = null,
  autoConsent = true,
  verifier = null,
  challenge = null,
  codeChallengeMethod = "S256",
} = {}) {
  let id = clientId;
  if (register) {
    const registration = await ctx.request("/oauth/register", {
      method: "POST",
      body: { client_name: clientName, redirect_uris: [redirectUri], scope, token_endpoint_auth_method: "none" },
    });
    if (registration.status !== 201) {
      throw new Error(`注册客户端失败：${registration.status} ${registration.text}`);
    }
    id = registration.json.client_id;
  }

  const pkce = verifier
    ? { verifier, challenge }
    : await (async () => {
        const { createPkcePair } = await import("../src/auth/crypto.js");
        return createPkcePair();
      })();

  const params = new URLSearchParams({
    response_type: "code",
    client_id: id,
    redirect_uri: redirectUri,
    scope,
    state: "state-123",
    code_challenge: pkce.challenge,
    code_challenge_method: codeChallengeMethod,
  });

  const authorize = await ctx.request(`/oauth/authorize?${params.toString()}`, { cookie });
  if (authorize.status === 302) {
    const location = new URL(authorize.headers.get("location"), ctx.base);
    return {
      clientId: id,
      verifier: pkce.verifier,
      code: location.searchParams.get("code"),
      state: location.searchParams.get("state"),
      redirect: authorize.headers.get("location"),
      consent: false,
    };
  }

  if (!autoConsent) {
    return { clientId: id, verifier: pkce.verifier, consentPage: authorize.text, status: authorize.status };
  }
  if (authorize.status !== 200 || !authorize.text.includes("允许访问")) {
    throw new Error(`授权页面异常：${authorize.status} ${authorize.text.slice(0, 200)}`);
  }

  const decision = await ctx.request("/oauth/authorize", {
    method: "POST",
    form: true,
    cookie,
    headers: { origin: ctx.origin ?? ctx.base },
    body: {
      decision: "allow",
      client_id: id,
      redirect_uri: redirectUri,
      scope,
      state: "state-123",
      code_challenge: pkce.challenge,
      code_challenge_method: "S256",
    },
  });
  if (decision.status !== 302) {
    throw new Error(`授权确认失败：${decision.status} ${decision.text.slice(0, 200)}`);
  }
  const location = new URL(decision.headers.get("location"), ctx.base);
  return {
    clientId: id,
    verifier: pkce.verifier,
    code: location.searchParams.get("code"),
    state: location.searchParams.get("state"),
    redirect: decision.headers.get("location"),
    consent: true,
  };
}

export async function exchangeCode(ctx, { clientId, code, verifier, redirectUri = "http://127.0.0.1:53682/callback" }) {
  return ctx.request("/oauth/token", {
    method: "POST",
    form: true,
    body: { grant_type: "authorization_code", client_id: clientId, code, code_verifier: verifier, redirect_uri: redirectUri },
  });
}

export async function mcpCall(ctx, { token, method, params, id = 1 }) {
  return ctx.request("/mcp", {
    method: "POST",
    token,
    headers: { accept: "application/json, text/event-stream" },
    body: { jsonrpc: "2.0", id, method, params },
  });
}
