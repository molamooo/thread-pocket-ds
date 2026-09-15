import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createApi } from "./api.js";
import { openDatabase } from "./db.js";
import { applyCors, bearerFrom, readJsonBody, sendJson, sendText } from "./http.js";
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

export function createServer({ dbFile = ":memory:", apiKey = null, logger = console } = {}) {
  const db = openDatabase(dbFile);
  const repo = createRepository(db);
  const views = createViews(repo);
  let mutationCount = 0;
  const router = createApi({ repo, views, onMutate: () => { mutationCount += 1; } });

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

    const isApi = pathname.startsWith("/api/") || pathname === "/health";
    if (!isApi) {
      serveStatic(res, pathname);
      return;
    }

    try {
      if (apiKey && pathname !== "/health" && pathname !== "/api/v1/meta") {
        if (bearerFrom(req) !== apiKey) {
          throw new HttpError(401, "缺少或错误的访问令牌", "unauthorized");
        }
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
        sendJson(res, error.status, { error: { code: error.code, message: error.message, details: error.details } });
        return;
      }
      logger.error?.("[thread-pocket] unhandled error", error);
      sendJson(res, 500, { error: { code: "internal_error", message: "服务器内部错误" } });
    }
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
    close: () => new Promise((resolve) => server.close(resolve)),
    get mutationCount() {
      return mutationCount;
    },
  };
}

export function listen({ port = 8787, host = "127.0.0.1", dbFile, apiKey, logger = console } = {}) {
  const app = createServer({ dbFile, apiKey, logger });
  return new Promise((resolve, reject) => {
    app.server.once("error", reject);
    app.server.listen(port, host, () => {
      resolve({ ...app, port, host });
    });
  });
}
