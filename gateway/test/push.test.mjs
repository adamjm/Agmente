// Push token registration (PLAN 3.11 without delivery, D-052). No APNs call is made.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { auth, connect, rpc, startGateway, OTHER_TOKEN, sleep } from './helpers.mjs';

const TOKEN_A = 'ab'.repeat(32);
const TOKEN_B = 'cd'.repeat(32);

function rows(gw) {
  const db = new DatabaseSync(join(gw.config.stateDir, 'gateway.db'), { readOnly: true });
  try {
    return db.prepare('SELECT identity, device, token, environment FROM push_tokens ORDER BY identity, device').all().map((r) => ({ ...r }));
  } finally {
    db.close();
  }
}

test('the gateway advertises the push extension', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    const init = await rpc(ws, 'initialize', { protocolVersion: 1, clientCapabilities: {} });
    assert.ok(init.result._meta['acpcode/gateway'].extensions.includes('push'));
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('register stores the token under the authenticated device; a second call replaces it', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    assert.deepEqual((await rpc(ws, '_acpcode/push/register', { deviceToken: TOKEN_A.toUpperCase(), environment: 'sandbox' })).result, {});
    assert.deepEqual(rows(gw), [{ identity: 'owner', device: 'phone', token: TOKEN_A, environment: 'sandbox' }]);
    await rpc(ws, '_acpcode/push/register', { deviceToken: TOKEN_B, environment: 'production' });
    assert.deepEqual(rows(gw), [{ identity: 'owner', device: 'phone', token: TOKEN_B, environment: 'production' }]);
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('bad tokens and environments are refused and store nothing', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    for (const deviceToken of ['', 'zz'.repeat(32), 'ab'.repeat(31), 'ab'.repeat(101), `${TOKEN_A}a`, 7, null, `${TOKEN_A}\n`]) {
      const res = await rpc(ws, '_acpcode/push/register', { deviceToken, environment: 'sandbox' });
      assert.equal(res.error?.code, -32602, JSON.stringify(deviceToken));
      assert.match(res.error.message, /deviceToken/);
    }
    for (const environment of ['', 'Sandbox', 'dev', 3, null, undefined]) {
      const res = await rpc(ws, '_acpcode/push/register', { deviceToken: TOKEN_A, environment });
      assert.equal(res.error?.code, -32602, JSON.stringify(environment));
      assert.match(res.error.message, /environment/);
    }
    assert.deepEqual(rows(gw), []);
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('unregister removes only the caller\'s token', async () => {
  const gw = await startGateway();
  try {
    const a = await connect(gw.url, auth());
    const b = await connect(gw.url, auth(OTHER_TOKEN));
    await rpc(a.ws, '_acpcode/push/register', { deviceToken: TOKEN_A, environment: 'sandbox' });
    await rpc(b.ws, '_acpcode/push/register', { deviceToken: TOKEN_B, environment: 'sandbox' });
    assert.equal(rows(gw).length, 2);
    assert.deepEqual((await rpc(b.ws, '_acpcode/push/unregister', {})).result, {});
    assert.deepEqual(rows(gw), [{ identity: 'owner', device: 'phone', token: TOKEN_A, environment: 'sandbox' }]);
    // Removing again is not an error.
    assert.deepEqual((await rpc(b.ws, '_acpcode/push/unregister', {})).result, {});
    a.ws.close();
    b.ws.close();
  } finally {
    await gw.stop();
  }
});

test('the token never appears in the audit log or in a response', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    const res = await rpc(ws, '_acpcode/push/register', { deviceToken: TOKEN_A, environment: 'sandbox' });
    assert.ok(!JSON.stringify(res).includes(TOKEN_A));
    await sleep(100);
    assert.ok(gw.audit.some((e) => e.event === 'push_registered' && e.identity === 'owner' && e.device === 'phone'));
    assert.ok(!JSON.stringify(gw.audit).includes(TOKEN_A));
    ws.close();
  } finally {
    await gw.stop();
  }
});
