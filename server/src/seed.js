#!/usr/bin/env node
import path from "node:path";
import { fileURLToPath } from "node:url";
import { openDatabase } from "./db.js";
import { createRepository } from "./repo.js";
import { addDays, toDateKey } from "./util.js";

const HERE = path.dirname(fileURLToPath(import.meta.url));

function atTime(dateKey, hour, minute = 0) {
  const [y, m, d] = dateKey.split("-").map(Number);
  return new Date(y, m - 1, d, hour, minute, 0, 0).toISOString();
}

export function seed(db) {
  const repo = createRepository(db);
  const today = toDateKey();
  const domainByName = new Map(repo.listDomains({ includeArchived: true }).map((d) => [d.name, d]));

  function domain(name, color, icon) {
    if (!domainByName.has(name)) {
      const created = repo.createDomain({ name, color, icon });
      domainByName.set(name, created);
      return created;
    }
    return domainByName.get(name);
  }

  const reno = domain("装修", "rose", "hammer");
  const work = domain("工作", "indigo", "briefcase");
  const life = domain("生活", "amber", "house");
  const study = domain("学习", "teal", "book");

  function thread(domainRef, title, summary, status = "active", isInbox = false) {
    return repo.createThread({ domainId: domainRef.id, title, summary, status, isInbox });
  }

  /* ---------------------------------- 装修 ---------------------------------- */

  const kitchen = thread(
    reno,
    "厨房方案",
    "已确定采用方案 B；预算仍需确认，下一步先核对报价中的增项。",
  );
  repo.createItem(kitchen.id, {
    kind: "task",
    title: "核对报价中的增项",
    dueDate: addDays(today, 3),
    planDate: addDays(today, 1),
    detail: "重点看台面石材、五金和拆改费用。",
  });
  repo.createItem(kitchen.id, {
    kind: "event",
    title: "现场量房",
    startAt: atTime(addDays(today, 2), 10, 0),
    endAt: atTime(addDays(today, 2), 11, 30),
  });
  repo.createItem(kitchen.id, { kind: "direction", title: "探索开放式厨房的可行性" });
  repo.createItem(kitchen.id, { kind: "direction", title: "比较岩板与石英石的长期表现" });
  repo.createItem(kitchen.id, {
    kind: "wait",
    title: "等设计师提供修订图",
    followUpDate: addDays(today, 2),
    detail: "约定周二前给出第二版平面图。",
  });
  repo.saveNote(
    kitchen.id,
    [
      "# 随手记",
      "",
      "- 台面深度 600，通道至少要留 900",
      "- 参考：https://example.com/kitchen-layout",
      "- 还没想清楚：冰箱放左还是放右？如果靠左，餐边柜就要压缩 20cm",
    ].join("\n"),
  );
  repo.addProgressNote(kitchen.id, "本次讨论排除了方案 A，原因是通道宽度不足。");

  const construction = thread(reno, "施工进度", "水电改造已完成验收，下一步等瓦工进场。");
  repo.createItem(construction.id, { kind: "task", title: "确认瓦工进场时间", planDate: today });
  repo.createItem(construction.id, {
    kind: "task",
    title: "补齐隐蔽工程照片存档",
    dueDate: addDays(today, -2),
  });
  repo.createItem(construction.id, { kind: "task", title: "整理验收单据", planDate: addDays(today, -5) });
  repo.createItem(construction.id, {
    kind: "wait",
    title: "等物业审批施工许可",
    followUpDate: today,
  });
  repo.addProgressNote(construction.id, "水电验收通过，现场照片已导出到本地文件夹。");

  const furniture = thread(reno, "家具采购", "先定沙发和餐桌，其余等尺寸确定后再看。", "waiting");
  repo.createItem(furniture.id, { kind: "task", title: "预约家具城看沙发" });
  repo.createItem(furniture.id, { kind: "direction", title: "考虑二手实木餐桌" });
  repo.createItem(furniture.id, {
    kind: "event",
    title: "家具城到店",
    startAt: atTime(addDays(today, -1), 14, 0),
    endAt: atTime(addDays(today, -1), 16, 0),
  });

  /* ---------------------------------- 工作 ---------------------------------- */

  const q3 = thread(work, "Q3 项目复盘", "复盘材料已成型，待补齐数据口径说明。");
  repo.createItem(q3.id, { kind: "task", title: "补齐数据口径说明", dueDate: addDays(today, 1) });
  repo.createItem(q3.id, { kind: "task", title: "约复盘会时间", planDate: today });
  repo.createItem(q3.id, { kind: "direction", title: "是否把复盘节奏改成双周一次" });
  repo.addProgressNote(q3.id, "复盘大纲确认，删除重复的指标口径段落。");

  const hire = thread(work, "后端招聘", "已确认岗位画像，进入简历筛选。", "active");
  repo.createItem(hire.id, { kind: "task", title: "筛选 10 份简历", dueDate: addDays(today, 4) });
  repo.createItem(hire.id, { kind: "wait", title: "等 HR 同步渠道简历", followUpDate: addDays(today, 1) });

  /* ---------------------------------- 学习 ---------------------------------- */

  const swift = thread(study, "SwiftUI 动效研究", "已跑通 matchedGeometryEffect 的基础用法。");
  repo.createItem(swift.id, { kind: "task", title: "整理一份动效示例清单", planDate: addDays(today, 2) });
  repo.createItem(swift.id, { kind: "direction", title: "研究自定义转场与手势结合" });
  repo.saveNote(swift.id, "- spring 响应值 0.35 左右手感比较好\n- 注意动画期间禁止重复触发");

  const writing = thread(study, "技术写作计划", "先确定主题，再拆章节。", "paused");
  repo.createItem(writing.id, { kind: "direction", title: "候选主题：把复杂状态讲清楚" });

  /* ---------------------------------- 生活 ---------------------------------- */

  const health = thread(life, "体检与复查", "体检报告已出，两项指标需要复查。");
  repo.createItem(health.id, { kind: "task", title: "预约复查", dueDate: addDays(today, 5) });
  repo.createItem(health.id, { kind: "event", title: "口腔科复查", startAt: atTime(addDays(today, 6), 9, 0), endAt: atTime(addDays(today, 6), 9, 45) });

  const trip = thread(life, "十一出行安排", "目的地定了，还在等同伴确认时间。", "waiting");
  repo.createItem(trip.id, { kind: "task", title: "对比三家民宿", planDate: addDays(today, 3) });
  repo.createItem(trip.id, { kind: "wait", title: "等同伴确认请假时间", followUpDate: addDays(today, 4) });

  /* --------------------------------- 收件箱 --------------------------------- */

  const inbox = repo.listThreads({ include: "active", domainId: reno.id }).find((t) => t.is_inbox);
  if (inbox) {
    repo.createItem(inbox.id, { kind: "task", title: "买厨房密封胶" });
    repo.createItem(inbox.id, { kind: "direction", title: "了解全屋净水方案" });
    repo.createItem(inbox.id, { kind: "wait", title: "等商家补发五金清单", followUpDate: addDays(today, 2) });
  }
  const workInbox = repo.listThreads({ include: "active", domainId: work.id }).find((t) => t.is_inbox);
  if (workInbox) {
    repo.createItem(workInbox.id, { kind: "task", title: "回复供应商邮件", dueDate: addDays(today, 2) });
  }

  /* -------------------------------- 其他状态 -------------------------------- */

  const done = thread(reno, "旧家具处理", "已经处理完，留作回顾。", "completed");
  const doneItem = repo.createItem(done.id, { kind: "task", title: "把旧沙发挂到二手平台" });
  repo.updateItem(doneItem.id, { status: "done" });
  repo.addProgressNote(done.id, "旧沙发已出售，书桌送给了邻居。");

  return repo;
}

