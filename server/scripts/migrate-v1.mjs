#!/usr/bin/env node
/**
 * 把旧实现（Obsidian Markdown + /api/threads）的数据迁移到新实现。
 *
 *   node scripts/migrate-v1.mjs --source http://localhost:17633 --target https://pocket.example.com --login --dry-run
 *   node scripts/migrate-v1.mjs --source http://localhost:17633 --target https://pocket.example.com --login
 *
 * 旧 → 新 的映射：
 *   topic（工作/装修/生活）        → Domain
 *   thread.now                     → Thread 当前描述
 *   标题为「收集箱」的 thread        → 该 Domain 自动创建的收件箱 Thread
 *   entry kind=task/event/wait/direction → Item（同 kind）
 *   entry kind=note                → Thread 的唯一一份自由笔记（多条则合并）
 *   entry done/cancelled           → status=done/cancelled（wait 的 done → resolved）
 *   entry scheduled/due/followUp   → plan_date / due_date / follow_up_date（纯日期）
 *   entry scheduled（event）        → plan_date（旧数据只有日期，不编造时刻）
 *   entry blockedBy                → blocked=true + blocker_reason
 *   logs                           → 日志（保留原发生时间与 actor；自动操作类降为 operation）
 */
import http from "node:http";
import { createPkcePair } from "../src/auth/crypto.js";

/* ---------------------------------- 参数 ---------------------------------- */

const args = process.argv.slice(2);
const flag = (name) => args.includes(`--${name}`);
const value = (name, fallback = null) => {
  const index = args.indexOf(`--${name}`);
  return index === -1 ? fallback : args[index + 1] ?? fallback;
};

const sourceUrl = value("source", "http://localhost:17633");
const sourceFile = value("source-file");
const targetUrl = value("target");
const token = value("token") ?? process.env.THREADPOCKET_TOKEN ?? null;
const dryRun = flag("dry-run");
const useLogin = flag("login");
const skipLegacyOps = flag("skip-legacy-ops");
const keepMigrationOps = flag("keep-migration-ops");
const onlyTopics = (value("topics") ?? "")
  .split(",")
  .map((item) => item.trim())
  .filter(Boolean);

if (!targetUrl) {
  console.error("缺少 --target，例如 --target https://pocket.example.com");
  process.exit(1);
}

/* -------------------------------- 工具函数 -------------------------------- */

const log = (...parts) => console.log(...parts);
const trimSlash = (url) => url.replace(/\/+$/, "");

async function request(url, { method = "GET", body, bearer, headers = {} } = {}) {
  const init = { method, headers: { ...headers } };
  if (body !== undefined) {
    init.headers["content-type"] = "application/json";
    init.body = JSON.stringify(body);
  }
  if (bearer) init.headers.authorization = `Bearer ${bearer}`;
  const response = await fetch(url, init);
  const text = await response.text();
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    json = null;
  }
  if (!response.ok) {
    const message = json?.error?.message ?? text.slice(0, 200);
    const error = new Error(`${response.status} ${message}`);
    error.status = response.status;
    error.payload = json;
    throw error;
  }
  return json;
}

/** 旧日志形如 "2026-09-08T07:19:13.687Z You: 新增事项「x」" 或 "2026-09-07 11:06 You: …"。 */
function parseLog(raw) {
  const text = typeof raw === "string" ? raw : String(raw?.text ?? JSON.stringify(raw));
  const match = text.match(
    // 时间戳优先匹配「带时刻」的形式，避免把 "2026-09-15 03:30:57.520Z" 误判成纯日期；
    // actor 必须以字母或汉字开头（You / Agent / Mola），否则会把时间的小时当成 actor。
    /^(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?|\d{4}-\d{2}-\d{2})\s+([A-Za-z\u4e00-\u9fff][^:：]{0,15})[:：]\s*([\s\S]*)$/,
  );
  if (!match) return { at: null, actor: "user", body: text };
  const [, stamp, who, rest] = match;
  let at = null;
  if (stamp.includes("T")) {
    const parsed = new Date(stamp);
    at = Number.isNaN(parsed.getTime()) ? null : parsed.toISOString();
  } else if (stamp.includes(" ")) {
    // "2026-09-15 03:30" / "2026-09-15 03:30:57.520Z" 都按本地时间理解
    const [date, time] = stamp.split(" ");
    const [y, m, d] = date.split("-").map(Number);
    const [hh, mm] = time.split(":").map(Number);
    at = new Date(y, m - 1, d, hh, mm).toISOString();
  } else {
    // 只有日期，没有时刻：按当天本地零点
    const [y, m, d] = stamp.split("-").map(Number);
    at = new Date(y, m - 1, d, 0, 0).toISOString();
  }
  const name = who.trim();
  const actor = name.toLowerCase() === "agent" ? "agent" : name.toLowerCase() === "you" ? "user" : name;
  return { at, actor, body: rest };
}

