#!/usr/bin/env node
import path from "node:path";
import { fileURLToPath } from "node:url";
import { listen } from "./server.js";

const HERE = path.dirname(fileURLToPath(import.meta.url));

const port = Number(process.env.PORT ?? process.env.THREADPOCKET_PORT ?? 8787);
const host = process.env.HOST ?? process.env.THREADPOCKET_HOST ?? "127.0.0.1";
const dbFile = process.env.THREADPOCKET_DB ?? path.resolve(HERE, "..", "data", "thread-pocket.sqlite");
const apiKey = process.env.THREADPOCKET_API_KEY?.trim() || null;

const app = await listen({ port, host, dbFile, apiKey });

console.log(`[thread-pocket] server listening on http://${host}:${port}`);
console.log(`[thread-pocket] database: ${dbFile}`);
console.log(`[thread-pocket] auth: ${apiKey ? "bearer token required" : "open (no token configured)"}`);
console.log(`[thread-pocket] web console: http://${host}:${port}/`);

const shutdown = async (signal) => {
  console.log(`\n[thread-pocket] received ${signal}, shutting down`);
  await app.close();
  process.exit(0);
};

process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));
