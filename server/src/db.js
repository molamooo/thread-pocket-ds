import fs from "node:fs";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { nowIso, newId } from "./util.js";

const SCHEMA = `
create table if not exists domains (
  id text primary key,
  name text not null,
  color text not null default 'blue',
  icon text,
  position integer not null default 0,
  archived integer not null default 0,
  created_at text not null,
  updated_at text not null
);

create table if not exists threads (
  id text primary key,
  domain_id text not null references domains(id) on delete cascade,
  title text not null,
  summary text not null default '',
  status text not null default 'active',
  is_inbox integer not null default 0,
  position integer not null default 0,
  revision integer not null default 1,
  archived_at text,
  trashed_at text,
  created_at text not null,
  updated_at text not null
);

create table if not exists items (
  id text primary key,
  thread_id text not null references threads(id) on delete cascade,
  kind text not null,
  title text not null,
  status text not null default 'open',
  detail text,
  plan_date text,
  due_date text,
  start_at text,
  end_at text,
  follow_up_date text,
  blocked integer not null default 0,
  blocker_reason text,
  source_id text,
  position integer not null default 0,
  created_at text not null,
  updated_at text not null,
  closed_at text
);

create table if not exists notes (
  thread_id text primary key references threads(id) on delete cascade,
  content text not null default '',
  updated_at text not null
);

create table if not exists log_entries (
  id text primary key,
  thread_id text not null references threads(id) on delete cascade,
  kind text not null,
  action text not null,
  text text not null,
  meta text,
  actor text not null default 'user',
  created_at text not null
);

create index if not exists idx_threads_domain on threads(domain_id);
create index if not exists idx_items_thread on items(thread_id);
create index if not exists idx_items_kind_status on items(kind, status);
create index if not exists idx_items_plan on items(plan_date);
create index if not exists idx_items_due on items(due_date);
create index if not exists idx_logs_thread on log_entries(thread_id, created_at);
`;

/**
 * 账号与授权。与业务数据分表，但共用同一个 SQLite 文件，因此备份即复制一个文件。
 */
const AUTH_SCHEMA = `
create table if not exists auth_users (
  id text primary key,
  email text not null unique,
  name text not null default 'Owner',
  password_hash text not null,
  created_at text not null,
  updated_at text not null
);

create table if not exists auth_sessions (
  token_hash text primary key,
  user_id text not null references auth_users(id) on delete cascade,
  user_agent text,
  created_at text not null,
  expires_at text not null
);

create index if not exists idx_auth_sessions_user on auth_sessions(user_id);

-- OAuth 客户端：来自动态注册、客户端元数据文档（CIMD）或环境变量预注册
create table if not exists oauth_clients (
  id text primary key,
  name text not null,
  redirect_uris text not null,
  scopes text not null,
  source text not null default 'dcr',
  metadata_url text,
  created_at text not null,
  last_used_at text
);

-- 授权码：只存哈希，短有效期，一次性
create table if not exists oauth_codes (
  code_hash text primary key,
  client_id text not null references oauth_clients(id) on delete cascade,
  user_id text not null references auth_users(id) on delete cascade,
  redirect_uri text not null,
  scopes text not null,
  code_challenge text not null,
  code_challenge_method text not null,
  resource text,
  created_at text not null,
  expires_at text not null,
  consumed_at text
);

-- 访问令牌与刷新令牌：只存哈希
create table if not exists oauth_tokens (
  token_hash text primary key,
  kind text not null,
  client_id text not null,
  user_id text not null,
  scopes text not null,
  family_id text not null,
  created_at text not null,
  expires_at text not null,
  revoked_at text,
  replaced_by text
);

create index if not exists idx_oauth_tokens_family on oauth_tokens(family_id);
create index if not exists idx_oauth_tokens_user on oauth_tokens(user_id);

-- 已授权的连接：用于「跳过重复授权确认」与「撤销某个客户端的访问」
create table if not exists oauth_consents (
  client_id text not null,
  user_id text not null,
  scopes text not null,
  created_at text not null,
  last_used_at text not null,
  primary key (client_id, user_id)
);

-- 首次初始化凭证：只在还没有账号时存在
create table if not exists auth_setup (
  id text primary key,
  token_hash text not null,
  created_at text not null
);

-- 速率限制计数（登录、注册、令牌端点）
create table if not exists auth_rate_limits (
  bucket text primary key,
  count integer not null,
  window_started_at text not null
);
`;

export function openDatabase(file = ":memory:") {
  if (file !== ":memory:") {
    const directory = path.dirname(file);
    if (!fs.existsSync(directory)) {
      // 只在自己创建目录时收紧权限，不去动已经存在的目录
      fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
    }
  }
  const db = new DatabaseSync(file);
  db.exec("PRAGMA journal_mode = WAL;");
  db.exec("PRAGMA foreign_keys = ON;");
  db.exec(SCHEMA);
  db.exec(AUTH_SCHEMA);
  migrate(db);
  bootstrap(db);
  if (file !== ":memory:") restrictPermissions(file);
  return db;
}

/**
 * 数据库里存着账号口令哈希与令牌哈希，虽然都是哈希，也没必要让本机其他用户读到。
 * WAL 模式下会额外产生 -wal / -shm，一并收紧。
 */
function restrictPermissions(file) {
  for (const target of [file, `${file}-wal`, `${file}-shm`]) {
    try {
      if (fs.existsSync(target)) fs.chmodSync(target, 0o600);
    } catch {
      /* 可能不是文件所有者（例如由 systemd 以其他用户创建），跳过 */
    }
  }
}

/** 就地升级已有数据库，不动用户数据。 */
function migrate(db) {
  const columns = db.prepare("pragma table_info(threads)").all().map((row) => row.name);
  if (!columns.includes("revision")) {
    db.exec("alter table threads add column revision integer not null default 1");
  }
}

const DEFAULT_DOMAINS = [
  { name: "工作", color: "indigo", icon: "briefcase" },
  { name: "生活", color: "amber", icon: "house" },
  { name: "学习", color: "teal", icon: "book" },
];

/** 空库时建立默认 Domain，并为每个 Domain 建一条承担收集职责的 Inbox Thread。 */
export function bootstrap(db) {
  const { count } = db.prepare("select count(*) as count from domains").get();
  if (count > 0) return;
  const stamp = nowIso();
  const insertDomain = db.prepare(
    "insert into domains (id, name, color, icon, position, archived, created_at, updated_at) values (?,?,?,?,?,0,?,?)",
  );
  const insertThread = db.prepare(
    "insert into threads (id, domain_id, title, summary, status, is_inbox, position, created_at, updated_at) values (?,?,?,?,'active',?,?,?,?)",
  );
  DEFAULT_DOMAINS.forEach((domain, index) => {
    const domainId = newId("dm");
    insertDomain.run(domainId, domain.name, domain.color, domain.icon, index, stamp, stamp);
    insertThread.run(newId("th"), domainId, "收件箱", "先收下来，稍后整理归属。", 1, 0, stamp, stamp);
  });
}

export function withTransaction(db, fn) {
  db.exec("BEGIN");
  try {
    const result = fn();
    db.exec("COMMIT");
    return result;
  } catch (error) {
    try {
      db.exec("ROLLBACK");
    } catch {
      /* ignore rollback failure, original error is more useful */
    }
    throw error;
  }
}
