import { addDays, toDateKey } from "./util.js";

const DAY_MS = 24 * 60 * 60 * 1000;

function dayKeyOf(iso) {
  if (!iso) return null;
  if (/^\d{4}-\d{2}-\d{2}$/.test(iso)) return iso;
  return toDateKey(new Date(iso));
}

function startOfDayIso(dateKey) {
  const [y, m, d] = dateKey.split("-").map(Number);
  return new Date(y, m - 1, d, 0, 0, 0, 0).toISOString();
}

function endOfDayIso(dateKey) {
  return new Date(Date.parse(startOfDayIso(dateKey)) + DAY_MS - 1).toISOString();
}

function isAction(item) {
  return item.kind === "task" || item.kind === "event";
}

function eventDayKeys(item) {
  const start = dayKeyOf(item.start_at) ?? item.plan_date;
  const end = dayKeyOf(item.end_at) ?? start ?? item.due_date;
  return { start, end };
}

export function createViews(repo) {
  function context({ domainId = null, includeArchived = false, today = toDateKey() } = {}) {
    const threads = repo
      .listThreads({ include: includeArchived ? "all" : "active", domainId })
      .filter((thread) => !thread.trashed_at);
    const byId = new Map(threads.map((thread) => [thread.id, thread]));
    const items = repo.listItems({ statuses: ["open"] }).filter((item) => byId.has(item.thread_id));
    const domainById = new Map(repo.listDomains({ includeArchived: true }).map((domain) => [domain.id, domain]));
    return { threads, byId, items, domainById, today };
  }

  function entry(item, threads) {
    const thread = threads.get(item.thread_id);
    return {
      item,
      thread: thread ? { id: thread.id, title: thread.title, domain_id: thread.domain_id, status: thread.status, is_inbox: thread.is_inbox } : null,
    };
  }

  function group(key, title, entries) {
    return { key, title, count: entries.length, entries };
  }

  /** 今天入口：今天安排与到期、已逾期、待重新安排、需要确认结果的过往日程。 */
  function todayView({ domainId = null, includeWaits = false, includePastEvents = true } = {}) {
    const ctx = context({ domainId });
    const { today, byId, items, domainById } = ctx;
    const buckets = { overdue: [], today: [], reschedule: [], past_events: [], follow_ups: [] };
    const nowIso = new Date().toISOString();

    for (const item of items) {
      if (isAction(item)) {
        if (item.kind === "task") {
          if (item.due_date && item.due_date < today) {
            buckets.overdue.push(entry(item, byId));
            continue;
          }
          if (item.plan_date === today || item.due_date === today) {
            buckets.today.push(entry(item, byId));
            continue;
          }
          if (item.plan_date && item.plan_date < today) {
            buckets.reschedule.push(entry(item, byId));
            continue;
          }
        } else if (item.kind === "event") {
          const { start, end } = eventDayKeys(item);
          if (!start) continue;
          const endIso = item.end_at ? new Date(item.end_at).toISOString() : endOfDayIso(end);
          const startIso = item.start_at ? new Date(item.start_at).toISOString() : startOfDayIso(start);
          const happening = startIso <= nowIso && endIso >= nowIso;
          if (happening) {
            buckets.today.push(entry(item, byId));
            continue;
          }
          const coversToday = start <= today && end >= today;
          if (coversToday) {
            buckets.today.push(entry(item, byId));
            continue;
          }
          if (includePastEvents && endIso < nowIso) {
            buckets.past_events.push(entry(item, byId));
          }
        }
      } else if (item.kind === "wait" && includeWaits) {
        if (item.follow_up_date && item.follow_up_date <= today) {
          buckets.follow_ups.push(entry(item, byId));
        }
      }
    }

    const sortByDate = (a, b) => {
      const keyA = a.item.due_date ?? a.item.plan_date ?? a.item.start_at ?? "";
      const keyB = b.item.due_date ?? b.item.plan_date ?? b.item.start_at ?? "";
      return String(keyA).localeCompare(String(keyB));
    };
    for (const key of Object.keys(buckets)) buckets[key].sort(sortByDate);

    const groups = [
      group("today", "今天", buckets.today),
      group("overdue", "已逾期", buckets.overdue),
      group("to_reschedule", "待重新安排", buckets.reschedule),
      group("past_events", "已过时间的日程", buckets.past_events),
    ];
    if (includeWaits) groups.push(group("follow_ups", "需要跟进的等待", buckets.follow_ups));
    return {
      today,
      domain_id: domainId,
      groups: groups.filter((g) => g.count > 0),
      totals: groups.reduce((acc, g) => ({ ...acc, [g.key]: g.count }), {}),
      domains: domainById,
    };
  }

  /** 行动入口：未结束的待办与固定日程，按 Thread 分组。 */
  function actionsView({ domainId = null, dates = "all", range = "any" } = {}) {
    const ctx = context({ domainId });
    const { today, byId, items } = ctx;
    const horizonEnd = addDays(today, 6);

    const matchesDates = (item) => {
      const hasDate = Boolean(item.plan_date || item.due_date || item.start_at);
      if (dates === "with" && !hasDate) return false;
      if (dates === "without" && (hasDate || item.kind === "event")) return false;
      if (range === "upcoming7") {
        const candidates = [item.plan_date, item.due_date, dayKeyOf(item.start_at)].filter(Boolean);
        if (candidates.length === 0) return false;
        return candidates.some((key) => key >= today && key <= horizonEnd);
      }
      return true;
    };

    const grouped = new Map();
    for (const item of items) {
      if (!isAction(item)) continue;
      if (!matchesDates(item)) continue;
      if (!grouped.has(item.thread_id)) grouped.set(item.thread_id, []);
      grouped.get(item.thread_id).push(item);
    }
    const groups = [...grouped.entries()]
      .map(([threadId, list]) => {
        const thread = byId.get(threadId);
        return {
          thread: { id: thread.id, title: thread.title, domain_id: thread.domain_id, is_inbox: thread.is_inbox, status: thread.status },
          items: list.sort((a, b) => {
            const keyA = a.plan_date ?? a.due_date ?? dayKeyOf(a.start_at) ?? "9999";
            const keyB = b.plan_date ?? b.due_date ?? dayKeyOf(b.start_at) ?? "9999";
            return String(keyA).localeCompare(String(keyB));
          }),
        };
      })
      .sort((a, b) => {
        if (a.thread.is_inbox !== b.thread.is_inbox) return a.thread.is_inbox ? 1 : -1;
        return a.thread.title.localeCompare(b.thread.title, "zh-Hans");
      });

    return {
      today,
      horizon_end: horizonEnd,
      domain_id: domainId,
      dates,
      range,
      groups,
      total: groups.reduce((sum, g) => sum + g.items.length, 0),
    };
  }

  /** 收件箱入口：聚合各 Domain 收集箱里的未结束事项。 */
  function inboxView({ domainId = null } = {}) {
    const ctx = context({ domainId });
    const { byId, items, domainById } = ctx;
    const grouped = new Map();
    for (const item of items) {
      const thread = byId.get(item.thread_id);
      if (!thread?.is_inbox) continue;
      if (!grouped.has(item.thread_id)) grouped.set(item.thread_id, []);
      grouped.get(item.thread_id).push(item);
    }
    const groups = [...grouped.entries()].map(([threadId, list]) => {
      const thread = byId.get(threadId);
      return {
        thread: { id: thread.id, title: thread.title, domain_id: thread.domain_id, is_inbox: true },
        domain: domainById.get(thread.domain_id) ?? null,
        items: list,
      };
    });
    return { domain_id: domainId, groups, total: groups.reduce((sum, g) => sum + g.items.length, 0) };
  }

  /** Thread 视图的时间筛选（全部 / 今天 / 近期 / 等待）。 */
  function threadScope(threadId, scope = "all") {
    const bundle = repo.threadBundle(threadId);
    const today = toDateKey();
    const horizonEnd = addDays(today, 6);
    const match = (item) => {
      if (scope === "today") {
        if (item.kind === "task") {
          return item.plan_date === today || item.due_date === today || (item.due_date && item.due_date < today) || (item.plan_date && item.plan_date < today);
        }
        if (item.kind === "event") {
          const { start, end } = eventDayKeys(item);
          return Boolean(start && end && start <= today && end >= today);
        }
        if (item.kind === "wait") return Boolean(item.follow_up_date && item.follow_up_date <= today);
        return false;
      }
      if (scope === "upcoming") {
        const candidates = [item.plan_date, item.due_date, dayKeyOf(item.start_at), item.follow_up_date].filter(Boolean);
        return candidates.some((key) => key >= today && key <= horizonEnd);
      }
      if (scope === "waiting") return item.kind === "wait" || item.blocked;
      return true;
    };
    return {
      thread: bundle.thread,
      scope,
      items: bundle.items.open.filter(match),
    };
  }

  return { todayView, actionsView, inboxView, threadScope };
}
