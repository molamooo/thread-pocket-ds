import {
  ACCESS_TOKEN_TTL_SECONDS,
  AUTHORIZATION_CODE_TTL_SECONDS,
  REFRESH_TOKEN_TTL_SECONDS,
  SESSION_TTL_SECONDS,
  newSetupToken,
} from "./config.js";
import { hashPassword, hashToken, randomId, randomToken, verifyPassword } from "./crypto.js";
import { newId, nowIso } from "../util.js";

function inSeconds(seconds) {
  return new Date(Date.now() + seconds * 1000).toISOString();
}

function parseScopes(value) {
  if (!value) return [];
  try {
    const parsed = JSON.parse(value);
    return Array.isArray(parsed) ? parsed.map(String) : [];
  } catch {
    return String(value).split(/\s+/).filter(Boolean);
  }
}

/**
 * 账号、会话、OAuth 客户端与令牌的存取。所有令牌在库里都只有哈希。
 */
export function createAuthStore(db, config) {
  const q = {
    userCount: db.prepare("select count(*) as count from auth_users"),
    userByEmail: db.prepare("select * from auth_users where email = ?"),
    userById: db.prepare("select * from auth_users where id = ?"),
    userInsert: db.prepare(
      "insert into auth_users (id, email, name, password_hash, created_at, updated_at) values (?,?,?,?,?,?)",
    ),
    userUpdatePassword: db.prepare("update auth_users set password_hash = ?, updated_at = ? where id = ?"),

    setupGet: db.prepare("select * from auth_setup limit 1"),
    setupInsert: db.prepare("insert into auth_setup (id, token_hash, created_at) values (?,?,?)"),
    setupDelete: db.prepare("delete from auth_setup"),

    sessionInsert: db.prepare(
      "insert into auth_sessions (token_hash, user_id, user_agent, created_at, expires_at) values (?,?,?,?,?)",
    ),
    sessionGet: db.prepare("select * from auth_sessions where token_hash = ? and expires_at > ?"),
    sessionDelete: db.prepare("delete from auth_sessions where token_hash = ?"),
    sessionDeleteUser: db.prepare("delete from auth_sessions where user_id = ?"),
    sessionSweep: db.prepare("delete from auth_sessions where expires_at <= ?"),

    clientGet: db.prepare("select * from oauth_clients where id = ?"),
    clientInsert: db.prepare(
      `insert into oauth_clients (id, name, redirect_uris, scopes, source, metadata_url, created_at)
       values (?,?,?,?,?,?,?)
       on conflict(id) do update set name = excluded.name, redirect_uris = excluded.redirect_uris,
         scopes = excluded.scopes, source = excluded.source, metadata_url = excluded.metadata_url`,
    ),
    clientTouch: db.prepare("update oauth_clients set last_used_at = ? where id = ?"),
    clientList: db.prepare("select * from oauth_clients order by created_at desc"),
    clientDelete: db.prepare("delete from oauth_clients where id = ? and source != 'static'"),

    codeInsert: db.prepare(
      `insert into oauth_codes (code_hash, client_id, user_id, redirect_uri, scopes, code_challenge,
        code_challenge_method, resource, created_at, expires_at)
       values (?,?,?,?,?,?,?,?,?,?)`,
    ),
    codeGet: db.prepare("select * from oauth_codes where code_hash = ?"),
    codeConsume: db.prepare("update oauth_codes set consumed_at = ? where code_hash = ? and consumed_at is null"),
    codeSweep: db.prepare("delete from oauth_codes where expires_at <= ?"),

    tokenInsert: db.prepare(
      `insert into oauth_tokens (token_hash, kind, client_id, user_id, scopes, family_id, created_at, expires_at)
       values (?,?,?,?,?,?,?,?)`,
    ),
    tokenGet: db.prepare("select * from oauth_tokens where token_hash = ?"),
    tokenRevoke: db.prepare("update oauth_tokens set revoked_at = ? where token_hash = ? and revoked_at is null"),
    tokenReplace: db.prepare("update oauth_tokens set replaced_by = ? where token_hash = ?"),
    familyRevoke: db.prepare("update oauth_tokens set revoked_at = ? where family_id = ? and revoked_at is null"),
    clientRevoke: db.prepare(
      "update oauth_tokens set revoked_at = ? where client_id = ? and user_id = ? and revoked_at is null",
    ),
    tokenSweep: db.prepare("delete from oauth_tokens where expires_at <= ? and revoked_at is not null"),
    tokenListByUser: db.prepare(
      "select * from oauth_tokens where user_id = ? and kind = 'refresh' and revoked_at is null and expires_at > ?",
    ),

    consentGet: db.prepare("select * from oauth_consents where client_id = ? and user_id = ?"),
    consentUpsert: db.prepare(
      `insert into oauth_consents (client_id, user_id, scopes, created_at, last_used_at) values (?,?,?,?,?)
       on conflict(client_id, user_id) do update set scopes = excluded.scopes, last_used_at = excluded.last_used_at`,
    ),
    consentDelete: db.prepare("delete from oauth_consents where client_id = ? and user_id = ?"),
    consentDeleteClient: db.prepare("delete from oauth_consents where client_id = ?"),
    consentList: db.prepare("select * from oauth_consents where user_id = ? order by last_used_at desc"),

    rateGet: db.prepare("select * from auth_rate_limits where bucket = ?"),
    rateUpsert: db.prepare(
      `insert into auth_rate_limits (bucket, count, window_started_at) values (?,?,?)
       on conflict(bucket) do update set count = excluded.count, window_started_at = excluded.window_started_at`,
    ),
  };

  function mapUser(row) {
    if (!row) return null;
    return { id: row.id, email: row.email, name: row.name, created_at: row.created_at };
  }

  function mapClient(row) {
    if (!row) return null;
    return {
      id: row.id,
      name: row.name,
      redirect_uris: parseScopes(row.redirect_uris),
      scopes: parseScopes(row.scopes),
      source: row.source,
      metadata_url: row.metadata_url ?? null,
      created_at: row.created_at,
      last_used_at: row.last_used_at ?? null,
    };
  }

  const store = {
    /* ---------------------------------- 账号 ---------------------------------- */

    userCount() {
      return q.userCount.get().count;
    },

    initialized() {
      return store.userCount() > 0;
    },

    getUser(id) {
      return mapUser(q.userById.get(id));
    },

    getUserByEmail(email) {
      return mapUser(q.userByEmail.get(String(email).toLowerCase().trim()));
    },

    createUser({ email, password, name = "Owner" }) {
      const normalized = String(email).toLowerCase().trim();
      if (q.userByEmail.get(normalized)) {
        throw Object.assign(new Error("该邮箱已存在"), { status: 409 });
      }
      const id = newId("us");
      const stamp = nowIso();
      q.userInsert.run(id, normalized, name, hashPassword(password), stamp, stamp);
      return mapUser(q.userById.get(id));
    },

    authenticate(email, password) {
      const row = q.userByEmail.get(String(email ?? "").toLowerCase().trim());
      if (!row) return null;
      if (!verifyPassword(String(password ?? ""), row.password_hash)) return null;
      return mapUser(row);
    },

    changePassword(userId, password) {
      q.userUpdatePassword.run(hashPassword(password), nowIso(), userId);
      q.sessionDeleteUser.run(userId);
    },

    /* -------------------------------- 首次初始化 ------------------------------- */

    /** 还没有账号时生成一次性初始化凭证；账号建立后立即删除。 */
    ensureSetupToken() {
      if (store.initialized()) {
        q.setupDelete.run();
        return null;
      }
      const existing = q.setupGet.get();
      // 显式指定了凭证就总是以它为准：链接丢了也能靠重新部署/env 恢复
      if (config.setupToken) {
        if (!existing || existing.token_hash !== hashToken(config.setupToken)) {
          q.setupDelete.run();
          q.setupInsert.run(newId("su"), hashToken(config.setupToken), nowIso());
        }
        return config.setupToken;
      }
      if (existing) return null;
      const token = newSetupToken();
      q.setupInsert.run(newId("su"), hashToken(token), nowIso());
      return token;
    },

    verifySetupToken(token) {
      if (!token) return false;
      const row = q.setupGet.get();
      if (!row) return false;
      return row.token_hash === hashToken(token);
    },

    clearSetupToken() {
      q.setupDelete.run();
    },

    /* --------------------------------- 会话 ----------------------------------- */

    createSession(userId, userAgent = null) {
      const token = randomToken("tp_sess");
      q.sessionInsert.run(hashToken(token), userId, userAgent, nowIso(), inSeconds(SESSION_TTL_SECONDS));
      return { token, expires_in: SESSION_TTL_SECONDS };
    },

    sessionUser(token) {
      if (!token) return null;
      const row = q.sessionGet.get(hashToken(token), nowIso());
      if (!row) return null;
      return store.getUser(row.user_id);
    },

    deleteSession(token) {
      if (!token) return;
      q.sessionDelete.run(hashToken(token));
    },

    /* ------------------------------ OAuth 客户端 ------------------------------- */

    upsertClient({ id, name, redirectUris, scopes, source = "dcr", metadataUrl = null }) {
      const clientId = id ?? newId("oc");
      q.clientInsert.run(
        clientId,
        name || "未命名客户端",
        JSON.stringify(redirectUris ?? []),
        JSON.stringify(scopes ?? []),
        source,
        metadataUrl,
        nowIso(),
      );
      return store.getClient(clientId);
    },

    getClient(id) {
      return mapClient(q.clientGet.get(id));
    },

    touchClient(id) {
      q.clientTouch.run(nowIso(), id);
    },

    listClients() {
      return q.clientList.all().map(mapClient);
    },

    deleteClient(id) {
      q.clientDelete.run(id);
      q.consentDeleteClient.run(id);
    },

    /* -------------------------------- 授权码 ---------------------------------- */

    createCode({ clientId, userId, redirectUri, scopes, codeChallenge, method, resource }) {
      const code = randomToken("tp_code");
      q.codeInsert.run(
        hashToken(code),
        clientId,
        userId,
        redirectUri,
        JSON.stringify(scopes),
        codeChallenge,
        method,
        resource ?? null,
        nowIso(),
        inSeconds(AUTHORIZATION_CODE_TTL_SECONDS),
      );
      return code;
    },

    /** 一次性消费：重复使用同一个授权码会失败。 */
    consumeCode(code) {
      const row = q.codeGet.get(hashToken(code));
      if (!row) return null;
      if (row.consumed_at) return { ...row, reused: true, scopes: parseScopes(row.scopes) };
      if (row.expires_at <= nowIso()) return { ...row, expired: true, scopes: parseScopes(row.scopes) };
      q.codeConsume.run(nowIso(), hashToken(code));
      return { ...row, scopes: parseScopes(row.scopes) };
    },

    /* --------------------------------- 令牌 ----------------------------------- */

    issueTokens({ clientId, userId, scopes, familyId = null, kind = "access", ttl = null }) {
      const token = randomToken(kind === "refresh" ? "tp_rt" : "tp_at");
      const family = familyId ?? randomId(12);
      const seconds = ttl ?? (kind === "refresh" ? REFRESH_TOKEN_TTL_SECONDS : ACCESS_TOKEN_TTL_SECONDS);
      q.tokenInsert.run(
        hashToken(token),
        kind,
        clientId,
        userId,
        JSON.stringify(scopes),
        family,
        nowIso(),
        inSeconds(seconds),
      );
      return { token, family, expires_in: seconds };
    },

    findToken(token) {
      const row = q.tokenGet.get(hashToken(token));
      if (!row) return null;
      const revoked = Boolean(row.revoked_at) || row.expires_at <= nowIso();
      return { ...row, scopes: parseScopes(row.scopes), active: !revoked };
    },

    revokeToken(token) {
      const row = q.tokenGet.get(hashToken(token));
      if (!row) return false;
      if (row.kind === "refresh") {
        q.familyRevoke.run(nowIso(), row.family_id);
      } else {
        q.tokenRevoke.run(nowIso(), hashToken(token));
      }
      return true;
    },

    revokeFamily(familyId) {
      q.familyRevoke.run(nowIso(), familyId);
    },

    markReplaced(oldToken, newToken) {
      q.tokenReplace.run(hashToken(newToken), hashToken(oldToken));
    },

    revokeClientForUser(clientId, userId) {
      q.clientRevoke.run(nowIso(), clientId, userId);
      q.consentDelete.run(clientId, userId);
    },

    /* ------------------------------- 已授权连接 -------------------------------- */

    consentFor(clientId, userId) {
      const row = q.consentGet.get(clientId, userId);
      if (!row) return null;
      return { ...row, scopes: parseScopes(row.scopes) };
    },

    recordConsent(clientId, userId, scopes) {
      const stamp = nowIso();
      q.consentUpsert.run(clientId, userId, JSON.stringify(scopes), stamp, stamp);
    },

    listConsents(userId) {
      return q.consentList.all(userId).map((row) => ({
        client_id: row.client_id,
        scopes: parseScopes(row.scopes),
        created_at: row.created_at,
        last_used_at: row.last_used_at,
      }));
    },

    /* ------------------------------- 速率限制 --------------------------------- */

    /** 固定窗口计数，超限返回 false。用于登录、注册与令牌端点。 */
    hitRateLimit(bucket, limit, windowSeconds) {
      const now = Date.now();
      const row = q.rateGet.get(bucket);
      if (!row || now - Date.parse(row.window_started_at) > windowSeconds * 1000) {
        q.rateUpsert.run(bucket, 1, new Date(now).toISOString());
        return true;
      }
      if (row.count >= limit) return false;
      q.rateUpsert.run(bucket, row.count + 1, row.window_started_at);
      return true;
    },

    /* --------------------------------- 清理 ----------------------------------- */

    sweep() {
      const stamp = nowIso();
      q.sessionSweep.run(stamp);
      q.codeSweep.run(stamp);
      q.tokenSweep.run(stamp);
    },
  };

  return store;
}
