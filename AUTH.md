# 鉴权与对外暴露设计

Thread Pocket 可能只跑在自己电脑上，也可能挂到公网给手机、家里的另一台机器，
或者给 MCP 客户端（Claude、ChatGPT 这类）调用。这份文档说明这套鉴权是怎么设计的、
为什么这么设计，以及对外部署时要检查什么。

## 1. 要解决的问题

| 场景 | 需求 |
| --- | --- |
| 本机开发 | 不要被登录流程挡住；起来就能用 |
| 挂到公网 | 任何网络请求都必须能被验证身份；不能出现"忘了配就裸奔"的情况 |
| 桌面端 | 用浏览器完成一次登录，之后长期免打扰；令牌过期自动续期 |
| MCP 客户端 | 能自动发现授权服务器、自动注册、走标准 OAuth；不需要用户手工复制令牌 |
| 脚本 / 自动化 | 保留一条不依赖浏览器的路径（静态密钥） |

同时要避免两类典型事故：**把没有鉴权的个人数据暴露到公网**，以及**撤销/过期后旧令牌仍然能用**。

## 2. 角色与资源

```
        ┌──────────────────────────── Thread Pocket 服务 ────────────────────────────┐
        │                                                                            │
 浏览器 │  /auth/*       登录、初始化、已授权客户端管理                                 │
        │  /oauth/*      授权服务器：注册、授权、令牌、撤销、introspect                  │
        │  /.well-known/*  OAuth 授权服务器元信息 + 资源元信息                          │
        │                                                                            │
        │  /api/v1/*     REST 资源  ← macOS 应用、Web 控制台、脚本                      │
        │  /mcp          MCP 资源   ← Agent 客户端                                     │
        └────────────────────────────────────────────────────────────────────────────┘
```

服务同时是**授权服务器**（AS）和**资源服务器**（RS）。两者同源部署带来两个好处：
发现流程不需要额外配置；token 校验就是一次同库查询，没有网络往返。

## 3. 授权服务器

自实现，无第三方依赖（`server/src/auth/`）。遵循 MCP 授权规范与 OAuth 2.1 的公共客户端实践。

| 端点 | 作用 |
| --- | --- |
| `GET /.well-known/oauth-authorization-server` | RFC 8414 元信息：各端点、支持的 scope、`S256` |
| `GET /.well-known/oauth-protected-resource[/mcp\|/api]` | RFC 9728 资源元信息：`resource`、`authorization_servers`、可用 scope |
| `POST /oauth/register` | RFC 7591 动态客户端注册（仅公共客户端） |
| `GET /oauth/authorize` | 授权码 + PKCE（S256 强制） |
| `POST /oauth/token` | `authorization_code` 与 `refresh_token` |
| `POST /oauth/revoke` | RFC 7009 撤销 |
| `POST /oauth/introspect` | RFC 7662 自省（仅本机或静态密钥） |
| `GET /auth/login` `POST /auth/login` | 账号登录（scrypt 口令哈希 + 服务端会话） |
| `GET/POST /auth/setup` | 首次初始化账号 |
| `GET /auth/connections` | 查看与撤销已授权的客户端 |

### 客户端注册的三条路径

1. **动态注册（DCR）**：客户端自己调用 `/oauth/register`，拿到 `client_id`。
   这是默认路径，也是 MCP 客户端最常用的方式。
2. **客户端元数据文档（CIMD）**：`client_id` 本身是一个 HTTPS 文档地址，
   服务端读取后即时登记。因为这是"服务端去访问一个 URL"，默认只信任
   `THREADPOCKET_CIMD_HOSTS` 列出的主机（默认 `chatgpt.com`、`claude.ai`、`claude.com`），
   读取时禁用跳转、限制 64 KiB、8 秒超时，避免被当成 SSRF 跳板。
3. **预注册**：直接在数据库里写一条 `source='static'` 的客户端记录（`oauth_clients` 表），
   适合无法动态注册的老客户端。

### 为什么强制 PKCE

客户端都是公共客户端（桌面应用、CLI、Agent 运行时），没有可靠保存 `client_secret` 的地方。
`code_challenge_method=none`、`plain` 一律拒绝，只接受 `S256`；授权码 120 秒过期、一次性消费。

### 令牌