/** 旧实现里由系统自动写入的操作记录，迁移后降为弱化的 operation 记录。 */
const OPERATION_PATTERNS = [
  /^新增(事项|方向|笔记|等待|日程)/,
  /^「[^」]*」(完成事项|解除等待|取消|删除)/,
  /^删除「/,
  /^创建 Thread/,
  /^状态：/,
  /^类型：/,
  /^标题：/,
  /^更新当前描述/,
  /^移动到/,
];

const isOperationLog = (text) => OPERATION_PATTERNS.some((pattern) => pattern.test(text.trim()));

/* ------------------------------- 读取旧数据 ------------------------------- */

async function loadOldThreads() {
  if (sourceFile) {
    const { readFile } = await import("node:fs/promises");
    const parsed = JSON.parse(await readFile(sourceFile, "utf8"));
    return parsed.threads ?? parsed;
  }
  const data = await request(`${trimSlash(sourceUrl)}/api/threads`);
  return data.threads ?? [];
}

/* --------------------------------- 登录 ---------------------------------- */

async function signIn(origin) {
  const resource = await request(`${origin}/.well-known/oauth-protected-resource`);
  const issuer = resource.authorization_servers?.[0] ?? origin;
  const metadata = await request(`${issuer}/.well-known/oauth-authorization-server`);

  const server = http.createServer();
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = server.address().port;
  const redirectUri = `http://127.0.0.1:${port}/callback`;
  const scope = "threads:read threads:write offline_access";

  const registration = await request(metadata.registration_endpoint, {
    method: "POST",
    body: {
      client_name: "Thread Pocket 迁移脚本",
      redirect_uris: [redirectUri],
      scope,
      token_endpoint_auth_method: "none",
    },
  });
  const pkce = createPkcePair();
  const state = createPkcePair().verifier.slice(0, 24);

  const authorizeUrl = new URL(metadata.authorization_endpoint);
  authorizeUrl.search = new URLSearchParams({
    response_type: "code",
    client_id: registration.client_id,
    redirect_uri: redirectUri,
    scope,
    state,
    code_challenge: pkce.challenge,
    code_challenge_method: "S256",
  }).toString();

  const codePromise = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("等待浏览器授权超时")), 300_000);
    server.on("request", (req, res) => {
      const url = new URL(req.url, `http://127.0.0.1:${port}`);
      if (url.pathname !== "/callback") {
        res.writeHead(404).end();
        return;
      }
      res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
      res.end("<meta charset='utf-8'><body style='font:15px -apple-system;padding:40px'>已收到授权，可以关闭这个页面，回到终端查看迁移进度。</body>");
      clearTimeout(timer);
      if (url.searchParams.get("error")) {
        reject(new Error(url.searchParams.get("error_description") ?? url.searchParams.get("error")));
      } else if (url.searchParams.get("state") !== state) {
        reject(new Error("state 校验失败"));
      } else {
        resolve(url.searchParams.get("code"));
      }
    });
  });

  log("");
  log("请在浏览器里完成登录并授权（3 分钟内有效）：");
  log(`  ${authorizeUrl}`);
  log("");
  const { spawn } = await import("node:child_process");
  const opener = process.platform === "darwin" ? "open" : "xdg-open";
  spawn(opener, [authorizeUrl.toString()], { stdio: "ignore" }).on("error", () => {});

  const code = await codePromise;
  server.close();

  const response = await fetch(metadata.token_endpoint, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "authorization_code",
      client_id: registration.client_id,
      code,
      code_verifier: pkce.verifier,
      redirect_uri: redirectUri,
    }),
  });
  const payload = await response.json();
  if (!response.ok) throw new Error(`换取令牌失败：${payload.error_description ?? payload.error}`);
  log(`已登录，授权范围：${payload.scope}`);
  return payload.access_token;
}

