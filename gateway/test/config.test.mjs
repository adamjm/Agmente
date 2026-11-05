// T-5 and config validation (FR-2, NFR-14).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { ConfigError, isLoopbackAddress, validateConfig } from '../src/config.js';
import { rawConfig } from './helpers.mjs';

const MAIN = fileURLToPath(new URL('../src/main.js', import.meta.url));

test('loopback detection', () => {
  for (const a of ['127.0.0.1', '127.1.2.3', '::1', 'localhost', '::ffff:127.0.0.1']) assert.equal(isLoopbackAddress(a), true, a);
  for (const a of ['0.0.0.0', '::', '10.0.0.1', '192.168.1.5', 'example.com', '128.0.0.1', '', undefined]) {
    assert.equal(isLoopbackAddress(a), false, String(a));
  }
});

test('T-5: a non-loopback listen host is refused', () => {
  for (const host of ['0.0.0.0', '::', '192.168.1.10']) {
    assert.throws(() => validateConfig(rawConfig('/srv/p', { listen: { host, port: 8787 } })), ConfigError, host);
  }
});

test('T-5: main.js exits non-zero for a public host', () => {
  const dir = mkdtempSync(join(tmpdir(), 'agmente-cfg-'));
  try {
    const file = join(dir, 'config.json');
    writeFileSync(file, JSON.stringify(rawConfig('/srv/p', { listen: { host: '0.0.0.0', port: 8787 } })));
    const run = spawnSync(process.execPath, [MAIN, '--config', file, '--dry-run'], { encoding: 'utf8' });
    assert.notEqual(run.status, 0);
    assert.match(run.stderr, /listen\.host must be a loopback address/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('a raw token in the config is refused (NFR-14)', () => {
  const raw = rawConfig('/srv/p');
  raw.tokens[0].token = 'plain-secret';
  assert.throws(() => validateConfig(raw), /must not contain a raw token/);
});

test('bad hashes, shell-string commands and relative roots are refused', () => {
  const raw = rawConfig('relative/root', { agent: { command: 'bob acp' } });
  raw.tokens[0].sha256 = 'abc';
  const err = assert.throws(() => validateConfig(raw), ConfigError);
  void err;
  try {
    validateConfig(raw);
  } catch (e) {
    const text = e.errors.join('\n');
    assert.match(text, /sha256 must be 64/);
    assert.match(text, /agent\.command must be a non-empty array/);
    assert.match(text, /must be an absolute path/);
  }
});

test('unknown limits and a per-identity cap above the total are refused', () => {
  assert.throws(() => validateConfig(rawConfig('/srv/p', { limits: { nope: 1 } })), /not a known limit/);
  assert.throws(
    () => validateConfig(rawConfig('/srv/p', { limits: { maxAgentsPerIdentity: 20, maxAgentsTotal: 10 } })),
    /must not exceed/,
  );
});

test('a valid config is normalized and frozen', () => {
  const config = validateConfig(rawConfig('/srv/p'));
  assert.equal(config.limits.maxMessageBytes, 16 * 1024 * 1024);
  assert.equal(Object.isFrozen(config.tokens[0]), true);
});