- 访问令牌与刷新令牌都是随机串，数据库里**只存 SHA-256 哈希**，泄露文件也无法直接使用。
- 访问令牌默认 1 小时，刷新令牌默认 30 天。
- 刷新即轮换：每次刷新签发新的刷新令牌并撤销旧的。
- **重放检测**：如果一个已被替换/撤销的刷新令牌再次出现，整个令牌族（同一 family）立即作废，
  必须重新授权。这使得令牌泄露的时间窗被压缩到一次刷新。

### 会话与初始化

- 登录会话使用 `HttpOnly` + `SameSite=Lax` 的 Cookie；HTTPS 部署时使用 `__Host-` 前缀 + `Secure`。
- 会话 Cookie 只用于**同源**浏览器访问（`/` 控制台、`/auth/connections`），
  并且服务端会校验 `Origin`，避免被跨站请求借用。
- 登录、注册、令牌、初始化端点都有按 IP 的固定窗口限流。

#### 初始化链接为什么把凭证放在 `#` 之后

一次性初始化链接长这样：

```
https://pocket.example.com/auth/setup#token=tp_setup_xxx
```

凭证放在 URL 的 **fragment** 里，而不是查询串：浏览器不会把 fragment 发给服务器，
因此它不会出现在反向代理 / CDN 的访问日志、也不进 `Referer`。

代价是服务端渲染这个页面时读不到凭证。所以流程拆成两步：

1. `GET /auth/setup` 只渲染表单（不含任何数据，允许无凭证访问），
   页面上一小段脚本读取 `location.hash`，把凭证填进隐藏字段，并把地址栏里的 fragment 清掉；
2. `POST /auth/setup` 才是真正的校验点：非本机部署必须带正确的一次性凭证，
   否则 403。凭证比较用常数时间，且受按 IP 限流保护。

也支持 `?token=` 形式（用 curl 或脚本初始化时方便），但这会把凭证写进访问日志，
所以脚本化请优先用表单提交。

## 4. 权限范围

| scope | 含义 | 典型客户端 |
| --- | --- | --- |
| `threads:read` | 读取 Domain / Thread / 事项 / 笔记 / 日志 | 只读面板、看板 |
| `threads:write` | 新增与修改上述内容 | macOS 应用、Web 控制台 |
| `mcp:tools` | 通过 MCP 工具读写 | Claude、ChatGPT 等 Agent |
| `offline_access` | 允许刷新，签发刷新令牌 | 需要长期运行的所有客户端 |

读接口要求 `threads:read`，写接口要求 `threads:write`；`/mcp` 要求 `mcp:tools`。
`mcp:tools` **不**自动等于完整的 REST 权限——Agent 的工具调用在服务端进程内完成，
不需要额外的 REST 权限，这样即使 Agent 的令牌泄露，影响面也限于 MCP 工具本身。

缺少权限时返回 `403 insufficient_scope`，并在 `WWW-Authenticate` 里指出缺哪个 scope。

## 5. 请求鉴权顺序

`server/src/auth/guard.js` 中，一次请求按下面的顺序判定：

1. 完全没有配置鉴权（没有账号、没有静态密钥、也没有对外暴露）→ 放行。这是本机起步状态。
2. 带了 Bearer 令牌 → 校验静态密钥或访问令牌。**无效就直接 401，不会回落到下面的规则。**
3. 带了会话 Cookie → 校验会话，并且要求同源。
4. 没有任何凭证，且显式开启了 `THREADPOCKET_TRUST_LOOPBACK` → 放行本机请求。
5. 其余 → `401`，带上 `resource_metadata` 挑战。

第 2 步的顺序是刻意的。早期版本把"信任本机"放在最前面，结果是：
在服务端撤销了某个客户端的令牌，本机上的应用仍然畅通无阻，撤销形同虚设。

### 默认值

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `THREADPOCKET_PUBLIC_URL` | 空 | 对外 origin，例如 `https://pocket.example.com`。设置后强制 HTTPS（本机可用 http） |
| `THREADPOCKET_TRUST_LOOPBACK` | `0` | 显式设为 `1` 时，本机请求可免登录（纯本机开发用） |
| `THREADPOCKET_API_KEY` | 空 | 静态密钥，给予全部权限，给脚本用 |
| `THREADPOCKET_ALLOW_INSECURE` | `0` | 允许在对外地址上无鉴权启动（不推荐） |
| `THREADPOCKET_CIMD_HOSTS` | `chatgpt.com,claude.ai,claude.com` | 允许读取客户端元数据文档的主机 |
| `THREADPOCKET_SETUP_TOKEN` | 随机 | 固定初始化凭证（默认随机生成并打印） |

