import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createApi } from "./api.js";
import { loadAuthConfig } from "./auth/config.js";
import { createAuthorizer } from "./auth/guard.js";
import { createAuthRoutes } from "./auth/routes.js";
import { createAuthStore } from "./auth/store.js";
import { openDatabase } from "./db.js";
import { applyCors, readAnyBody, readJsonBody, readRawBody, sendJson, sendText } from "./http.js";
import { createThreadPocketMcp } from "./mcp/index.js";
import { createRepository } from "./repo.js";
import { HttpError } from "./util.js";
import { createViews } from "./views.js";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC_DIR = path.resolve(HERE, "..", "public");

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".ico": "image/x-icon",
};

export function createServer({
  dbFile = ":memory:",
  apiKey = null,
  env = process.env,
  logger = console,
  version = "0.1.0",
} = {}) {
  const db = openDatabase(dbFile);
  const repo = createRepository(db);
  const views = createViews(repo);
  let mutationCount = 0;
  const router = createApi({ repo, views, onMutate: () => { mutationCount += 1; } });

  const config = loadAuthConfig(apiKey ? { ...env, THREADPOCKET_API_KEY: apiKey } : env);
  const authStore = createAuthStore(db, config);
  const authRoutes = createAuthRoutes({ store: authStore, config, repo, logger });
  const authorizer = createAuthorizer({ store: authStore, config });
  const mcp = createThreadPocketMcp({ repo, views, version, logger });
  const setupToken = authStore.ensureSetupToken();
  const sweepTimer = setInterval(() => authStore.sweep(), 10 * 60 * 1000);
  sweepTimer.unref?.();

  function serveStatic(res, pathname) {
    const relative = pathname === "/" || pathname === "" ? "index.html" : pathname.replace(/^\/+/, "");
    const target = path.resolve(PUBLIC_DIR, relative);
    if (!target.startsWith(PUBLIC_DIR)) {
      sendText(res, 403, "forbidden");
      return;
    }
    if (!fs.existsSync(target) || !fs.statSync(target).isFile()) {
      sendText(res, 404, "not found");
      return;
    }
    const body = fs.readFileSync(target);
    res.writeHead(200, {
      "content-type": MIME[path.extname(target)] ?? "application/octet-stream",
      "content-length": body.length,
    });
    res.end(body);
  }

  async function handler(req, res) {
    applyCors(res);
    const url = new URL(req.url ?? "/", `http://${req.headers.host ?? "localhost"}`);
    const pathname = url.pathname;

    if (req.method === "OPTIONS") {
      res.writeHead(204);
      res.end();
      return;
    }

    try {
      /* --------------------------- OAuth / 登录页面 --------------------------- */
      if (authRoutes.handles(req.method, pathname)) {
        const body = ["POST", "PUT", "PATCH"].includes(req.method) ? await readAnyBody(req) : {};
        const result = await authRoutes.handle(req.method, pathname, {
          req,
          url,
          query: Object.fromEntries(url.searchParams.entries()),
          body,
          repo,
          views,
          store: authStore,
        });
        sendResult(res, result);
        return;
      }

      /* --------------------------------- MCP --------------------------------- */
      if (pathname === "/mcp" || pathname === "/mcp/") {
        await handleMcp(req, res);
        return;
      }

      const isApi = pathname.startsWith("/api/") || pathname === "/health";
      if (!isApi) {
        serveStatic(res, pathname);
        return;
      }

      if (pathname !== "/health" && pathname !== "/api/v1/meta") {
        enforceAuth(req, pathname);
      }

      const matched = router.match(req.method, pathname);
      if (!matched) throw new HttpError(404, "接口不存在", "not_found");
      if (matched.error === 405) throw new HttpError(405, "请求方法不支持", "method_not_allowed");

      const query = Object.fromEntries(url.searchParams.entries());
      const needsBody = req.method === "POST" || req.method === "PATCH" || req.method === "PUT";
      const body = needsBody ? await readJsonBody(req) : {};
      const result = await matched.handler({ params: matched.params, query, body, req, repo, views });
      sendJson(res, req.method === "POST" && pathname === "/api/v1/domains" ? 201 : 200, result ?? { ok: true });
    } catch (error) {
      if (error instanceof HttpError) {
        sendJson(
          res,
          error.status,
          { error: { code: error.code, message: error.message, details: error.details } },
          error.headers ?? {},
        );
        return;
      }
      logger.error?.("[thread-pocket] unhandled error", error);
      sendJson(res, 500, { error: { code: "internal_error", message: "服务器内部错误" } });
    }
  }

  function sendResult(res, result) {
    if (!result) {
      sendJson(res, 200, { ok: true });
      return;
    }
    const headers = result.headers ?? {};
    const body = result.body ?? "";
    res.writeHead(result.status ?? 200, { ...headers, "content-length": Buffer.byteLength(body) });
    res.end(body);
  }

  /** 统一的鉴权入口：静态密钥、OAuth 访问令牌或同源浏览器会话。 */
  function enforceAuth(req, pathname) {
    const principal = authorizer.resolve(req, { pathname, method: req.method });
    const resource = pathname.startsWith("/api/") ? "api" : "mcp";
    if (principal.kind === "anonymous" || principal.kind === "invalid") {
      const headers = {
        "www-authenticate": principal.kind === "invalid"
          ? authorizer.challengeValue(principal)
          : authorizer.challenge(req, resource, principal.required.join(" ")),
      };
      throw new HttpError(
        401,
        principal.kind === "invalid" ? principal.reason : "需要登录或提供访问令牌",
        principal.kind === "invalid" ? "invalid_token" : "unauthorized",
        undefined,
        headers,
      );
    }
    const missing = authorizer.missingScopes(principal);
    if (missing.length > 0) {
      throw new HttpError(403, `当前凭证缺少权限：${missing.join(", ")}`, "insufficient_scope", undefined, {
        "www-authenticate": authorizer.challenge(req, resource, missing.join(" ")),
      });
    }
    return principal;
  }

  async function handleMcp(req, res) {
    res.setHeader("mcp-protocol-version", "2025-06-18");
    if (req.method === "GET") {
      // 无状态实现不提供服务端推送流；按规范返回 405 让客户端退回 POST。
      res.writeHead(405, { allow: "POST, DELETE", "content-type": "application/json; charset=utf-8" });
      res.end(JSON.stringify({ error: "该 MCP 端点不提供 SSE 流，请使用 POST" }));
      return;
    }
    if (req.method === "DELETE") {
      // 无会话状态，删除请求总是成功
      res.writeHead(204);
      res.end();
      return;
    }
    if (req.method !== "POST") {
      res.writeHead(405, { allow: "POST, DELETE", "content-type": "application/json; charset=utf-8" });
      res.end(JSON.stringify({ error: "只支持 POST" }));
      return;
    }

    const principal = enforceAuth(req, "/mcp");
    if (config.logRequests) {
      logger.log?.(`[thread-pocket] MCP ${req.method} 来自 ${principal.kind}`);
    }
    // MCP 自己解析请求体：这里不能用通用的 JSON 校验，
    // 否则批量请求之类的协议级错误会变成 HTTP 400 而不是 JSON-RPC 错误。
    const raw = await readRawBody(req);
    const { status, payload } = mcp.handle(raw === null ? {} : raw);
    if (payload === null) {
      res.writeHead(202);
      res.end();
      return;
    }
    sendJson(res, status, payload);
  }

  const server = http.createServer((req, res) => {
    handler(req, res).catch((error) => {
      logger.error?.("[thread-pocket] fatal handler error", error);
      if (!res.headersSent) sendJson(res, 500, { error: { code: "internal_error", message: "服务器内部错误" } });
      else res.end();
    });
  });

  return {
    server,
    repo,
    views,
    db,
    auth: {
      config,
      store: authStore,
      routes: authRoutes,
      authorizer,
      setupToken,
    },
    mcp,
    close: () =>
      new Promise((resolve) => {
        clearInterval(sweepTimer);
        // fetch 的 keep-alive 连接会让 close() 一直等待，测试里必须先断开空闲连接
        server.closeAllConnections?.();
        server.close(() => resolve());
      }),
    dispose() {
      clearInterval(sweepTimer);
    },
    setupToken,
    get mutationCount() {
      return mutationCount;
    },
  };
}

export function listen({ port = 8787, host = "127.0.0.1", dbFile, apiKey, logger = console } = {}) {
  const app = createServer({ dbFile, apiKey, logger, env: { ...process.env, HOST: host } });
  return new Promise((resolve, reject) => {
    app.server.once("error", reject);
    app.server.listen(port, host, () => {
      resolve({ ...app, port, host });
    });
  });
}
