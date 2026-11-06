// Admission before upgrade, over the wire: T-2, T-3, T-4, T-7, T-10 (FR-1, FR-3, FR-5, FR-8).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { auth, connect, nextClose, OTHER_TOKEN, SLOW_EXIT_AGENT, sleep, startGateway, TOKEN } from './helpers.mjs';

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

test('T-3: wrong token gets 401, right token gets 101', async () => {
  const gw = await startGateway();
  try {
    assert.equal((await connect(gw.url, auth('wrong-token-abcdefghijk'))).status, 401);
    await gw.settle();
    assert.equal(gw.spawned(), 0);
    const ok = await connect(gw.url, auth());
    assert.equal(ok.status, 101);
    const line = await gw.waitForAudit((l) => l.event === 'connect');
    assert.equal(line.identity, 'owner');
    assert.equal(line.device, 'phone');
    assert.equal(typeof line.pid, 'number');
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

test('T-7: the connection over the per-identity cap gets 429; the cap frees after the agent exits', async () => {
  const gw = await startGateway({ limits: { maxAgentsPerIdentity: 2, maxAgentsTotal: 3 } });
  try {
    const a = await connect(gw.url, auth());
    const b = await connect(gw.url, auth());
    const c = await connect(gw.url, auth());
    assert.deepEqual([a.status, b.status, c.status], [101, 101, 429]);
    assert.equal(c.headers['retry-after'], '30');
    await gw.waitForAudit((l) => l.event === 'reject' && l.reason === 'capacity');
    await gw.settle();
    assert.equal(gw.spawned(), 2);
    // Another identity still fits under the total cap of 3.
    const other = await connect(gw.url, auth(OTHER_TOKEN));
    assert.equal(other.status, 101);
    // Total cap reached now.
    assert.equal((await connect(gw.url, auth(OTHER_TOKEN))).status, 429);
    a.ws.close();
    await nextClose(a.ws);
    await gw.waitForAudit((l) => l.event === 'agent_exit');
    await sleep(50);
    const d = await connect(gw.url, auth());
    assert.equal(d.status, 101);
    for (const s of [b, other, d]) s.ws.close();
  } finally {
    await gw.stop();
  }
});

test('T-7: parallel requests cannot pass the cap', async () => {
  const gw = await startGateway({ limits: { maxAgentsPerIdentity: 2, maxAgentsTotal: 16 } });
  try {
    const results = await Promise.all(Array.from({ length: 6 }, () => connect(gw.url, auth())));
    assert.equal(results.filter((r) => r.status === 101).length, 2);
    assert.equal(results.filter((r) => r.status === 429).length, 4);
    await gw.settle();
    assert.equal(gw.spawned(), 2);
    for (const r of results) r.ws?.close();
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

test('D-015: a closed socket keeps its slot until the agent has exited', async () => {
  const marker = join(await mkdtemp(join(tmpdir(), 'agmente-slow-')), 'exited');
  // Agent that keeps running for 600 ms after SIGTERM, as Bob does while it saves its task store.
  const gw = await startGateway({
    agent: { command: [process.execPath, SLOW_EXIT_AGENT, marker, '600'], envPassthrough: ['PATH'] },
    limits: { maxAgentsPerIdentity: 1, maxAgentsTotal: 1 },
  });
  try {
    const a = await connect(gw.url, auth());
    assert.equal(a.status, 101);
    await sleep(300); // let the agent install its SIGTERM handler
    a.ws.close();
    await nextClose(a.ws);
    await sleep(100);
    // The old agent is still running: no second agent may start.
    assert.equal(existsSync(marker), false);
    assert.equal((await connect(gw.url, auth())).status, 429);
    assert.equal(gw.spawned(), 1);
    // After it has exited, the slot is free again.
    for (let i = 0; i < 40 && !existsSync(marker); i++) await sleep(50);
    assert.equal(existsSync(marker), true);
    await gw.waitForAudit((l) => l.event === 'agent_exit');
    await sleep(50);
    const b = await connect(gw.url, auth());
    assert.equal(b.status, 101);
    b.ws.close();
    await nextClose(b.ws);
  } finally {
    await gw.stop();
  }
});