/* --------------------------------- 映射 ---------------------------------- */

function buildPlan(threads) {
  const selected = onlyTopics.length ? threads.filter((t) => onlyTopics.includes(t.topic)) : threads;
  const skipped = selected.filter((t) => t.deleted);
  const kept = selected.filter((t) => !t.deleted);
  const stats = {
    domains: [...new Set(kept.map((t) => t.topic))].length,
    threads: kept.filter((t) => t.title !== "收集箱").length,
    inboxes: kept.filter((t) => t.title === "收集箱").length,
    items: 0,
    events: 0,
    notes: 0,
    logs: 0,
  };
  for (const thread of kept) {
    const entries = thread.entries ?? [];
    stats.items += entries.filter((e) => e.kind !== "note").length;
    stats.events += entries.filter((e) => e.kind === "event").length;
    if (entries.some((e) => e.kind === "note")) stats.notes += 1;
    stats.logs += (thread.logs ?? []).length;
  }
  return { kept, topics: [...new Set(kept.map((t) => t.topic))], stats, skipped };
}

function threadStatus(old) {
  if (old === "done") return "completed";
  if (old === "waiting" || old === "paused") return old;
  return "active";
}

function itemPayload(entry) {
  if (entry.kind === "note") return null;
  const done = Boolean(entry.done);
  const cancelled = Boolean(entry.cancelled);
  const scheduled = String(entry.scheduled ?? "").trim().slice(0, 10);
  const due = String(entry.due ?? "").trim().slice(0, 10);
  const followUp = String(entry.followUp ?? "").trim().slice(0, 10);
  const end = String(entry.end ?? "").trim();
  const blockedBy = String(entry.blockedBy ?? "").trim();

  const payload = {
    id: entry.id,
    kind: entry.kind,
    title: entry.title,
    status: cancelled ? "cancelled" : done ? (entry.kind === "wait" ? "resolved" : "done") : "open",
  };
  if (entry.kind === "event") {
    // 旧数据的事件只有日期、没有时刻：保留到天的精度，不编造时间
    if (scheduled) payload.plan_date = scheduled;
    if (due) payload.due_date = due;
    if (end && end.includes("T")) payload.end_at = end;
    return payload;
  }
  if (scheduled) payload.plan_date = scheduled;
  if (due) payload.due_date = due;
  if (followUp) payload.follow_up_date = followUp;
  if (blockedBy) {
    payload.blocked = true;
    payload.blocker_reason = blockedBy;
  }
  return payload;
}

function composeNote(entries) {
  const notes = entries.filter((entry) => entry.kind === "note");
  if (notes.length === 0) return null;
  return notes
    .map((entry) => {
      const title = String(entry.title ?? "").trim();
      const body = String(entry.body ?? "").trim();
      if (title && body) return `## ${title}\n\n${body}`;
      return title || body;
    })
    .filter(Boolean)
    .join("\n\n---\n\n");
}

/* --------------------------------- 写入 ---------------------------------- */

