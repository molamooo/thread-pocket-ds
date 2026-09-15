import { SCOPE_DEFINITIONS } from "./config.js";

export function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

const STYLE = `
:root { color-scheme: dark; --bg:#090b12; --panel:rgba(255,255,255,.05); --line:rgba(255,255,255,.1);
  --text:#eef1f8; --muted:#8d94a8; --accent:#7c8cff; --danger:#f87171; }
* { box-sizing: border-box; }
body { margin:0; min-height:100vh; display:grid; place-items:center; padding:40px 20px;
  background: radial-gradient(900px 500px at 12% -10%, rgba(124,140,255,.24), transparent 60%),
    radial-gradient(700px 420px at 100% 0%, rgba(255,138,190,.16), transparent 55%), var(--bg);
  color:var(--text); font:14px/1.55 -apple-system, "SF Pro Text", "PingFang SC", system-ui, sans-serif; }
.card { width:100%; max-width:460px; background:var(--panel); border:1px solid var(--line);
  border-radius:20px; padding:26px; backdrop-filter: blur(24px);
  box-shadow: 0 30px 80px rgba(0,0,0,.45); }
.mark { width:40px; height:40px; border-radius:12px; display:grid; place-items:center; font-size:19px;
  background: linear-gradient(150deg,#7c8cff,#b98cff 60%,#ff8abe); color:#0b0d14; }
h1 { font-size:17px; margin:16px 0 6px; }
p { color:var(--muted); margin:0 0 18px; font-size:12.5px; }
label { display:block; font-size:11.5px; font-weight:700; color:#b9c0d2; margin:14px 0 6px; }
input { width:100%; font:inherit; color:var(--text); background:rgba(255,255,255,.06);
  border:1px solid var(--line); border-radius:11px; padding:10px 12px; }
input:focus { outline:none; border-color:rgba(124,140,255,.65); background:rgba(255,255,255,.09); }
button { font:inherit; font-weight:650; cursor:pointer; border-radius:11px; padding:10px 16px; border:1px solid var(--line);
  background:rgba(255,255,255,.06); color:var(--text); transition:transform .14s ease, background .14s ease; }
button:hover { transform:translateY(-1px); background:rgba(255,255,255,.1); }
button.primary { background:var(--accent); border-color:transparent; color:#0b0d14; }
button.primary:hover { background:#8f9dff; }
button.danger { color:var(--danger); }
.row { display:flex; gap:10px; align-items:center; margin-top:20px; }
.row .spacer { flex:1; }
.meta { background:rgba(0,0,0,.25); border:1px solid var(--line); border-radius:12px; padding:12px 14px; margin:0 0 4px; }
.meta dt { color:var(--muted); font-size:11px; margin-top:8px; }
.meta dt:first-child { margin-top:0; }
.meta dd { margin:2px 0 0; word-break:break-all; font-size:12.5px; }
ul.scopes { list-style:none; padding:0; margin:8px 0 0; }
ul.scopes li { padding:8px 0; border-top:1px solid var(--line); font-size:12.5px; }
ul.scopes li:first-child { border-top:none; }
ul.scopes code { color:var(--accent); font-size:11.5px; }
ul.scopes span { display:block; color:var(--muted); font-size:11.5px; margin-top:2px; }
.msg { margin-top:14px; font-size:12.5px; min-height:18px; }
.msg.error { color:var(--danger); }
.msg.ok { color:#7ee0a8; }
.foot { margin-top:18px; color:#6f7688; font-size:11px; }
a { color:var(--accent); }
code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
`;

export function layout({ title, body }) {
  return `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<meta name="color-scheme" content="dark" />
<title>${escapeHtml(title)} · Thread Pocket</title>
<style>${STYLE}</style>
</head>
<body>
<main class="card">
  <div class="mark">🧵</div>
  ${body}
</main>
</body>
</html>
`;
}

export function messagePage({ title, message, tone = "ok", actions = "" }) {
  return layout({
    title,
    body: `
    <h1>${escapeHtml(title)}</h1>
    <p>${escapeHtml(message)}</p>
    <div class="row">${actions}</div>`,
  });
}

