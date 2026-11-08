// Admission before upgrade, over the wire: T-2, T-3, T-4, T-7, T-10 (FR-1, FR-3, FR-5, FR-8).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { mkdir, mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { auth, connect, FAKE_AGENT, nextClose, OTHER_TOKEN, rpc, sleep, startGateway, TOKEN, useProject } from './helpers.mjs';

test('only a well-formed bearer header is accepted', async () => {
  const gw = await startGateway({ limits: { authFailuresPerWindow: 100 } });
  try {
    for (const header of [`Bearer ${TOKEN}`, `bearer ${TOKEN}`, `Bearer  ${TOKEN}  `]) {
      const ok = await connect(gw.url, { Authorization: header });
      assert.equal(ok.status, 101, header);
      ok.ws.close();
      await nextClose(ok.ws);
    }
    for (const bad of ['', 'Basic abc', 'Bearer', 'Bearer short', `Bearer ${TOKEN} extra`, `Token ${TOKEN}`, `Bearer ${TOKEN}x`]) {
      const res = await connect(gw.url, { Authorization: bad });
      assert.equal(res.status, 401, JSON.stringify(bad));
      assert.equal(res.headers['www-authenticate'], 'Bearer');
    }
  } finally {
    await gw.stop();
  }
});

test('T-2: no Authorization header gets 401 and spawns nothing', async () => {
  const gw = await startGateway();
  try {
    const res = await connect(gw.url);
    assert.equal(res.status, 401);
    await gw.waitForAudit((l) => l.event === 'reject' && l.status === 401 && l.reason === 'token');
    await gw.settle();
    assert.equal(gw.spawned(), 0);
  } finally {
    await gw.stop();
  }
});

test('T-3: wrong token gets 401, right token gets 101; no agent starts until a request is routed to a project', async () => {
  const gw = await startGateway();
  try {
    assert.equal((await connect(gw.url, auth('wrong-token-abcdefghijk'))).status, 401);
    const ok = await connect(gw.url, auth());
    assert.equal(ok.status, 101);
    const line = await gw.waitForAudit((l) => l.event === 'connect');
    assert.equal(line.identity, 'owner');
    assert.equal(line.device, 'phone');
    await gw.settle();
    assert.equal(gw.spawned(), 0, 'a socket owns no agent (D-025)');
    const { project } = await useProject(gw, ok.ws);
    const start = await gw.waitForAudit((l) => l.event === 'agent_start');
    assert.equal(start.project, project.id);
    assert.equal(typeof start.pid, 'number');
    assert.equal(gw.spawned(), 1);
    ok.ws.close();
  } finally {
    await gw.stop();
  }
});

test('T-4: an Origin header gets 403 even with a valid token', async () => {
  const gw = await startGateway();
  try {
    for (const origin of ['https://evil.example', 'null']) {
      const res = await connect(gw.url, { ...auth(), Origin: origin });
      assert.equal(res.status, 403, origin);
    }
    await gw.waitForAudit((l) => l.event === 'reject' && l.status === 403 && l.reason === 'origin');
    await gw.settle();
    assert.equal(gw.spawned(), 0);
  } finally {
    await gw.stop();
  }
});

test('T-7: the connection over the per-identity cap gets 429; the cap frees when a socket closes', async () => {
  const gw = await startGateway({ limits: { maxConnectionsPerIdentity: 2 } });
  try {
    const a = await connect(gw.url, auth());
    const b = await connect(gw.url, auth());
    const c = await connect(gw.url, auth());
    assert.deepEqual([a.status, b.status, c.status], [101, 101, 429]);
    assert.equal(c.headers['retry-after'], '30');
    await gw.waitForAudit((l) => l.event === 'reject' && l.reason === 'capacity');
    // Another identity has its own cap.
    const other = await connect(gw.url, auth(OTHER_TOKEN));
    assert.equal(other.status, 101);
    a.ws.close();
    await nextClose(a.ws);
    await gw.waitForAudit((l) => l.event === 'disconnect');
    await sleep(50);
    const d = await connect(gw.url, auth());
    assert.equal(d.status, 101);
    for (const s of [b, other, d]) s.ws.close();
  } finally {
    await gw.stop();
  }
});

