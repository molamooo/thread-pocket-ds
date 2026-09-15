import { ALL_SCOPES, isLoopbackAddress, isLoopbackHost } from "./config.js";
import { safeEqual } from "./crypto.js";

/** 每类资源的默认所需 scope；写操作需要额外权限。 */
export const RESOURCE_RULES = {
  mcp: { read: ["mcp:tools"], write: ["mcp:tools"] },
  api: { read: ["threads:read"], write: ["threads:write"] },
  web: { read: [], write: [] },
};

export function sessionCookieName(secure) {
  return secure ? "__Host-tp_session" : "tp_session";
}

export function readCookie(req, name) {
  const header = req.headers.cookie;
  if (typeof header !== "string" || !header) return null;
  for (const part of header.split(";")) {
    const index = part.indexOf("=");
    if (index === -1) continue;
    if (part.slice(0, index).trim() === name) {
      return decodeURIComponent(part.slice(index + 1).trim());
    }
  }
  return null;
}

export function bearerToken(req) {
  const header = req.headers.authorization;
  if (typeof header === "string" && header.toLowerCase().startsWith("bearer ")) {
    return header.slice(7).trim() || null;
  }
  const apiKey = req.headers["x-api-key"];
  if (typeof apiKey === "string" && apiKey.trim()) return apiKey.trim();
  return null;
}

function originOf(req, fallback) {
  const proto = req.headers["x-forwarded-proto"]?.split(",")[0]?.trim()
    || (req.socket.encrypted ? "https" : "http");
  const host = req.headers["x-forwarded-host"]?.split(",")[0]?.trim() || req.headers.host;
  if (!host) return fallback;
  return `${proto}://${host}`;
}

/**
 * 鉴权判定。核心规则：
 * - 没有配置任何鉴权手段（无静态密钥、无账号）时保持开放，方便本机起步；
 * - 一旦有账号或静态密钥，除「明确信任的本机请求」外都必须带凭证；
 * - 对外暴露（配置了公网 origin）时，本机豁免一律关闭。
 */
export function createAuthorizer({ store, config }) {
  const publicHost = config.publicOrigin ? new URL(config.publicOrigin).hostname : null;
  const trustLoopback = publicHost && !isLoopbackHost(publicHost) ? false : config.trustLoopback;
  /**
   * 「对外暴露」的部署形态：即使还没有账号，也绝不能是开放的。
   * 否则第一个访问者就能读写整个工作区。
   */
  const exposed = Boolean(publicHost && !isLoopbackHost(publicHost)) || !config.bindIsLoopback;

  function configured() {
    return exposed || Boolean(config.staticKey) || store.initialized();
  }

  function baseOrigin(req) {
    return config.publicOrigin ?? originOf(req, `http://127.0.0.1:${req.socket.localPort ?? 8787}`);
  }

  /** 401 挑战：MCP 客户端据此发现授权服务器（RFC 9728 + MCP 授权规范）。 */
  function challenge(req, resource, scope) {
    const origin = baseOrigin(req);
    const metadataUrl = resource === "mcp"
      ? `${origin}/.well-known/oauth-protected-resource/mcp`
      : `${origin}/.well-known/oauth-protected-resource/api`;
    const parts = [`Bearer realm="thread-pocket"`, `resource_metadata="${metadataUrl}"`];
    if (scope) parts.push(`scope="${scope}"`);
    return parts.join(", ");
  }

  function resourceFor(pathname) {
    if (pathname === "/mcp" || pathname.startsWith("/mcp/")) return "mcp";
    if (pathname.startsWith("/api/")) return "api";
    return null;
  }

  function requiredScopes(pathname, method) {
    const resource = resourceFor(pathname) ?? "web";
    const rule = RESOURCE_RULES[resource];
    const isWrite = !["GET", "HEAD", "OPTIONS"].includes(method);
    return isWrite ? rule.write : rule.read;
  }

  /** 返回 principal 或抛出 401 所需的挑战信息。 */
  function resolve(req, { pathname, method }) {
    const required = requiredScopes(pathname, method);

    if (!configured()) {
      return { kind: "open", scopes: ALL_SCOPES, userId: null, clientId: null, required, origin: baseOrigin(req) };
    }

    // 优先处理显式凭证：出示了无效令牌就应当被拒绝，
    // 而不是回落到「本机免登录」，否则撤销访问后旧令牌在本机仍然有效。
    const token = bearerToken(req);
    if (token) {
      if (config.staticKey && safeEqual(token, config.staticKey)) {
        return { kind: "static", scopes: ALL_SCOPES, userId: null, clientId: null, required, origin: baseOrigin(req) };
      }
      const record = store.findToken(token);
      if (record?.active && record.kind === "access") {
        return {
          kind: "token",
          scopes: record.scopes,
          userId: record.user_id,
          clientId: record.client_id,
          required,
          origin: baseOrigin(req),
        };
      }
      return {
        kind: "invalid",
        reason: record ? "令牌已过期或已撤销" : "令牌无法识别",
        scopes: [],
        userId: null,
        clientId: null,
        required,
        origin: baseOrigin(req),
      };
    }

    // 浏览器会话：只允许同源使用，避免被跨站请求借用
    const cookie = readCookie(req, sessionCookieName(Boolean(config.publicOrigin) && config.publicOrigin.startsWith("https")));
    if (cookie) {
      const requestOrigin = req.headers.origin;
      const sameOrigin = !requestOrigin || requestOrigin === baseOrigin(req);
      if (sameOrigin) {
        const user = store.sessionUser(cookie);
        if (user) {
          return {
            kind: "session",
            scopes: ALL_SCOPES,
            userId: user.id,
            clientId: null,
            required,
            origin: baseOrigin(req),
          };
        }
      }
      return {
        kind: "invalid",
        reason: "登录状态已失效",
        scopes: [],
        userId: null,
        clientId: null,
        required,
        origin: baseOrigin(req),
      };
    }

    // 没有任何凭证，且允许信任本机时，才走免登录通道。
    if (trustLoopback && isLoopbackAddress(req.socket.remoteAddress)) {
      return { kind: "local", scopes: ALL_SCOPES, userId: null, clientId: null, required, origin: baseOrigin(req) };
    }

    return { kind: "anonymous", scopes: [], userId: null, clientId: null, required, origin: baseOrigin(req) };
  }

  function challengeValue(principal, scope) {
    if (principal.kind === "invalid") {
      // HTTP 头只能是 ASCII：这里用固定英文描述，中文原因放在响应体里
      return `Bearer realm="thread-pocket", error="invalid_token", error_description="token expired, revoked or unknown"`;
    }
    return null;
  }

  function missingScopes(principal) {
    if (principal.kind === "anonymous") return principal.required;
    return principal.required.filter((scope) => !principal.scopes.includes(scope));
  }

  return { resolve, missingScopes, challenge, challengeValue, configured, trustLoopback, baseOrigin, resourceFor };
}
