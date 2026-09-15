import {
  createHash,
  randomBytes,
  scryptSync,
  timingSafeEqual,
} from "node:crypto";

const SCRYPT = { N: 16384, r: 8, p: 1, keyLength: 64 };

export function base64url(buffer) {
  return Buffer.from(buffer).toString("base64url");
}

export function randomId(bytes = 16) {
  return base64url(randomBytes(bytes));
}

/** 生成对外可见的令牌，前缀便于在日志与配置里辨认用途。 */
export function randomToken(prefix) {
  return `${prefix}_${base64url(randomBytes(32))}`;
}

/** 令牌一律只存哈希，数据库泄露也无法直接使用。 */
export function hashToken(token) {
  return createHash("sha256").update(String(token)).digest("hex");
}

export function sha256Base64url(value) {
  return base64url(createHash("sha256").update(value).digest());
}

export function safeEqual(a, b) {
  const bufferA = Buffer.from(String(a));
  const bufferB = Buffer.from(String(b));
  if (bufferA.length !== bufferB.length) return false;
  return timingSafeEqual(bufferA, bufferB);
}

export function hashPassword(password) {
  const salt = randomBytes(16);
  const derived = scryptSync(password, salt, SCRYPT.keyLength, SCRYPT);
  return `scrypt$${SCRYPT.N}$${SCRYPT.r}$${SCRYPT.p}$${base64url(salt)}$${base64url(derived)}`;
}

export function verifyPassword(password, stored) {
  if (typeof stored !== "string") return false;
  const parts = stored.split("$");
  if (parts.length !== 6 || parts[0] !== "scrypt") return false;
  const [, n, r, p, salt, expected] = parts;
  try {
    const derived = scryptSync(password, Buffer.from(salt, "base64url"), Buffer.from(expected, "base64url").length, {
      N: Number(n),
      r: Number(r),
      p: Number(p),
    });
    return safeEqual(base64url(derived), expected);
  } catch {
    return false;
  }
}

/** RFC 7636：校验 PKCE。只接受 S256。 */
export function verifyPkce(verifier, challenge, method = "S256") {
  if (typeof verifier !== "string" || verifier.length < 43 || verifier.length > 128) return false;
  if (!/^[A-Za-z0-9\-._~]+$/.test(verifier)) return false;
  if (method !== "S256") return false;
  return safeEqual(sha256Base64url(verifier), challenge);
}

/** 生成 PKCE 验证码对，供测试与命令行调试使用。 */
export function createPkcePair() {
  const verifier = base64url(randomBytes(48));
  return { verifier, challenge: sha256Base64url(verifier), method: "S256" };
}
