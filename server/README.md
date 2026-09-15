# Thread Pocket 后端

零依赖的 REST 服务：Node 内置 HTTP + 内置 SQLite（`node:sqlite`）。没有 `node_modules`，
复制目录即可运行，数据就是一个 SQLite 文件。

## 运行

```bash
npm start          # 默认 http://127.0.0.1:8787
npm run dev        # --watch 模式
npm run seed       # 写入演示数据
npm run reset      # 清空并重建演示数据
npm test           # 27 个接口 / 视图 / 鉴权测试
```

环境变量：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `PORT` | `8787` | 监听端口 |
| `HOST` | `127.0.0.1` | 监听地址，容器中通常设为 `0.0.0.0` |
| `THREADPOCKET_DB` | `server/data/thread-pocket.sqlite` | 数据库文件 |
| `THREADPOCKET_API_KEY` | 空 | 设置后，除 `/health` 与 `/api/v1/meta` 外都需要 Bearer 令牌 |

`GET /` 提供内置 Web 控制台（读取同一份数据，并支持快速收集）。

## 数据模型

```
Domain ──< Thread ──< Item
                │      kind: task | event | direction | wait
                │      status: open | done | cancelled | resolved | abandoned | converted
                ├──< Note   每个 Thread 一份自由笔记
                └──< LogEntry  kind: progress | operation
```

- **Thread**：可独立接续的一件事。`is_inbox = true` 表示它是该 Domain 的收集箱。
  `archived_at` 表示归档，`trashed_at` 表示回收站，两者互相独立于 `status`。
- **Item**：四类事项共表，用 `kind` 区分。「探索方向」可以转成待办（保留 `source_id`），
  「受阻的行动」是 `blocked = true` 的待办。
- **LogEntry**：`progress` 是用户写下的进展，`operation` 由服务端在增删改时自动追加，
  并且尽量带上 `meta`（例如当前描述的变化前后、改期的原值与新值）。

时间字段都使用字符串：日期为 `YYYY-MM-DD`，时刻为 ISO 8601（带时区偏移）。

## API

所有路径以 `/api/v1` 开头，请求与响应都是 JSON，字段使用 `snake_case`。

### 元信息

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/health` | 存活检查（不需要令牌） |
| GET | `/api/v1/meta` | 版本、能力列表、可用枚举（不需要令牌） |
| GET | `/api/v1/snapshot` | 一次取回 domains / threads / items / notes / logs，供客户端首屏使用 |

### Domain

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/v1/domains?include_archived=1` | 列出领域 |
| POST | `/api/v1/domains` | 新建领域，并自动创建该领域的收集箱 |
| PATCH | `/api/v1/domains/:id` | 改名 / 换色 / 排序 / 归档 |
| DELETE | `/api/v1/domains/:id` | 删除领域（级联删除其下线索） |

### Thread

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/v1/threads?domain_id=&include=active\|archived\|trashed\|all&status=&q=` | 列表，带未结束事项计数 |
| POST | `/api/v1/threads` | 新建（`domain_id`, `title`, `summary`, `is_inbox`） |
| GET | `/api/v1/threads/:id` | 上下文：thread + items(open/closed) + note + logs |
| GET | `/api/v1/threads/:id/scope?scope=all\|today\|upcoming\|waiting` | 按时间范围取该 Thread 的事项 |
| PATCH | `/api/v1/threads/:id` | 改标题 / 当前描述 / 状态 / 归属 / 归档 / 回收 |
| DELETE | `/api/v1/threads/:id?hard=1` | 默认软删除（回收站），`hard=1` 彻底删除 |

`PATCH` 会按实际变化追加日志：`thread.summary` 记录描述的前后值，`thread.status` 记录状态迁移，
归档 / 回收 / 恢复也各自留下记录。

### Item

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/v1/items?thread_id=&kind=&status=open,done` | 跨 Thread 查询 |
| POST | `/api/v1/threads/:id/items` | 新增事项 |
| PATCH | `/api/v1/items/:id` | 改标题 / 时间 / 状态 / 受阻标记；改 `thread_id` 等于移动 |
| POST | `/api/v1/items/:id/move` | 移动到另一个 Thread，返回源与目标的完整上下文 |
| POST | `/api/v1/items/:id/convert` | 探索方向 → 待办（方向标记为 `converted`，待办记录 `source_id`） |
| DELETE | `/api/v1/items/:id` | 删除事项 |

新增事项的请求体示例：

```json
{ "kind": "task", "title": "核对报价中的增项", "plan_date": "2026-09-16", "due_date": "2026-09-18" }
```

四种 `kind` 各自可用的时间字段：

| kind | 可用字段 |
| --- | --- |
| `task` | `plan_date`（计划日）、`due_date`（截止日）、`blocked` + `blocker_reason` |
| `event` | `start_at`、`end_at`（ISO 时刻，支持跨天） |
| `wait` | `follow_up_date`（跟进日） |
| `direction` | 无时间字段 |

### 笔记与日志

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET / PUT | `/api/v1/threads/:id/note` | 读取 / 覆写这一份自由笔记 |
| GET | `/api/v1/threads/:id/logs?limit=200` | 日志（时间倒序） |
| POST | `/api/v1/threads/:id/logs` | 记录一条进展（`kind` 默认 `progress`） |
| DELETE | `/api/v1/logs/:id` | 删除一条日志 |

### 视图

视图把「今天该看什么」这类产品逻辑放在服务端，方便多个客户端共享。

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/v1/views/today?domain_id=&include_waits=1&include_past_events=0` | 分组：`today` / `overdue` / `to_reschedule` / `past_events`（可选 `follow_ups`） |
| GET | `/api/v1/views/actions?domain_id=&dates=all\|with\|without&range=any\|upcoming7` | 未结束的待办与日程，按 Thread 分组 |
| GET | `/api/v1/views/inbox?domain_id=` | 聚合各收集箱中的未结束事项 |
| GET | `/api/v1/overview?domain_id=` | 一次返回上面三个视图 |
| GET | `/api/v1/search?q=` | 搜索线索与事项 |

分组规则（与 DESIGN.md 5.2 一致）：

- 同一事项只出现一次，优先级为 **已逾期 → 今天安排与到期 → 待重新安排**。
- 固定日程按「进行中 / 今天覆盖 / 已过时间」划分；已过时间不等于已完成。
- 「无时间」只包含既没有计划日也没有截止日的待办；探索方向与等待不进入行动清单。
- 等待默认不进入今天视图，`include_waits=1` 时才附上需要跟进的等待。

## 测试

```bash
npm test
```

覆盖：健康检查与元信息、Domain/Thread 生命周期、四类事项的创建与状态流转、
日志与笔记、三个视图的分组与去重、收件箱聚合、搜索、鉴权、持久化。

## 部署示例

```ini
# /etc/systemd/system/thread-pocket.service
[Unit]
Description=Thread Pocket API
After=network.target

[Service]
WorkingDirectory=/opt/thread-pocket/server
Environment=PORT=8787
Environment=HOST=0.0.0.0
Environment=THREADPOCKET_DB=/var/lib/thread-pocket/data.sqlite
Environment=THREADPOCKET_API_KEY=change-me
ExecStart=/usr/bin/node src/index.js
Restart=always

[Install]
WantedBy=multi-user.target
```

备份就是复制 `THREADPOCKET_DB` 指向的文件（写入过程中建议同时复制 `-wal` 文件，
或先执行一次 `sqlite3 data.sqlite ".backup backup.sqlite"`）。