async function migrate({ origin, bearer, threads }) {
  const api = (path, options = {}) => request(`${origin}${path}`, { ...options, bearer });
  const runStartedAt = new Date().toISOString();
  const existingDomains = await api("/api/v1/domains");
  const domainByName = new Map(existingDomains.domains.map((domain) => [domain.name, domain]));
  const inboxByDomain = new Map();
  const report = {
    domainsCreated: [],
    threadsCreated: [],
    threadsReused: [],
    inboxesMerged: [],
    itemsCreated: 0,
    itemsSkipped: 0,
    notes: 0,
    logs: 0,
    logsSkipped: 0,
    opsDropped: 0,
    errors: [],
  };

  for (const name of [...new Set(threads.map((thread) => thread.topic))]) {
    if (domainByName.has(name)) continue;
    const created = await api("/api/v1/domains", { method: "POST", body: { name } });
    domainByName.set(name, created.domain);
    report.domainsCreated.push(name);
  }

  for (const [name, domain] of domainByName) {
    const list = await api(`/api/v1/threads?domain_id=${encodeURIComponent(domain.id)}`);
    const inbox = list.threads.find((thread) => thread.is_inbox);
    if (inbox) inboxByDomain.set(name, inbox);
  }

  /** 按标题复用已有线索，保证脚本可以重复执行（中途失败后再跑不会产生重复）。 */
  async function findThreadByTitle(domainId, title) {
    const list = await api(`/api/v1/threads?domain_id=${encodeURIComponent(domainId)}`);
    return list.threads.find((thread) => thread.title === title) ?? null;
  }

  for (const thread of threads) {
    const domain = domainByName.get(thread.topic);
    if (!domain) continue;

    // 旧的「收集箱」直接并入该 Domain 已有的收件箱，不新建
    let targetId = null;
    if (thread.title === "收集箱" && inboxByDomain.has(thread.topic)) {
      targetId = inboxByDomain.get(thread.topic).id;
      report.inboxesMerged.push(`${thread.topic}/收集箱`);
    } else {
      const existing = await findThreadByTitle(domain.id, thread.title);
      if (existing) {
        targetId = existing.id;
        report.threadsReused.push(`${thread.topic}/${thread.title}`);
      } else {
        const created = await api("/api/v1/threads", {
          method: "POST",
          body: {
            domain_id: domain.id,
            title: thread.title,
            summary: String(thread.now ?? "").trim(),
          },
        });
        targetId = created.thread.id;
        report.threadsCreated.push(`${thread.topic}/${thread.title}`);
      }
    }

    const entries = [...(thread.entries ?? [])];
    for (const entry of entries) {
      const payload = itemPayload(entry);
      if (!payload) continue;
      try {
        await api(`/api/v1/threads/${targetId}/items`, { method: "POST", body: payload });
        report.itemsCreated += 1;
      } catch (error) {
        if (error.status === 409) {
          report.itemsSkipped += 1;
        } else {
          report.errors.push(`${thread.title} / ${entry.title}：${error.message}`);
        }
      }
    }

    const note = composeNote(entries);
    if (note) {
      await api(`/api/v1/threads/${targetId}/note`, { method: "PUT", body: { content: note } });
      report.notes += 1;
    }

    // 重跑时不要重复写历史日志：按「发生时间 + 正文」去重
    const bundle = await api(`/api/v1/threads/${targetId}`);
    const seenLogs = new Set(
      (bundle.logs ?? []).map((entry) => `${entry.created_at}\u0000${entry.text}`),
    );

    for (const raw of thread.logs ?? []) {
      const parsed = parseLog(raw);
      const operation = isOperationLog(parsed.body);
      if (skipLegacyOps && operation) continue;
      const body = {
        text: parsed.body.slice(0, 8000),
        actor: parsed.actor,
        kind: operation ? "operation" : "progress",
      };
      if (parsed.at) body.occurred_at = parsed.at;
      if (parsed.at && seenLogs.has(`${parsed.at}\u0000${body.text}`)) {
        report.logsSkipped += 1;
        continue;
      }
      await api(`/api/v1/threads/${targetId}/logs`, { method: "POST", body });
      report.logs += 1;
    }

    const patch = {};
    if (thread.status && threadStatus(thread.status) !== "active") patch.status = threadStatus(thread.status);
    if (thread.archived) patch.archived = true;
    if (Object.keys(patch).length > 0) {
      await api(`/api/v1/threads/${targetId}`, { method: "PATCH", body: patch });
    }

    // 导入过程中服务端会为每个条目写一条「新增待办：…」操作记录。
    // 这些记录的正文与条目本身重复，会把真正的历史压到下面，因此默认清掉
    // （导入的历史日志 action 是 progress.note，不会被误删）。
    if (!keepMigrationOps) {
      const after = await api(`/api/v1/threads/${targetId}`);
      const noise = (after.logs ?? []).filter(
        (entry) => entry.action !== "progress.note" && entry.created_at >= runStartedAt,
      );
      for (const entry of noise) {
        await api(`/api/v1/logs/${entry.id}`, { method: "DELETE" });
        report.opsDropped += 1;
      }
    }
  }

  return report;
}

/* ---------------------------------- 主流程 --------------------------------- */

const origin = trimSlash(targetUrl);

// 迁移依赖两个服务端能力（创建条目时指定 id、日志写入 occurred_at），
// 目标跑的是旧版本时先拦住，避免出现「id 丢失 / 日志时间全变成现在」这种半成品结果。
const meta = await request(`${origin}/api/v1/meta`);
const requiredApi = [1, 1, 0];
const currentApi = String(meta.api_version ?? "0").split(".").map(Number);
const outdated = requiredApi.some((part, index) => (currentApi[index] ?? 0) < part);
if (outdated) {
  console.error(
    [
      `目标服务版本过旧：api_version=${meta.api_version ?? "未知"}，迁移需要 1.1.0 以上。`,
      "请先在服务器上更新并重启后端（git pull && systemctl restart thread-pocket），再运行迁移。",
    ].join("\n"),
  );
  process.exit(1);
}

