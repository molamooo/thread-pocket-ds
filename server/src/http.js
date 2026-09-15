import { HttpError } from "./util.js";

export const MAX_BODY_BYTES = 1024 * 1024;

export function createRouter() {
  const routes = [];

  function add(method, pattern, handler) {
    routes.push({
      method,
      segments: pattern.split("/").filter(Boolean),
      handler,
    });
  }

  function match(method, pathname) {
    const parts = pathname.split("/").filter(Boolean);
    let pathMatched = false;
    for (const route of routes) {
      if (route.segments.length !== parts.length) continue;
      const params = {};
      let ok = true;
      for (let i = 0; i < route.segments.length; i += 1) {
        const segment = route.segments[i];
        if (segment.startsWith(":")) {
          params[segment.slice(1)] = decodeURIComponent(parts[i]);
        } else if (segment !== parts[i]) {
          ok = false;
          break;
        }
      }
      if (!ok) continue;
      pathMatched = true;
      if (route.method === method) return { handler: route.handler, params };
    }
    return pathMatched ? { error: 405 } : null;
  }

  return {
    get: (pattern, handler) => add("GET", pattern, handler),
    post: (pattern, handler) => add("POST", pattern, handler),
    patch: (pattern, handler) => add("PATCH", pattern, handler),
    put: (pattern, handler) => add("PUT", pattern, handler),
    delete: (pattern, handler) => add("DELETE", pattern, handler),
    match,
    routes,
  };
}

export async function readJsonBody(req) {
  const raw = await readRawBody(req);
  if (raw === null) return {};
  try {
    const parsed = JSON.parse(raw);
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
      throw new HttpError(400, "请求体需要是 JSON 对象", "bad_request");
    }
    return parsed;
  } catch (error) {
    if (error instanceof HttpError) throw error;
    throw new HttpError(400, "请求体不是合法 JSON", "bad_request");
  }
}

export async function readRawBody(req) {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > MAX_BODY_BYTES) throw new HttpError(413, "请求体过大", "payload_too_large");
    chunks.push(chunk);
  }
  if (size === 0) return null;
  return Buffer.concat(chunks).toString("utf8");
}

/**
 * 同时接受 JSON 与表单编码：OAuth 端点按规范用表单，
 * 应用与测试更习惯 JSON，两者都支持可以少很多边界问题。
 */
export async function readAnyBody(req) {
  const raw = await readRawBody(req);
  if (raw === null) return {};
  const contentType = String(req.headers["content-type"] ?? "").toLowerCase();
  if (contentType.includes("application/x-www-form-urlencoded")) {
    return Object.fromEntries(new URLSearchParams(raw));
  }
  try {
    const parsed = JSON.parse(raw);
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
      throw new HttpError(400, "请求体需要是 JSON 对象或表单", "bad_request");
    }
    return parsed;
  } catch (error) {
    if (error instanceof HttpError) throw error;
    throw new HttpError(400, "请求体不是合法 JSON", "bad_request");
  }
}

export function sendJson(res, status, payload, headers = {}) {
  const body = JSON.stringify(payload, null, 2);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(body),
    "cache-control": "no-store",
    ...headers,
  });
  res.end(body);
}

export function sendText(res, status, body, contentType = "text/plain; charset=utf-8") {
  res.writeHead(status, {
    "content-type": contentType,
    "content-length": Buffer.byteLength(body),
    "cache-control": "no-store",
  });
  res.end(body);
}

export function applyCors(res) {
  res.setHeader("access-control-allow-origin", "*");
  res.setHeader("access-control-allow-methods", "GET,POST,PATCH,PUT,DELETE,OPTIONS");
  res.setHeader(
    "access-control-allow-headers",
    "content-type,authorization,x-api-key,mcp-session-id,mcp-protocol-version,last-event-id",
  );
  res.setHeader("access-control-expose-headers", "mcp-session-id,mcp-protocol-version");
  res.setHeader("access-control-max-age", "86400");
}

export function bearerFrom(req) {
  const header = req.headers.authorization;
  if (typeof header === "string" && header.toLowerCase().startsWith("bearer ")) {
    return header.slice(7).trim();
  }
  const apiKey = req.headers["x-api-key"];
  if (typeof apiKey === "string" && apiKey.trim()) return apiKey.trim();
  return null;
}
