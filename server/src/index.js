#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { listen } from "./server.js";
import { isLoopbackHost } from "./auth/config.js";

const HERE = path.dirname(fileURLToPath(import.meta.url));

const port = Number(process.env.PORT ?? process.env.THREADPOCKET_PORT ?? 8787);
const host = process.env.HOST ?? process.env.THREADPOCKET_HOST ?? "127.0.0.1";
const dbFile = process.env.THREADPOCKET_DB ?? path.resolve(HERE, "..", "data", "thread-pocket.sqlite");
const apiKey = process.env.THREADPOCKET_API_KEY?.trim() || null;
const publicUrl = process.env.THREADPOCKET_PUBLIC_URL?.trim() || null;
const allowInsecure = ["1", "true", "yes"].includes(process.env.THREADPOCKET_ALLOW_INSECURE ?? "");

// 防止把个人数据以「无任何鉴权」的方式暴露到公网：这是最常见的部署事故。
const exposedWithoutAuth =
  !isLoopbackHost(host) && !apiKey && !publicUrl && !allowInsecure;
if (exposedWithoutAuth) {
  console.error(
    [
      "[thread-pocket] 拒绝启动：监听地址不是本机，但还没有配置任何鉴权。",
      "",
      "请任选一种方式：",
      "  1. 配置 THREADPOCKET_PUBLIC_URL=https://你的域名 并先完成账号初始化（推荐）；",
      "  2. 或配置 THREADPOCKET_API_KEY=<至少 16 位随机串>；",
      "  3. 确实只是想临时试探，可设置 THREADPOCKET_ALLOW_INSECURE=1。",
    ].join("\n"),
  );
  process.exit(1);
}

const app = await listen({ port, host, dbFile, apiKey });

const baseUrl = publicUrl ?? `http://${host === "0.0.0.0" ? "127.0.0.1" : host}:${port}`;

console.log(`[thread-pocket] server listening on http://${host}:${port}`);
console.log(`[thread-pocket] database: ${dbFile}`);
console.log(`[thread-pocket] auth: ${describeAuth(app)}`);
console.log(`[thread-pocket] web console: http://${host}:${port}/`);
console.log(`[thread-pocket] MCP endpoint: ${baseUrl}/mcp`);

const linkFile = path.resolve(path.dirname(dbFile), "setup-link.txt");

if (app.setupToken && !app.auth.store.initialized()) {
  const link = `${baseUrl}/auth/setup#token=${encodeURIComponent(app.setupToken)}`;
  try {
    fs.writeFileSync(linkFile, `${link}\n`, { mode: 0o600 });
  } catch (error) {
    console.error(`[thread-pocket] 无法写入 ${linkFile}：${error.message}`);
  }
  console.log("");
  console.log("[thread-pocket] 还没有账号。打开下面的链接创建个人账号（只建立一次）：");
  console.log(`[thread-pocket]   ${link}`);
  console.log(`[thread-pocket] 链接同时保存在 ${linkFile}，可用 npm run setup:link 再次获取。`);
  console.log("");
} else if (!app.auth.store.initialized()) {
  console.log("[thread-pocket] 还没有账号；本机可直接访问 /auth/setup 完成初始化。");
} else {
  // 账号已建立：一次性凭证文件已经没有用处，留着只会多一份残留密钥。
  try {
    fs.rmSync(linkFile, { force: true });
  } catch {
    /* 删不掉也不影响运行 */
  }
}

function describeAuth(app) {
  if (app.auth.config.staticKey) return "static bearer token";
  if (app.auth.store.initialized()) {
    return app.auth.authorizer.trustLoopback
      ? "OAuth enabled · 本机免登录，其他来源需要令牌"
      : "OAuth enabled · 所有请求都需要登录或令牌";
  }
  return "open (还没有账号，也没有静态密钥)";
}

const shutdown = async (signal) => {
  console.log(`\n[thread-pocket] received ${signal}, shutting down`);
  await app.close();
  process.exit(0);
};

process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));
