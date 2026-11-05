// Protocol guard for client-to-agent messages (FR-6, FR-7, NFR-3).
import { realpath } from 'node:fs/promises';
import { isAbsolute, sep } from 'node:path';

export const CLOSE_UNSUPPORTED_DATA = 1003;
export const CLOSE_INVALID_PAYLOAD = 1007;
export const CLOSE_TOO_BIG = 1009;

/**
 * Parse one WebSocket message. Accept exactly one JSON-RPC 2.0 object, with at
 * most one trailing newline. Reject arrays (batches), several lines and binary
 * frames, because each of these could carry a second request past the cwd check.
 */
export function parseClientMessage(data, isBinary, maxBytes) {
  if (isBinary) return { ok: false, closeCode: CLOSE_UNSUPPORTED_DATA, reason: 'text frames only' };
  const buf = Buffer.isBuffer(data) ? data : Buffer.from(data);
  if (buf.length > maxBytes) return { ok: false, closeCode: CLOSE_TOO_BIG, reason: 'message too big' };
  let text = buf.toString('utf8');
  if (text.endsWith('\r\n')) text = text.slice(0, -2);
  else if (text.endsWith('\n')) text = text.slice(0, -1);
  if (text.includes('\n') || text.includes('\r')) {
    return { ok: false, closeCode: CLOSE_INVALID_PAYLOAD, reason: 'one JSON object per message' };
  }
  let message;
  try {
    message = JSON.parse(text);
  } catch {
    return { ok: false, closeCode: CLOSE_INVALID_PAYLOAD, reason: 'invalid JSON' };
  }
  if (message === null || typeof message !== 'object' || Array.isArray(message)) {
    return { ok: false, closeCode: CLOSE_INVALID_PAYLOAD, reason: 'JSON-RPC object required' };
  }
  if (message.jsonrpc !== '2.0') {
    return { ok: false, closeCode: CLOSE_INVALID_PAYLOAD, reason: 'jsonrpc must be "2.0"' };
  }
  return { ok: true, message };
}

/** Resolve the configured roots once. A root that does not exist is skipped. */
export async function resolveRoots(roots) {
  const resolved = [];
  for (const root of roots) {
    try {
      resolved.push(await realpath(root));
    } catch {
      // A missing root allows nothing. The dry run reports it.
    }
  }
  return resolved;
}

/** True when `path` (already a realpath) is a root or inside one. */
export function isInsideRoots(path, resolvedRoots) {
  return resolvedRoots.some((root) => path === root || path.startsWith(root.endsWith(sep) ? root : root + sep));
}

/**
 * Check `params.cwd` on any request. Return null if it is absent or allowed.
 * Otherwise return a JSON-RPC error response (or a drop marker for notifications).
 */
export async function checkCwd(message, resolvedRoots) {
  const cwd = message?.params?.cwd;
  if (cwd === undefined || cwd === null) return null;
  let allowed = false;
  if (typeof cwd === 'string' && isAbsolute(cwd)) {
    try {
      allowed = isInsideRoots(await realpath(cwd), resolvedRoots);
    } catch {
      allowed = false; // missing path or permission error
    }
  }
  if (allowed) return null;
  if (message.id === undefined || message.id === null) return { drop: true };
  return {
    jsonrpc: '2.0',
    id: message.id,
    error: { code: -32602, message: 'cwd is outside the allowed project roots' },
  };
}
