import { randomToken } from "./crypto.js";

export const SCOPE_DEFINITIONS = {
  "threads:read": "读取 Domain、Thread、事项、笔记与日志",
  "threads:write": "新增与修改 Thread、事项、笔记与日志",
  "mcp:tools": "通过 MCP 工具读写 Thread Pocket",
  offline_access: "在访问令牌过期后继续获取新令牌",
};

export const ALL_SCOPES = Object.keys(SCOPE_DEFINITIONS);

/** Agent / MCP 客户端的默认授权范围。 */
export const MCP_DEFAULT_SCOPES = ["mcp:tools", "offline_access"];

/** 桌面端与 Web 控制台的默认授权范围。 */
export const APP_DEFAULT_SCOPES = ["threads:read", "threads:write", "offline_access"];

export const ACCESS_TOKEN_TTL_SECONDS = 60 * 60;
export const REFRESH_TOKEN_TTL_SECONDS = 60 * 60 * 24 * 30;
export const AUTHORIZATION_CODE_TTL_SECONDS = 120;
export const SESSION_TTL_SECONDS = 60 * 60 * 24 * 14;

const LOOPBACK_HOSTS = new Set(["127.0.0.1", "::1", "localhost", "[::1]"]);

export function isLoopbackHost(host) {
  return LOOPBACK_HOSTS.has(String(host).toLowerCase());
}

export function isLoopbackAddress(address) {
  if (!address) return false;
  const value = String(address).replace(/^::ffff:/, "");
  return value === "::1" || value.startsWith("127.") || value === "localhost";
}

function truthy(value) {
  return value === "1" || value === "true" || value === "yes";
}

/**
 * 鉴权配置。默认「本机开放、对外必须鉴权」：
 * - 只在配置了静态密钥或已存在账号时才要求鉴权；
 * - 绑定在非回环地址且没有任何鉴权手段时，直接拒绝启动，避免把个人数据裸奔到公网。
 */
export function loadAuthConfig(env = process.env) {
  const bindHost = env.HOST ?? env.THREADPOCKET_HOST ?? "127.0.0.1";
  const publicUrlRaw = (env.THREADPOCKET_PUBLIC_URL ?? "").trim();
  let publicOrigin = null;
  if (publicUrlRaw) {
    let parsed;
    try {
      parsed = new URL(publicUrlRaw);
    } catch {
      throw new Error(`THREADPOCKET_PUBLIC_URL 不是合法 URL：${publicUrlRaw}`);
    }
    if (parsed.search || parsed.hash || parsed.username || parsed.password || (parsed.pathname !== "/" && parsed.pathname !== "")) {
      throw new Error("THREADPOCKET_PUBLIC_URL 只能是 origin，例如 https://pocket.example.com");
    }
    if (parsed.protocol !== "https:" && !(parsed.protocol === "http:" && isLoopbackHost(parsed.hostname))) {
      throw new Error("对外暴露时必须使用 HTTPS（本地开发可用 http://127.0.0.1:8787）");
    }
    publicOrigin = parsed.origin;
  }

  const bindIsLoopback = isLoopbackHost(bindHost);
  /**
   * 本机免登录默认关闭：只要配置了账号或静态密钥，本机请求同样要凭证。
   * 否则「撤销访问 / 令牌过期」在本机不会生效，容易造成错觉。
   * 想要纯本机开发省掉登录，可显式设置 THREADPOCKET_TRUST_LOOPBACK=1。
   */
  const trustLoopback = truthy(env.THREADPOCKET_TRUST_LOOPBACK);
  const allowInsecure = truthy(env.THREADPOCKET_ALLOW_INSECURE);
  const staticKey = (env.THREADPOCKET_API_KEY ?? "").trim() || null;

  // 客户端元数据文档（CIMD）：默认只信任明确列出的主机，避免服务端被当成 SSRF 跳板。
  const cimdHosts = (env.THREADPOCKET_CIMD_HOSTS ?? "chatgpt.com,claude.ai,claude.com")
    .split(",")
    .map((item) => item.trim().toLowerCase())
    .filter(Boolean);

  return {
    bindHost,
    bindIsLoopback,
    publicOrigin,
    trustLoopback,
    allowInsecure,
    staticKey,
    cimdHosts,
    setupToken: (env.THREADPOCKET_SETUP_TOKEN ?? "").trim() || null,
    logRequests: truthy(env.THREADPOCKET_LOG_REQUESTS),
  };
}

export function newSetupToken() {
  return randomToken("tp_setup");
}

/** 授权码/令牌的 scope 归一化：去重、保持顺序、校验合法性。 */
export function normalizeScopes(input, fallback = []) {
  const raw = Array.isArray(input)
    ? input
    : String(input ?? "")
        .split(/[\s,]+/)
        .filter(Boolean);
  const list = raw.length > 0 ? raw : fallback;
  const seen = new Set();
  const result = [];
  for (const scope of list) {
    const value = String(scope).trim();
    if (!value || seen.has(value)) continue;
    if (!ALL_SCOPES.includes(value)) continue;
    seen.add(value);
    result.push(value);
  }
  return result;
}
