// T-5 and config validation, through the CLI (FR-2, NFR-14, SPEC 6.3, 6.4).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { dryRun, gatewayCommand, hashToken, rawConfig, TOKEN } from './helpers.mjs';

test('loopback listen hosts are accepted', async () => {
  for (const host of ['127.0.0.1', '127.1.2.3', '::1', 'localhost', '::ffff:127.0.0.1']) {
    const run = await dryRun(rawConfig('/srv/p', { listen: { host, port: 8787 } }));
    assert.equal(run.status, 0, `${host}: ${run.stderr}`);
    assert.match(run.stdout, /Config OK \(dry run\)\./);
  }
});

test('T-5: a non-loopback listen host is refused', async () => {
  for (const host of ['0.0.0.0', '::', '10.0.0.1', '192.168.1.5', 'example.com', '128.0.0.1', '', undefined, 127]) {
    const run = await dryRun(rawConfig('/srv/p', { listen: { host, port: 8787 } }));
    assert.notEqual(run.status, 0, String(host));
    assert.match(run.stderr, /listen\.host must be a loopback address/, String(host));
  }
});

test('T-5: the gateway itself (not only --dry-run) exits non-zero for a public host', async () => {
  const { mkdtempSync, writeFileSync, rmSync } = await import('node:fs');
  const { tmpdir } = await import('node:os');
  const { join } = await import('node:path');
  const dir = mkdtempSync(join(tmpdir(), 'acpcode-cfg-'));
  try {
    const file = join(dir, 'config.json');
    writeFileSync(file, JSON.stringify(rawConfig('/srv/p', { listen: { host: '0.0.0.0', port: 0 } })));
    const [cmd, ...args] = gatewayCommand();
    const run = spawnSync(cmd, [...args, '--config', file], { encoding: 'utf8', timeout: 10_000 });
    assert.notEqual(run.status, 0);
    assert.match(run.stderr, /listen\.host must be a loopback address/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('listen.port must be an integer from 0 to 65535', async () => {
  for (const port of [-1, 65536, 1.5, '8787', null]) {
    const run = await dryRun(rawConfig('/srv/p', { listen: { host: '127.0.0.1', port } }));
    assert.notEqual(run.status, 0, String(port));
    assert.match(run.stderr, /listen\.port must be an integer from 0 to 65535/, String(port));
  }
});

test('a raw token in the config is refused (NFR-14)', async () => {
  for (const key of ['token', 'secret']) {
    const raw = rawConfig('/srv/p');
    raw.tokens[0][key] = 'plain-secret';
    const run = await dryRun(raw);
    assert.notEqual(run.status, 0);
    assert.match(run.stderr, /must not contain a raw token/);
  }
});

test('bad hashes, shell-string commands and relative roots are refused, all reported at once', async () => {
  const raw = rawConfig('relative/root', { agent: { command: 'bob acp' } });
  raw.tokens[0].sha256 = 'abc';
  const run = await dryRun(raw);
  assert.notEqual(run.status, 0);
  assert.match(run.stderr, /^Invalid gateway config:\n- /);
  assert.match(run.stderr, /sha256 must be 64/);
  assert.match(run.stderr, /agent\.command must be a non-empty array/);
  assert.match(run.stderr, /must be an absolute path/);
});

test('token entries: uppercase hashes, unsafe ids and duplicate ids are refused', async () => {
  const cases = [
    [(r) => { r.tokens[0].sha256 = hashToken(TOKEN).toUpperCase(); }, /sha256 must be 64 lowercase hex/],
    [(r) => { r.tokens[0].id = 'bad id'; }, /tokens\[0\]\.id must match/],
    [(r) => { r.tokens[0].identity = ''; }, /tokens\[0\]\.identity must match/],
    [(r) => { r.tokens[1].id = r.tokens[0].id; }, /tokens\[1\]\.id "phone" is a duplicate/],
    [(r) => { r.tokens = []; }, /tokens must hold at least one entry/],
    [(r) => { r.tokens = [null]; }, /tokens\[0\] must be an object/],
  ];
  for (const [edit, pattern] of cases) {
    const raw = rawConfig('/srv/p');
    edit(raw);
    const run = await dryRun(raw);
    assert.notEqual(run.status, 0, String(pattern));
    assert.match(run.stderr, pattern);
  }
});

test('agent and roots: empty commands, bad env names, "/" and empty roots are refused', async () => {
  const cases = [
    [{ agent: { command: [] } }, /agent\.command must be a non-empty array/],
    [{ agent: { command: ['bob', ''] } }, /agent\.command must be a non-empty array/],
    [{ agent: { command: ['bob'], envPassthrough: ['lower'] } }, /agent\.envPassthrough must be an array/],
    [{ agent: { command: ['bob'], envPassthrough: 'PATH' } }, /agent\.envPassthrough must be an array/],
    [{ projects: { roots: ['/'] } }, /projects\.roots\[0\] must not be "\/"/],
    [{ projects: { roots: [] } }, /projects\.roots must hold at least one absolute path/],
    [{ trustProxy: 'yes' }, /trustProxy must be true or false/],
  ];
  for (const [overrides, pattern] of cases) {
    const run = await dryRun(rawConfig('/srv/p', overrides));
    assert.notEqual(run.status, 0, String(pattern));
    assert.match(run.stderr, pattern);
  }
});

test('unknown limits, non-positive limits and a per-identity cap above the total are refused', async () => {
  const cases = [
    [{ nope: 1 }, /limits\.nope is not a known limit/],
    [{ lockoutSeconds: 0 }, /limits\.lockoutSeconds must be a positive integer/],
    [{ maxMessageBytes: 1.5 }, /limits\.maxMessageBytes must be a positive integer/],
    [{ maxAgentsPerIdentity: 20, maxAgentsTotal: 10 }, /must not exceed/],
  ];
  for (const [limits, pattern] of cases) {
    const run = await dryRun(rawConfig('/srv/p', { limits }));
    assert.notEqual(run.status, 0, String(pattern));
    assert.match(run.stderr, pattern);
  }
});

test('unreadable and non-JSON config files are refused', async () => {
  const bad = await dryRun('{ not json');
  assert.notEqual(bad.status, 0);
  assert.match(bad.stderr, /is not valid JSON/);
  const arr = await dryRun('[]');
  assert.notEqual(arr.status, 0);
  assert.match(arr.stderr, /config must be a JSON object/);
  const [cmd, ...args] = gatewayCommand();
  const missing = spawnSync(cmd, [...args, '--config', '/nonexistent/acpcode.json', '--dry-run'], { encoding: 'utf8' });
  assert.notEqual(missing.status, 0);
  assert.match(missing.stderr, /cannot read \/nonexistent\/acpcode\.json/);
  const noArg = spawnSync(cmd, args, { encoding: 'utf8' });
  assert.equal(noArg.status, 2);
  assert.match(noArg.stderr, /Usage: .*--config <file> \[--dry-run\]/);
});

test('the dry run applies defaults and prints no token hashes', async () => {
  const raw = rawConfig('/srv/p');
  delete raw.agent.envPassthrough;
  const run = await dryRun(raw);
  assert.equal(run.status, 0, run.stderr);
  const summary = JSON.parse(run.stdout.slice(0, run.stdout.lastIndexOf('}') + 1));
  assert.deepEqual(summary.limits, {
    maxMessageBytes: 16 * 1024 * 1024,
    maxAgentsPerIdentity: 4,
    maxAgentsTotal: 16,
    maxConnectionsPerIdentity: 8,
    authFailuresPerWindow: 10,
    authWindowSeconds: 60,
    lockoutSeconds: 600,
    approvalTimeoutSeconds: 43200,
    idleSeconds: 1800,
  });
  assert.deepEqual(summary.envPassthrough, ['PATH', 'HOME']);
  assert.deepEqual(summary.tokens, ['phone (owner)', 'other (guest)']);
  assert.equal(summary.listen, '127.0.0.1:0');
  assert.equal(summary.trustProxy, false);
  assert.match(summary.roots[0], /^\/srv\/p \(missing: no cwd will be allowed\)$/);
  assert.equal(run.stdout.includes(hashToken(TOKEN)), false, 'no hash in the summary');
});

test('the example config passes the dry run', async () => {
  const { readFileSync } = await import('node:fs');
  const run = await dryRun(readFileSync(new URL('../config.example.json', import.meta.url), 'utf8'));
  assert.equal(run.status, 0, run.stderr);
});