const oldThreads = await loadOldThreads();
const { kept, topics, stats, skipped } = buildPlan(oldThreads);

log(`数据源：${sourceFile ?? trimSlash(sourceUrl)}`);
log(`目标：${origin}`);
log("");
log("迁移计划：");
log(`  Domain ${stats.domains} 个：${topics.join(" / ")}`);
log(`  线索 ${stats.threads} 条 + 收集箱 ${stats.inboxes} 个（并入已有收件箱）`);
log(`  条目 ${stats.items} 个，其中固定日程 ${stats.events} 个`);
log(`  笔记 ${stats.notes} 份（旧模型多条 note 会合并成一份）`);
log(`  日志 ${stats.logs} 条`);
if (skipped.length > 0) {
  log(`  跳过已删除的线索 ${skipped.length} 条：${skipped.map((thread) => thread.title).join("、")}`);
}
log("");

if (dryRun) {
  log("（--dry-run，没有写入任何数据）");
  const sample = kept.find((thread) => (thread.entries ?? []).length > 2) ?? kept[0];
  log("");
  log(`样例转换：${sample.topic}/${sample.title}`);
  log(`  当前描述：${String(sample.now ?? "").trim() || "（空）"}`);
  const sampleNote = composeNote(sample.entries ?? []);
  if (sampleNote) log(`  笔记：${sampleNote.slice(0, 80).replace(/\n/g, " ")}…`);
  for (const entry of (sample.entries ?? []).slice(0, 6)) {
    const payload = itemPayload(entry);
    if (!payload) continue;
    const extra = ["plan_date", "due_date", "follow_up_date", "end_at"]
      .filter((key) => payload[key])
      .map((key) => `${key}=${payload[key]}`)
      .join(" ");
    log(`  [${payload.kind}] ${payload.title} → status=${payload.status}${extra ? ` ${extra}` : ""}`);
  }
  const sampleLog = (sample.logs ?? [])[0];
  if (sampleLog) {
    const parsed = parseLog(sampleLog);
    log(`  日志：${parsed.at ?? "无时间"} ${parsed.actor} [${isOperationLog(parsed.body) ? "operation" : "progress"}] ${parsed.body.slice(0, 50)}`);
  }
  process.exit(0);
}

/** 目标是否需要凭证：先用匿名请求探一下，避免对开放的本机实例强行走登录。 */
async function needsAuth() {
  if (token) return false;
  try {
    await request(`${origin}/api/v1/domains`);
    return false;
  } catch (error) {
    return error.status === 401 || error.status === 403;
  }
}

let bearer = token ?? null;
if (useLogin || !bearer) {
  if (useLogin || (await needsAuth())) {
    bearer = await signIn(origin);
  }
}
log("开始写入…");
const report = await migrate({ origin, bearer, threads: kept });

log("");
log("迁移完成：");
log(`  新建 Domain ${report.domainsCreated.length} 个${report.domainsCreated.length ? `：${report.domainsCreated.join("、")}` : ""}`);
log(`  新建线索 ${report.threadsCreated.length} 条${report.threadsReused.length ? `，复用已有 ${report.threadsReused.length} 条` : ""}`);
log(`  收集箱并入 ${report.inboxesMerged.length} 个`);
log(`  写入条目 ${report.itemsCreated} 个${report.itemsSkipped ? `（跳过已存在 ${report.itemsSkipped} 个）` : ""}`);
log(`  写入笔记 ${report.notes} 份、日志 ${report.logs} 条${report.logsSkipped ? `（跳过已存在 ${report.logsSkipped} 条）` : ""}`);
if (report.opsDropped > 0) {
  log(`  清理导入过程产生的操作记录 ${report.opsDropped} 条（用 --keep-migration-ops 可保留）`);
}
if (report.errors.length > 0) {
  log(`  失败 ${report.errors.length} 项：`);
  for (const message of report.errors.slice(0, 20)) log(`    - ${message}`);
  process.exitCode = 1;
}
