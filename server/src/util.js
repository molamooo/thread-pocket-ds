import { randomUUID } from "node:crypto";

export const THREAD_STATUSES = ["active", "waiting", "paused", "completed"];
export const ITEM_KINDS = ["task", "event", "direction", "wait"];
export const OPEN_ITEM_STATUSES = ["open"];
export const CLOSED_ITEM_STATUSES = ["done", "cancelled", "resolved", "abandoned", "converted"];

export function newId(prefix = "it") {
  return `${prefix}_${randomUUID().replaceAll("-", "").slice(0, 20)}`;
}

export function nowIso() {
  return new Date().toISOString();
}

/** 本地日期（非 UTC），格式 YYYY-MM-DD。 */
export function toDateKey(date = new Date()) {
  const y = date.getFullYear();
  const m = `${date.getMonth() + 1}`.padStart(2, "0");
  const d = `${date.getDate()}`.padStart(2, "0");
  return `${y}-${m}-${d}`;
}

export function addDays(dateKey, days) {
  const [y, m, d] = dateKey.split("-").map(Number);
  const base = new Date(y, m - 1, d);
  base.setDate(base.getDate() + days);
  return toDateKey(base);
}

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

export function isDateKey(value) {
  if (typeof value !== "string" || !DATE_RE.test(value)) return false;
  const [y, m, d] = value.split("-").map(Number);
  const probe = new Date(y, m - 1, d);
  return probe.getFullYear() === y && probe.getMonth() === m - 1 && probe.getDate() === d;
}

export function isDateTime(value) {
  if (typeof value !== "string" || value.length === 0) return false;
  const parsed = Date.parse(value);
  return Number.isFinite(parsed);
}

export class HttpError extends Error {
  constructor(status, message, code = "error", details = undefined, headers = undefined) {
    super(message);
    this.status = status;
    this.code = code;
    this.details = details;
    this.headers = headers;
  }
}

export function badRequest(message, details) {
  return new HttpError(400, message, "bad_request", details);
}

export function notFound(message = "资源不存在") {
  return new HttpError(404, message, "not_found");
}

export function conflict(message) {
  return new HttpError(409, message, "conflict");
}

export function requireString(value, field, { max = 4000, min = 1, allowEmpty = false } = {}) {
  if (value === undefined || value === null) throw badRequest(`缺少字段 ${field}`);
  if (typeof value !== "string") throw badRequest(`字段 ${field} 必须是字符串`);
  const trimmed = value.trim();
  if (!allowEmpty && trimmed.length < min) throw badRequest(`字段 ${field} 不能为空`);
  if (value.length > max) throw badRequest(`字段 ${field} 过长（上限 ${max} 字符）`);
  return trimmed;
}

export function optionalString(value, field, { max = 4000 } = {}) {
  if (value === undefined || value === null) return null;
  if (typeof value !== "string") throw badRequest(`字段 ${field} 必须是字符串`);
  if (value.length > max) throw badRequest(`字段 ${field} 过长（上限 ${max} 字符）`);
  return value;
}

export function optionalDateKey(value, field) {
  if (value === undefined || value === null || value === "") return null;
  if (!isDateKey(value)) throw badRequest(`字段 ${field} 需要是 YYYY-MM-DD 日期`);
  return value;
}

export function optionalDateTime(value, field) {
  if (value === undefined || value === null || value === "") return null;
  if (!isDateTime(value)) throw badRequest(`字段 ${field} 需要是 ISO 时间`);
  return new Date(value).toISOString();
}

export function optionalBool(value, field) {
  if (value === undefined || value === null) return null;
  if (typeof value === "boolean") return value;
  if (value === 0 || value === 1) return value === 1;
  throw badRequest(`字段 ${field} 需要是布尔值`);
}

export function pickEnum(value, field, allowed) {
  if (value === undefined || value === null) return null;
  if (!allowed.includes(value)) {
    throw badRequest(`字段 ${field} 需要是 ${allowed.join(" / ")} 之一`);
  }
  return value;
}

/** 把 sqlite 的 0/1 还原成布尔值。 */
export function bool(value) {
  return value === 1 || value === true;
}

export function parseJson(value, fallback = null) {
  if (value === null || value === undefined) return fallback;
  try {
    return JSON.parse(value);
  } catch {
    return fallback;
  }
}
