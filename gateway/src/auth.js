// Bearer-token authentication and the failed-auth rate limiter (FR-1, FR-8, NFR-5).
import { createHash, timingSafeEqual } from 'node:crypto';
import { isLoopbackAddress } from './config.js';

/** SHA-256 of a token, as lowercase hex. */
export function hashToken(token) {
  return createHash('sha256').update(token, 'utf8').digest('hex');
}

/** Extract the token from an `Authorization: Bearer <token>` header, or return null. */
export function parseBearer(header) {
  if (typeof header !== 'string') return null;
  const match = /^Bearer\s+([A-Za-z0-9._~+/=-]{16,512})\s*$/i.exec(header);
  return match ? match[1] : null;
}

/**
 * Find the token entry whose hash matches. Compares against every entry in
 * constant time per entry and does not stop early, so timing does not reveal
 * which entry matched.
 */
export function findTokenEntry(tokens, authorizationHeader) {
  const token = parseBearer(authorizationHeader);
  if (token === null) return null;
  const presented = Buffer.from(hashToken(token), 'hex');
  let found = null;
  for (const entry of tokens) {
    const expected = Buffer.from(entry.sha256, 'hex');
    if (expected.length === presented.length && timingSafeEqual(expected, presented) && found === null) {
      found = entry;
    }
  }
  return found;
}

/**
 * The address to rate-limit on. Behind Caddy every peer is loopback, so use the
 * X-Forwarded-For header, but only when trustProxy is on and the peer is loopback.
 * Use the LAST entry: the proxy appends the address it saw. Earlier entries come
 * from the client and an attacker can set them to dodge the lockout.
 */
export function clientKey(req, trustProxy) {
  const peer = req.socket?.remoteAddress ?? 'unknown';
  if (trustProxy && isLoopbackAddress(peer)) {
    const xff = req.headers['x-forwarded-for'];
    const last = typeof xff === 'string' ? xff.split(',').map((s) => s.trim()).filter(Boolean).at(-1) : undefined;
    if (last) return last;
  }
  return peer;
}

/** Count failures per key in a sliding window; lock a key out once it reaches the limit. */
export class FailureLimiter {
  constructor({ maxFailures, windowMs, lockoutMs, now = () => Date.now() }) {
    this.maxFailures = maxFailures;
    this.windowMs = windowMs;
    this.lockoutMs = lockoutMs;
    this.now = now;
    this.failures = new Map(); // key -> timestamps
    this.lockedUntil = new Map(); // key -> time
  }

  isLocked(key) {
    const until = this.lockedUntil.get(key);
    if (until === undefined) return false;
    if (this.now() < until) return true;
    this.lockedUntil.delete(key);
    return false;
  }

  recordFailure(key) {
    const t = this.now();
    const recent = (this.failures.get(key) ?? []).filter((ts) => t - ts < this.windowMs);
    recent.push(t);
    this.failures.set(key, recent);
    if (recent.length >= this.maxFailures) {
      this.lockedUntil.set(key, t + this.lockoutMs);
      this.failures.delete(key);
    }
    this.prune(t);
  }

  prune(t) {
    if (this.failures.size < 10_000) return;
    for (const [key, list] of this.failures) {
      if (list.every((ts) => t - ts >= this.windowMs)) this.failures.delete(key);
    }
  }
}