另外两条防呆：

- 绑定到非回环地址、又没有账号也没有静态密钥时，**服务拒绝启动**并给出三种修复方式。
- 配置了公网 origin 时，`THREADPOCKET_TRUST_LOOPBACK` 会被强制关闭，
  避免"反向代理在本机"导致的绕过。

## 6. 桌面端怎么配合

桌面端复用同一套授权服务器，走 RFC 8252 推荐的原生应用流程：

```
应用启动登录
  ├─ GET /.well-known/oauth-protected-resource      发现授权服务器
  ├─ GET /.well-known/oauth-authorization-server    拿到端点与支持的 scope
  ├─ POST /oauth/register（一次，结果缓存）          注册 http://127.0.0.1/callback
  ├─ 启动 127.0.0.1:<随机端口> 本地回调服务器
  ├─ 打开系统浏览器 → /oauth/authorize?…&code_challenge=…
  │     用户在浏览器里登录并确认授权
  ├─ 浏览器跳回 http://127.0.0.1:<端口>/callback?code=…&state=…
  ├─ POST /oauth/token（code + code_verifier）      换到访问令牌与刷新令牌
  └─ 令牌写入钥匙串（钥匙串不可用时退回 0600 本地文件）
```

几个实现细节：

- 回调地址注册成 `http://127.0.0.1/callback`（不带端口）。服务端对回环地址忽略端口差异，
  所以随机端口每次都匹配得上，应用不需要反复注册。
- 桌面端申请的 scope 是 `threads:read threads:write offline_access`，**不申请 `mcp:tools`**。
- 请求前若令牌在 90 秒内过期就先刷新；服务端返回 `401 invalid_token` 时刷新并重试一次；
  刷新失败（例如刷新令牌被撤销）才提示重新登录。
- 应用只依赖服务器地址，不依赖 cookie，因此可以直接连公网地址。

## 7. MCP 客户端怎么配合

Agent 侧完全是标准流程，不需要用户提供任何令牌：

1. 客户端 POST `/mcp`，未带令牌 → `401`，`WWW-Authenticate: Bearer realm="thread-pocket",
   resource_metadata="https://…/.well-known/oauth-protected-resource/mcp", scope="mcp:tools"`。
2. 客户端读取资源元信息 → 授权服务器元信息 → 动态注册 → 打开浏览器授权。
3. 用户在浏览器里登录并确认（scope 是 `mcp:tools offline_access`），
   之后同一个客户端再授权会被记住，不再重复确认。
4. 客户端带上访问令牌调用 `initialize`，服务端在响应里返回**内嵌的 skill 说明**
   （`instructions`），Agent 由此知道该如何归类与写入，不需要额外安装 Skill。

## 8. 对外部署清单

```bash
THREADPOCKET_PUBLIC_URL=https://pocket.example.com \
HOST=127.0.0.1 \
PORT=8787 \
THREADPOCKET_DB=/var/lib/thread-pocket/data.sqlite \
node src/index.js
```

- [ ] 用 HTTPS 反向代理（Caddy / nginx / Cloudflare Tunnel）终结 TLS，服务只监听 `127.0.0.1`。
- [ ] 设置 `THREADPOCKET_PUBLIC_URL`，确认打印出来的 MCP 地址、元信息里的 issuer 都是这个域名。
- [ ] 用启动日志里的初始化链接创建账号，确认 `/api/v1/snapshot` 匿名访问返回 `401`。
- [ ] 确认 `THREADPOCKET_TRUST_LOOPBACK` 没有被打开。
- [ ] 备份 `THREADPOCKET_DB` 指向的文件（账号、令牌与业务数据都在里面）。
- [ ] 需要给脚本发长期凭证时用 `THREADPOCKET_API_KEY`，不要用账号密码。

反向代理需要转发 `X-Forwarded-Proto` 与 `X-Forwarded-Host`；服务用它生成正确的元信息地址。
仓库里的 `docs/deploy.md` 给出了 Caddy 与 nginx 的示例配置。
