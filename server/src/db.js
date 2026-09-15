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

export function openDatabase(file = ":memory:") {
  if (file !== ":memory:") {
    fs.mkdirSync(path.dirname(file), { recursive: true });
  }
  const db = new DatabaseSync(file);
  db.exec("PRAGMA journal_mode = WAL;");
  db.exec("PRAGMA foreign_keys = ON;");
  db.exec(SCHEMA);
  bootstrap(db);
  return db;
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
