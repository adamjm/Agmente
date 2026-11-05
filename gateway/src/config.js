// Load and validate the gateway config file (SPEC 6.3, FR-2, NFR-14).
import { readFileSync } from 'node:fs';
import { isAbsolute } from 'node:path';

export class ConfigError extends Error {
  constructor(errors) {
    super(`Invalid gateway config:\n- ${errors.join('\n- ')}`);
    this.name = 'ConfigError';
    this.errors = errors;
  }
}

export const DEFAULT_LIMITS = Object.freeze({
  maxMessageBytes: 16 * 1024 * 1024, // NFR-3
  maxAgentsPerIdentity: 4, // NFR-4
  maxAgentsTotal: 16, // NFR-4
  authFailuresPerWindow: 10, // NFR-5
  authWindowSeconds: 60, // NFR-5
  lockoutSeconds: 600, // NFR-5
});

const LOOPBACK_NAMES = new Set(['localhost', '::1', '[::1]']);

/** True when the address is a loopback address (IPv4 127/8, IPv6 ::1, or an IPv4-mapped 127/8). */
export function isLoopbackAddress(address) {
  if (typeof address !== 'string') return false;
  const a = address.trim().toLowerCase();
  if (LOOPBACK_NAMES.has(a)) return true;
  const v4 = a.startsWith('::ffff:') ? a.slice(7) : a;
  return /^127\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.test(v4);
}

const HEX64 = /^[0-9a-f]{64}$/;
const SAFE_ID = /^[A-Za-z0-9._-]{1,64}$/;

/** Validate a parsed config object. Return a normalized, frozen copy, or throw ConfigError. */
export function validateConfig(raw) {
  const errors = [];
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
    throw new ConfigError(['config must be a JSON object']);
  }

  const listen = raw.listen ?? {};
  if (!isLoopbackAddress(listen.host)) {
    errors.push('listen.host must be a loopback address (127.0.0.1, ::1 or localhost). Put Caddy in front for public access.');
  }
  if (!Number.isInteger(listen.port) || listen.port < 0 || listen.port > 65535) {
    errors.push('listen.port must be an integer from 0 to 65535');
  }

  if (raw.trustProxy !== undefined && typeof raw.trustProxy !== 'boolean') {
    errors.push('trustProxy must be true or false');
  }

  const tokens = Array.isArray(raw.tokens) ? raw.tokens : [];
  if (tokens.length === 0) errors.push('tokens must hold at least one entry');
  const seenIds = new Set();
  tokens.forEach((t, i) => {
    if (!t || typeof t !== 'object') {
      errors.push(`tokens[${i}] must be an object`);
      return;
    }
    if (!SAFE_ID.test(t.id ?? '')) errors.push(`tokens[${i}].id must match ${SAFE_ID}`);
    if (!SAFE_ID.test(t.identity ?? '')) errors.push(`tokens[${i}].identity must match ${SAFE_ID}`);
    if (!HEX64.test(t.sha256 ?? '')) errors.push(`tokens[${i}].sha256 must be 64 lowercase hex characters (store the hash, never the token)`);
    if ('token' in t || 'secret' in t) errors.push(`tokens[${i}] must not contain a raw token (NFR-14)`);
    if (seenIds.has(t.id)) errors.push(`tokens[${i}].id "${t.id}" is a duplicate`);
    seenIds.add(t.id);
  });

  const agent = raw.agent ?? {};
  const command = agent.command;
  if (!Array.isArray(command) || command.length === 0 || !command.every((c) => typeof c === 'string' && c.length > 0)) {
    errors.push('agent.command must be a non-empty array of strings (no shell string)');
  }
  const envPassthrough = agent.envPassthrough ?? ['PATH', 'HOME'];
  if (!Array.isArray(envPassthrough) || !envPassthrough.every((e) => typeof e === 'string' && /^[A-Z_][A-Z0-9_]*$/.test(e))) {
    errors.push('agent.envPassthrough must be an array of environment variable names');
  }

  const roots = raw.projects?.roots;
  if (!Array.isArray(roots) || roots.length === 0) {
    errors.push('projects.roots must hold at least one absolute path');
  } else {
    roots.forEach((r, i) => {
      if (typeof r !== 'string' || !isAbsolute(r)) errors.push(`projects.roots[${i}] must be an absolute path`);
      if (r === '/') errors.push(`projects.roots[${i}] must not be "/"`);
    });
  }

  const limits = { ...DEFAULT_LIMITS, ...(raw.limits ?? {}) };
  for (const [key, value] of Object.entries(limits)) {
    if (!(key in DEFAULT_LIMITS)) errors.push(`limits.${key} is not a known limit`);
    else if (!Number.isInteger(value) || value < 1) errors.push(`limits.${key} must be a positive integer`);
  }
  if (limits.maxAgentsPerIdentity > limits.maxAgentsTotal) {
    errors.push('limits.maxAgentsPerIdentity must not exceed limits.maxAgentsTotal');
  }

  if (errors.length > 0) throw new ConfigError(errors);

  return deepFreeze({
    listen: { host: listen.host, port: listen.port },
    trustProxy: raw.trustProxy ?? false,
    tokens: tokens.map((t) => ({ id: t.id, identity: t.identity, sha256: t.sha256 })),
    agent: { command: [...command], envPassthrough: [...envPassthrough] },
    projects: { roots: [...roots] },
    limits,
  });
}

/** Read, parse and validate a config file. */
export function loadConfig(path) {
  let text;
  try {
    text = readFileSync(path, 'utf8');
  } catch (err) {
    throw new ConfigError([`cannot read ${path}: ${err.code ?? err.message}`]);
  }
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch (err) {
    throw new ConfigError([`${path} is not valid JSON: ${err.message}`]);
  }
  return validateConfig(parsed);
}

function deepFreeze(obj) {
  for (const value of Object.values(obj)) {
    if (value && typeof value === 'object') deepFreeze(value);
  }
  return Object.freeze(obj);
}