export function setupPage({ token, error = null, embedded = false }) {
  // 初始化链接把凭证放在 URL 的 # 之后：浏览器不会把 fragment 发给服务器，
  // 因此它不会出现在反向代理的访问日志里。代价是服务端渲染时读不到它，
  // 需要在页面上用一小段脚本把它填进表单，真正的校验发生在 POST。
  const hidden = embedded ? "" : `<input type="hidden" name="token" id="setup-token" value="${escapeHtml(token ?? "")}" />`;
  const script = embedded
    ? ""
    : `
    <script>
      (function () {
        var field = document.getElementById("setup-token");
        if (!field) return;
        var pick = function (raw) {
          if (!raw) return "";
          var text = raw.charAt(0) === "#" || raw.charAt(0) === "?" ? raw.slice(1) : raw;
          try { return new URLSearchParams(text).get("token") || ""; } catch (error) { return ""; }
        };
        var token = pick(location.hash) || pick(location.search);
        if (token && !field.value) field.value = token;
        // 地址栏里不再留下凭证
        if (location.hash.indexOf("token=") !== -1) {
          history.replaceState(null, "", location.pathname);
        }
      })();
    </script>`;
  return layout({
    title: "初始化账号",
    body: `
    <h1>创建个人账号</h1>
    <p>Thread Pocket 是单人多端工具。账号只建立一次，之后用浏览器登录即可授权 MCP 客户端与桌面端。</p>
    <form method="post" action="/auth/setup">
      ${hidden}
      <label for="email">邮箱</label>
      <input id="email" name="email" type="email" autocomplete="username" required />
      <label for="password">密码（至少 12 位）</label>
      <input id="password" name="password" type="password" autocomplete="new-password" minlength="12" required />
      <div class="row">
        <button class="primary" type="submit">创建账号</button>
        <span class="spacer"></span>
      </div>
      <div class="msg error">${escapeHtml(error ?? "")}</div>
    </form>
    ${script}
    <div class="foot">${
      embedded
        ? "本机首次初始化：只有这台机器能访问该页面。"
        : "凭证在服务启动时打印，也可用 npm run setup:link 重新获取。它只用于这一次初始化。"
    }</div>`,
  });
}

export function loginPage({ next = "/", error = null, brandHint = "" }) {
  return layout({
    title: "登录",
    body: `
    <h1>登录 Thread Pocket</h1>
    <p>${brandHint ? escapeHtml(brandHint) : "登录后即可授权当前客户端访问你的私人线索。"}</p>
    <form method="post" action="/auth/login">
      <input type="hidden" name="next" value="${escapeHtml(next)}" />
      <label for="email">邮箱</label>
      <input id="email" name="email" type="email" autocomplete="username" required />
      <label for="password">密码</label>
      <input id="password" name="password" type="password" autocomplete="current-password" required />
      <div class="row">
        <button class="primary" type="submit">登录</button>
        <span class="spacer"></span>
        <a href="/">返回控制台</a>
      </div>
      <div class="msg error">${escapeHtml(error ?? "")}</div>
    </form>`,
  });
}

export function consentPage({ request, clientName, clientId }) {
  const scopeItems = request.scopes
    .map(
      (scope) =>
        `<li><code>${escapeHtml(scope)}</code><span>${escapeHtml(SCOPE_DEFINITIONS[scope] ?? "")}</span></li>`,
    )
    .join("");
  const target = new URL(request.redirectUri);
  const hiddenFields = [
    ["client_id", request.clientId],
    ["redirect_uri", request.redirectUri],
    ["scope", request.scopes.join(" ")],
    ["state", request.state ?? ""],
    ["code_challenge", request.codeChallenge],
    ["code_challenge_method", request.codeChallengeMethod],
    ["resource", request.resource ?? ""],
  ]
    .map(([name, value]) => `<input type="hidden" name="${name}" value="${escapeHtml(value ?? "")}" />`)
    .join("");
  return layout({
    title: "授权",
    body: `
    <h1>允许访问？</h1>
    <p>确认这是你正在连接的客户端。它只能在下面列出的范围内读写你的线索。</p>
    <dl class="meta">
      <dt>客户端</dt>
      <dd>${escapeHtml(clientName)}<br /><code>${escapeHtml(clientId)}</code></dd>
      <dt>回调地址</dt>
      <dd>${escapeHtml(target.origin)}${escapeHtml(target.pathname)}</dd>
    </dl>
    <ul class="scopes">${scopeItems}</ul>
    <form method="post" action="/oauth/authorize">
      ${hiddenFields}
      <div class="row">
        <button class="primary" type="submit" name="decision" value="allow">允许</button>
        <button type="submit" name="decision" value="deny">拒绝</button>
        <span class="spacer"></span>
        <a href="/auth/connections">已授权客户端</a>
      </div>
    </form>`,
  });
}

export function connectionsPage({ user, consents, clients }) {
  const rows = consents.length
    ? consents
        .map((consent) => {
          const client = clients.find((item) => item.id === consent.client_id);
          return `<li>
            <code>${escapeHtml(client?.name ?? "未知客户端")}</code>
            <span>${escapeHtml(consent.scopes.join(" · "))}</span>
            <span>最近使用 ${escapeHtml(consent.last_used_at)}</span>
            <form method="post" action="/auth/connections">
              <input type="hidden" name="client_id" value="${escapeHtml(consent.client_id)}" />
              <button class="danger" type="submit">撤销访问</button>
            </form>
          </li>`;
        })
        .join("")
    : `<li><span>还没有客户端获得授权。</span></li>`;
  return layout({
    title: "已授权客户端",
    body: `
    <h1>已授权客户端</h1>
    <p>登录身份：${escapeHtml(user.email)}。撤销后，该客户端的刷新令牌立即失效，需要重新授权。</p>
    <ul class="scopes">${rows}</ul>
    <div class="row">
      <a href="/">返回控制台</a>
      <span class="spacer"></span>
      <form method="post" action="/auth/logout"><button type="submit">退出登录</button></form>
    </div>`,
  });
}
