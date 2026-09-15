# Thread Pocket 后端

零依赖的 REST 服务：Node 内置 HTTP + 内置 SQLite（`node:sqlite`）。没有 `node_modules`，
复制目录即可运行，数据就是一个 SQLite 文件。

## 运行

```bash
npm start          # 默认 http://127.0.0.1:8787
npm run dev        # --watch 模式
npm run seed       # 写入演示数据
npm run reset      # 清空并重建演示数据
npm run setup:link # 打印/打开首次初始化账号的链接（对外部署时用）
npm test           # 79 个接口 / OAuth / MCP 测试
```

环境变量：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `PORT` | `8787` | 监听端口 |
| `HOST` | `127.0.0.1` | 监听地址，容器中通常设为 `0.0.0.0` |
| `THREADPOCKET_DB` | `server/data/thread-pocket.sqlite` | 数据库文件 |
| `THREADPOCKET_API_KEY` | 空 | 设置后，除 `/health` 与 `/api/v1/meta` 外都需要 Bearer 令牌 |
| `THREADPOCKET_PUBLIC_URL` | 空 | 对外 origin（如 `https://pocket.example.com`）；设置后所有请求都要凭证 |
| `THREADPOCKET_TRUST_LOOPBACK` | `0` | 设为 `1` 时本机请求可免登录（纯本机开发） |
| `THREADPOCKET_CIMD_HOSTS` | `chatgpt.com,claude.ai,claude.com` | 允许读取客户端元数据文档的主机 |

`GET /` 提供内置 Web 控制台（读取同一份数据，并支持快速收集）。

绑定到非回环地址、又没有任何鉴权时服务会**拒绝启动**；
确需临时试探可设 `THREADPOCKET_ALLOW_INSECURE=1`。设计说明见仓库根目录的 [AUTH.md](../AUTH.md)。

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
| PATCH | `/api/v1/threads/:id` | 改标题 / 当前描述 / 状态 / 归属 / 置顶(`pinned`) / 归档 / 回收 |
| POST | `/api/v1/threads/reorder` | 人工排序：`ids` 按期望顺序排列，放回它们原先占据的位置槽 |
| DELETE | `/api/v1/threads/:id?hard=1` | 默认软删除（回收站），`hard=1` 彻底删除 |

`PATCH` 会按实际变化追加日志：`thread.summary` 记录描述的前后值，`thread.status` 记录状态迁移，
归档 / 回收 / 恢复也各自留下记录。

列表顺序由人安排：置顶的一组排在最前，其余按 `position` 升序，新线索插在最前。
顺序与「最近更新」无关，改标题、写日志都不会把线索挪到别处。

### Item

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/v1/items?thread_id=&kind=&status=open,done` | 跨 Thread 查询 |
| POST | `/api/v1/threads/:id/items` | 新增事项 |
| PATCH | `/api/v1/items/:id` | 改标题 / 时间 / 状态 / 受阻标记；改 `thread_id` 等于移动 |
| POST | `/api/v1/items/:id/move` | 移动到另一个 Thread，返回源与目标的完整上下文 |
| POST | `/api/v1/items/:id/convert` | 探索方向 → 待办（方向标记为 `converted`，待办记录 `source_id`） |
| POST | `/api/v1/items/reorder` | 同一 Thread 内的人工排序（`thread_id` + `ids`） |
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

## MCP

`POST /mcp` 上是自己实现的 MCP（Streamable HTTP，无状态，不依赖任何 MCP SDK）。
它在 `initialize` 的 `instructions` 里返回**完整的工具使用说明**（即原先独立分发的 Skill 内容），
因此接入方不需要再安装 Skill 包。

| 工具 | 用途 |
| --- | --- |
| `list_domains` | 列出关注范围与各自的收件箱 |
| `list_threads` | 按关键词 / Domain / 状态分页查找线索 |
| `resolve_thread` | 把用户口述的主题解析成确切的 Thread（同名线索 → 同名 Domain 的收件箱 → 按需新建） |
| `get_thread` | 读取当前描述、未结束与已结束条目、笔记、最近日志，并返回 `revision` |
| `create_thread` | 新建线索 |
| `update_thread` | 更新标题 / 当前描述 / 状态 / 归属 / 归档 |
| `upsert_entries` | 批量写入 1–200 条条目，单事务，支持 `expected_revision` 乐观并发 |
| `update_entry` / `delete_entry` / `move_entry` | 单条更新、删除、跨线索移动 |
| `append_log` | 记录已经发生的结果与判断，可带 `occurred_at` |
| `write_note` | 覆盖这条线索的唯一一份自由笔记 |
| `list_overview` | 今天 / 行动 / 收件箱三个视图 |
| `search` | 跨线索搜索 |

并发控制：每条 Thread 有 `revision`，任何写入都会 +1。Agent 先 `get_thread` 拿到 revision，
再带着它写入；版本不一致返回 `409 revision_conflict`，并提示先重新读取再合并。

### MCP 鉴权

`/mcp` 需要 `mcp:tools`。未授权时返回：

```
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer realm="thread-pocket",
  resource_metadata="https://<origin>/.well-known/oauth-protected-resource/mcp",
  scope="mcp:tools"
```

客户端据此完成发现、注册与授权（支持动态注册与客户端元数据文档两种方式）。

## OAuth 端点

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/.well-known/oauth-authorization-server` | 授权服务器元信息（RFC 8414） |
| GET | `/.well-known/oauth-protected-resource[/mcp\|/api]` | 资源元信息（RFC 9728） |
| POST | `/oauth/register` | 动态客户端注册（仅公共客户端） |
| GET/POST | `/oauth/authorize` | 授权码 + PKCE(S256)，POST 为同意/拒绝 |
| POST | `/oauth/token` | `authorization_code` / `refresh_token`（刷新即轮换） |
| POST | `/oauth/revoke` | 撤销令牌 |
| POST | `/oauth/introspect` | 自省（仅本机或静态密钥） |
| GET/POST | `/auth/login` `/auth/setup` `/auth/connections` | 登录、初始化、管理已授权客户端 |

scope：`threads:read`、`threads:write`、`mcp:tools`、`offline_access`。
缺少权限返回 `403 insufficient_scope` 并在挑战里指出缺哪个 scope。

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