const isMain = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);

if (isMain) {
  const dbFile = process.env.THREADPOCKET_DB ?? path.resolve(HERE, "..", "data", "thread-pocket.sqlite");
  const reset = process.argv.includes("--reset");
  const db = openDatabase(dbFile);
  if (reset) {
    db.exec("delete from log_entries; delete from notes; delete from items; delete from threads; delete from domains;");
    db.exec(
      `insert into domains (id,name,color,icon,position,archived,created_at,updated_at) values
       ('dm_seed_work','工作','indigo','briefcase',0,0,'2026-01-01T00:00:00.000Z','2026-01-01T00:00:00.000Z'),
       ('dm_seed_life','生活','amber','house',1,0,'2026-01-01T00:00:00.000Z','2026-01-01T00:00:00.000Z'),
       ('dm_seed_study','学习','teal','book',2,0,'2026-01-01T00:00:00.000Z','2026-01-01T00:00:00.000Z');`,
    );
    db.exec(
      `insert into threads (id,domain_id,title,summary,status,is_inbox,position,created_at,updated_at) values
       ('th_seed_work_inbox','dm_seed_work','收件箱','先收下来，稍后整理归属。','active',1,0,'2026-01-01T00:00:00.000Z','2026-01-01T00:00:00.000Z'),
       ('th_seed_life_inbox','dm_seed_life','收件箱','先收下来，稍后整理归属。','active',1,0,'2026-01-01T00:00:00.000Z','2026-01-01T00:00:00.000Z'),
       ('th_seed_study_inbox','dm_seed_study','收件箱','先收下来，稍后整理归属。','active',1,0,'2026-01-01T00:00:00.000Z','2026-01-01T00:00:00.000Z');`,
    );
  }
  const { count } = db.prepare("select count(*) as count from threads").get();
  const existingNonInbox = db.prepare("select count(*) as count from threads where is_inbox = 0").get().count;
  if (existingNonInbox > 0) {
    console.log(`[seed] 已有 ${count} 条 Thread，跳过初始化。使用 --reset 可重建演示数据。`);
  } else {
    seed(db);
    const stats = db.prepare("select count(*) as t from threads").get();
    const items = db.prepare("select count(*) as c from items").get();
    console.log(`[seed] 完成：${stats.t} 条 Thread，${items.c} 条事项。`);
  }
  db.close();
}