test('T-7: parallel requests cannot pass the cap', async () => {
  const gw = await startGateway({ limits: { maxConnectionsPerIdentity: 2 } });
  try {
    const results = await Promise.all(Array.from({ length: 6 }, () => connect(gw.url, auth())));
    assert.equal(results.filter((r) => r.status === 101).length, 2);
    assert.equal(results.filter((r) => r.status === 429).length, 4);
    for (const r of results) r.ws?.close();
  } finally {
    await gw.stop();
  }
});

test('maxAgentsTotal caps running project agents; a request over it gets a JSON-RPC error', async () => {
  const gw = await startGateway({ limits: { maxAgentsPerIdentity: 1, maxAgentsTotal: 1 } });
  try {
    const { ws } = await connect(gw.url, auth());
    await useProject(gw, ws);
    const second = join(gw.dirs.root, 'second');
    await mkdir(second);
    assert.ok((await rpc(ws, '_acpcode/projects/create', { name: 'second', path: second })).result);
    const res = await rpc(ws, 'session/new', { cwd: second, mcpServers: [] });
    assert.equal(res.error.code, -32000);
    assert.match(res.error.message, /agent capacity reached/);
    await gw.waitForAudit((l) => l.event === 'agent_capacity');
    assert.equal(gw.spawned(), 1);
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('T-10: 10 failures lock the address out, even for a good token', async () => {
  const gw = await startGateway({ limits: { authFailuresPerWindow: 10, authWindowSeconds: 60, lockoutSeconds: 600 } });
  try {
    for (let i = 0; i < 10; i += 1) assert.equal((await connect(gw.url, auth('bad-token-abcdefghijklmn'))).status, 401);
    const locked = await connect(gw.url, auth());
    assert.equal(locked.status, 429);
    assert.equal(locked.headers['retry-after'], '600');
    await gw.waitForAudit((l) => l.event === 'reject' && l.reason === 'locked_out');
    await gw.settle();
    assert.equal(gw.spawned(), 0);
  } finally {
    await gw.stop();
  }
});

test('T-10: the lockout expires after lockoutSeconds', async () => {
  const gw = await startGateway({ limits: { authFailuresPerWindow: 2, authWindowSeconds: 60, lockoutSeconds: 1 } });
  try {
    await connect(gw.url, auth('bad-token-abcdefghijklmn'));
    await connect(gw.url, auth('bad-token-abcdefghijklmn'));
    assert.equal((await connect(gw.url, auth())).status, 429);
    await sleep(1200);
    const ok = await connect(gw.url, auth());
    assert.equal(ok.status, 101);
    ok.ws.close();
  } finally {
    await gw.stop();
  }
});

test('T-10: failures older than the window do not count', async () => {
  const gw = await startGateway({ limits: { authFailuresPerWindow: 2, authWindowSeconds: 1, lockoutSeconds: 600 } });
  try {
    await connect(gw.url, auth('bad-token-abcdefghijklmn'));
    await sleep(1200);
    await connect(gw.url, auth('bad-token-abcdefghijklmn'));
    const ok = await connect(gw.url, auth());
    assert.equal(ok.status, 101);
    ok.ws.close();
  } finally {
    await gw.stop();
  }
});

test('T-10: behind a trusted proxy the limit applies per X-Forwarded-For address', async () => {
  const gw = await startGateway({ trustProxy: true, limits: { authFailuresPerWindow: 3 } });
  try {
    const attacker = { 'X-Forwarded-For': '203.0.113.9' };
    for (let i = 0; i < 3; i += 1) await connect(gw.url, { ...attacker, ...auth('bad-token-abcdefghijklmn') });
    assert.equal((await connect(gw.url, { ...attacker, ...auth() })).status, 429);
    const line = await gw.waitForAudit((l) => l.event === 'reject' && l.reason === 'locked_out');
    assert.equal(line.client, '203.0.113.9');
    // A different client behind the same proxy is not locked out.
    const ok = await connect(gw.url, { 'X-Forwarded-For': '198.51.100.7', ...auth() });
    assert.equal(ok.status, 101);
    ok.ws.close();
  } finally {
    await gw.stop();
  }
});

test('T-10: a client-supplied X-Forwarded-For prefix cannot dodge the lockout', async () => {
  const gw = await startGateway({ trustProxy: true, limits: { authFailuresPerWindow: 3 } });
  try {
    // The proxy appends the real address last; the attacker controls the earlier entries.
    for (let i = 0; i < 3; i += 1) {
      await connect(gw.url, { 'X-Forwarded-For': `10.0.0.${i}, 203.0.113.9`, ...auth('bad-token-abcdefghijklmn') });
    }
    const res = await connect(gw.url, { 'X-Forwarded-For': '10.9.9.9, 203.0.113.9', ...auth() });
    assert.equal(res.status, 429);
  } finally {
    await gw.stop();
  }
});

test('X-Forwarded-For is ignored when trustProxy is off', async () => {
  const gw = await startGateway({ trustProxy: false, limits: { authFailuresPerWindow: 2 } });
  try {
    await connect(gw.url, { 'X-Forwarded-For': '203.0.113.1', ...auth('bad-token-abcdefghijklmn') });
    await connect(gw.url, { 'X-Forwarded-For': '203.0.113.2', ...auth('bad-token-abcdefghijklmn') });
    // Both failures count against 127.0.0.1, so a spoofed new XFF does not help.
    assert.equal((await connect(gw.url, { 'X-Forwarded-For': '203.0.113.3', ...auth() })).status, 429);
    const line = await gw.waitForAudit((l) => l.event === 'reject' && l.reason === 'locked_out');
    assert.match(line.client, /127\.0\.0\.1$/);
  } finally {
    await gw.stop();
  }
});

test('health check needs no auth and reveals nothing', async () => {
  const gw = await startGateway();
  try {
    const res = await fetch(`${gw.httpUrl}healthz`);
    assert.equal(res.status, 200);
    assert.equal(await res.text(), 'ok');
    assert.equal((await fetch(`${gw.httpUrl}other`)).status, 404);
    assert.equal((await fetch(`${gw.httpUrl}healthz`, { method: 'POST' })).status, 404);
    await gw.settle();
    assert.equal(gw.spawned(), 0);
  } finally {
    await gw.stop();
  }
});

test('D-015: a replacement agent starts only after the old one has exited', async () => {
  const marker = join(await mkdtemp(join(tmpdir(), 'acpcode-slow-')), 'exited');
  // The agent keeps running for 600 ms after SIGTERM, as Bob does while it saves its task store.
  const gw = await startGateway({
    agent: { command: [process.execPath, FAKE_AGENT, '--exit-delay', '600', '--exit-marker', marker], envPassthrough: ['PATH'] },
  });
  try {
    const { ws } = await connect(gw.url, auth());
    await useProject(gw, ws);
    const first = (await rpc(ws, '_test/state', {})).result.pid;
    // An agent line over the cap makes the gateway stop the agent.
    ws.send(JSON.stringify({ jsonrpc: '2.0', id: 'big', method: '_test/big', params: { bytes: 17 * 1024 * 1024 } }));
    await gw.waitForAudit((l) => l.event === 'agent_line_too_big');
    // A request now must wait for the old process to exit, then start a new one.
    const t0 = Date.now();
    const state = await rpc(ws, '_test/state', {});
    assert.ok(existsSync(marker), 'the old agent had exited before the new one answered');
    assert.equal(readFileSync(marker, 'utf8'), `exited ${first}`);
    assert.notEqual(state.result.pid, first);
    assert.ok(Date.now() - t0 >= 400, 'the request waited for the slow exit');
    const events = gw.audit.map((l) => l.event).filter((e) => e === 'agent_start' || e === 'agent_exit');
    assert.deepEqual(events, ['agent_start', 'agent_exit', 'agent_start']);
    ws.close();
  } finally {
    await gw.stop();
  }
});
