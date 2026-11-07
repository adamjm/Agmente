// APNs delivery (PLAN 3.11, FR-23, NFR-11, D-053, D-054, D-055). Every request goes to a fake APNs
// server (HTTP/2 over TLS, a throwaway certificate and key made at run time). Nothing reaches Apple.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { chmodSync, copyFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { auth, connect, dryRun, rawConfig, rpc, sleep, spawnGateway, startGateway, useProject, makeDirs } from './helpers.mjs';
import { KEY_ID, TEAM_ID, TOPIC, makeMaterial, pushConfig, startFakeApns, verifyProviderToken } from './apns-fake.mjs';

const TOKEN_HEX = 'ab'.repeat(32);
const TOKEN_PROD = 'cd'.repeat(32);
const PROMPT_SECRET = 'PROMPT-SECRET-7731';

async function until(pred, what, ms = 10000) {
  for (const t0 = Date.now(); Date.now() - t0 < ms; await sleep(10)) if (await pred()) return;
  throw new Error(`timed out waiting for ${what}`);
}

function rows(stateDir) {
  const db = new DatabaseSync(join(stateDir, 'gateway.db'), { readOnly: true });
  try {
    return db.prepare('SELECT identity, device, token, environment FROM push_tokens ORDER BY identity, device').all().map((r) => ({ ...r }));
  } finally {
    db.close();
  }
}

/** The event names of the notifications the fake received, in order. */
const events = (fake) => fake.requests.map((r) => JSON.parse(r.body).event);

/** Collect every message a socket receives. */
function collect(ws) {
  const seen = [];
  ws.on('message', (d) => seen.push(JSON.parse(d.toString())));
  return seen;
}

/** Set up: a fake APNs server, a gateway that uses it, and the owner's phone with a token and a project. */
async function setup({ fallback, extraFake, env = 'sandbox' } = {}) {
  const material = await makeMaterial();
  const fake = await startFakeApns(material);
  if (fallback) fake.fallback = fallback;
  const prod = extraFake ? await startFakeApns(material) : null;
  const gw = await startGateway({ push: pushConfig(material, fake.url, prod ? prod.url : fake.url) });
  const phone = await connect(gw.url, auth());
  const deviceToken = env === 'production' ? TOKEN_PROD : TOKEN_HEX;
  assert.deepEqual((await rpc(phone.ws, '_agmente/push/register', { deviceToken, environment: env })).result, {});
  const { sessionId } = await useProject(gw, phone.ws);
  const cleanup = async () => {
    phone.ws.close();
    await fake.close();
    if (prod) await prod.close();
    await gw.stop();
    await material.cleanup();
  };
  return { material, fake, prod, gw, phone, sessionId, deviceToken, cleanup };
}

const turnEnded = (fake) => fake.requests.filter((r) => JSON.parse(r.body).event === 'turn_ended');

test('no push is made when the push block is absent (FR-23 off by default)', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    await rpc(ws, '_agmente/push/register', { deviceToken: TOKEN_HEX, environment: 'sandbox' });
    const { sessionId } = await useProject(gw, ws);
    await rpc(ws, 'session/prompt', { sessionId, prompt: [{ type: 'text', text: 'hello' }] });
    await sleep(300);
    assert.ok(!gw.audit.some((e) => ['push_sent', 'push_failed', 'push_token_removed', 'push_dropped'].includes(e.event)), 'no delivery audit line');
    assert.ok(!gw.audit.some((e) => e.event === 'push_enabled'));
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('a finished turn sends one alert: path, headers, a provider token that verifies, and a payload with no prompt text', async () => {
  const s = await setup();
  try {
    await rpc(s.phone.ws, 'session/prompt', { sessionId: s.sessionId, prompt: [{ type: 'text', text: `${PROMPT_SECRET} please` }] });
    await until(() => s.fake.requests.length === 1, 'the push');
    const req = s.fake.requests[0];
    assert.equal(req.method, 'POST');
    assert.equal(req.path, `/3/device/${TOKEN_HEX}`);
    assert.equal(req.httpVersion, '2.0');
    assert.equal(req.headers['apns-topic'], TOPIC);
    assert.equal(req.headers['apns-push-type'], 'alert');
    assert.equal(req.headers['apns-priority'], '10');
    assert.match(req.headers.authorization, /^bearer [\w-]+\.[\w-]+\.[\w-]+$/);

    const jwt = verifyProviderToken(req.headers.authorization.slice('bearer '.length), s.material.publicPem);
    assert.equal(jwt.ok, true, 'the signature verifies against the key');
    assert.deepEqual(jwt.header, { alg: 'ES256', kid: KEY_ID });
    assert.equal(jwt.claims.iss, TEAM_ID);
    assert.ok(Math.abs(jwt.claims.iat - Date.now() / 1000) < 120, 'iat is now');

    assert.ok(Buffer.byteLength(req.body) <= 256, 'payload at most 256 bytes (NFR-11)');
    assert.ok(!req.body.includes(PROMPT_SECRET), 'no prompt text in the payload');
    assert.ok(!req.body.includes('echo:'), 'no reply text in the payload');
    const body = JSON.parse(req.body);
    assert.equal(body.aps.alert.title, 'test', 'the project name');
    assert.equal(body.aps.alert.body, 'Turn finished');
    assert.equal(body.event, 'turn_ended');
    assert.equal(body.sessionId, s.sessionId);

    await until(() => s.gw.audit.some((e) => e.event === 'push_sent'), 'push_sent');
    const sent = s.gw.audit.find((e) => e.event === 'push_sent');
    assert.equal(sent.identity, 'owner');
    assert.equal(sent.device, 'phone');
    assert.equal(sent.status, 200);
    const audit = JSON.stringify(s.gw.audit);
    assert.ok(!audit.includes(TOKEN_HEX), 'no device token in the audit log');
    assert.ok(!audit.includes(req.headers.authorization.slice(7)), 'no provider token in the audit log');
    assert.ok(!audit.includes(PROMPT_SECRET));
  } finally {
    await s.cleanup();
  }
});

test('a production token goes to the production host, a sandbox token to the sandbox host', async () => {
  const s = await setup({ extraFake: true, env: 'production' });
  try {
    await rpc(s.phone.ws, 'session/prompt', { sessionId: s.sessionId, prompt: [{ type: 'text', text: 'x' }] });
    await until(() => s.prod.requests.length === 1, 'the production push');
    assert.equal(s.fake.requests.length, 0, 'the sandbox host gets nothing');
    assert.equal(s.prod.requests[0].path, `/3/device/${TOKEN_PROD}`);
  } finally {
    await s.cleanup();
  }
});

test('an approval request sends "Approval needed"; a payload never carries the tool text', async () => {
  const s = await setup();
  try {
    const turn = rpc(s.phone.ws, 'session/prompt', { sessionId: s.sessionId, prompt: [{ type: 'text', text: `${PROMPT_SECRET} [permission]` }] });
    await until(() => events(s.fake).includes('approval_needed'), 'the approval push');
    const pending = (await rpc(s.phone.ws, '_agmente/approvals/pending', {})).result.approvals;
    assert.equal(pending.length, 1);
    assert.deepEqual((await rpc(s.phone.ws, '_agmente/approvals/answer', { approvalId: pending[0].approvalId, cancelled: true })).result, {});
    await turn;
    const req = s.fake.requests.find((r) => JSON.parse(r.body).event === 'approval_needed');
    const body = JSON.parse(req.body);
    assert.equal(body.aps.alert.body, 'Approval needed');
    assert.equal(body.sessionId, s.sessionId);
    assert.ok(!req.body.includes(PROMPT_SECRET) && !req.body.includes('[permission]'));
  } finally {
    await s.cleanup();
  }
});

test('a turn that fails (the agent exits mid-turn) sends "Session failed"', async () => {
  const s = await setup();
  try {
    const turn = rpc(s.phone.ws, 'session/prompt', { sessionId: s.sessionId, prompt: [{ type: 'text', text: 'x [chunks:5] [slow:1000]' }] });
    await sleep(200);
    s.phone.ws.send(JSON.stringify({ jsonrpc: '2.0', id: 999001, method: '_test/exit', params: { sessionId: s.sessionId } }));
    const res = await turn;
    assert.ok(res.error, 'the turn ended with an error');
    await until(() => events(s.fake).includes('session_failed'), 'the session_failed push');
    assert.equal(JSON.parse(s.fake.requests.at(-1).body).aps.alert.body, 'Session failed');
  } finally {
    await s.cleanup();
  }
});

test('a device with a live subscriber on the session gets no push; once it leaves, the next turn pushes', async () => {
  const s = await setup();
  try {
    // A second socket of the same device subscribes: the app is open on this session.
    const watcher = await connect(s.gw.url, auth());
    const seen = collect(watcher.ws);
    assert.ok((await rpc(watcher.ws, '_agmente/sessions/subscribe', { sessionId: s.sessionId, afterSeq: 0 })).result.headSeq >= 0);

    await rpc(s.phone.ws, 'session/prompt', { sessionId: s.sessionId, prompt: [{ type: 'text', text: 'x' }] });
    await until(() => seen.some((m) => m.method === '_agmente/event' && m.params?.message?.method === '_agmente/turn_ended'), 'turn_ended on the subscriber');
    await sleep(500);
    assert.equal(s.fake.requests.length, 0, 'the foreground device gets no push');

    // A different device of the same owner is not foreground: it gets the push.
    // (Only the phone device holds a token here, so this is checked by the next step.)
    watcher.ws.close();
    await sleep(300);
    await rpc(s.phone.ws, 'session/prompt', { sessionId: s.sessionId, prompt: [{ type: 'text', text: 'y' }] });
    await until(() => s.fake.requests.length === 1, 'the push after the subscriber left');
  } finally {
    await s.cleanup();
  }
});

test('a subscriber on another session does not suppress the push', async () => {
  const s = await setup();
  try {
    const watcher = await connect(s.gw.url, auth());
    const other = await useProject(s.gw, watcher.ws, s.gw.dirs.project);
    assert.ok(other.sessionId !== s.sessionId);
    await rpc(watcher.ws, '_agmente/sessions/subscribe', { sessionId: other.sessionId, afterSeq: 0 });
    await rpc(s.phone.ws, 'session/prompt', { sessionId: s.sessionId, prompt: [{ type: 'text', text: 'x' }] });
    await until(() => s.fake.requests.length === 1, 'the push');
    watcher.ws.close();
  } finally {
    await s.cleanup();
  }
});

test('410 Gone removes the token at once and is not retried', async () => {
  const s = await setup({ fallback: { status: 410, reason: 'Unregistered' } });
  try {
    await rpc(s.phone.ws, 'session/prompt', { sessionId: s.sessionId, prompt: [{ type: 'text', text: 'x' }] });
    await until(() => s.gw.audit.some((e) => e.event === 'push_token_removed'), 'push_token_removed');
    await sleep(2000);
    assert.equal(s.fake.requests.length, 1, 'no retry on 410');
    assert.deepEqual(rows(s.gw.config.stateDir), [], 'the row is gone');
    const failed = s.gw.audit.find((e) => e.event === 'push_failed');
    assert.equal(failed.status, 410);
    assert.equal(failed.reason, 'Unregistered');
  } finally {
    await s.cleanup();
  }
});

test('BadDeviceToken and DeviceTokenNotForTopic remove the token', async () => {
  const s = await setup({ fallback: { status: 400, reason: 'BadDeviceToken' } });
  try {
    await rpc(s.phone.ws, 'session/prompt', { sessionId: s.sessionId, prompt: [{ type: 'text', text: 'x' }] });
    await until(() => s.gw.audit.some((e) => e.event === 'push_token_removed'), 'removal on BadDeviceToken');
    assert.deepEqual(rows(s.gw.config.stateDir), []);
    assert.equal(s.fake.requests.length, 1);

    // Register again, then answer DeviceTokenNotForTopic.
    assert.deepEqual((await rpc(s.phone.ws, '_agmente/push/register', { deviceToken: TOKEN_HEX, environment: 'sandbox' })).result, {});
    s.fake.fallback = { status: 400, reason: 'DeviceTokenNotForTopic' };
    await rpc(s.phone.ws, 'session/prompt', { sessionId: s.sessionId, prompt: [{ type: 'text', text: 'y' }] });
    await until(() => s.gw.audit.filter((e) => e.event === 'push_token_removed').length === 2, 'removal on DeviceTokenNotForTopic');
    assert.deepEqual(rows(s.gw.config.stateDir), []);
  } finally {
    await s.cleanup();
  }
});

test('429 is retried twice with backoff, then given up; the token is kept', async () => {
  const s = await setup({ fallback: { status: 429, reason: 'TooManyRequests' } });
  try {
    await rpc(s.phone.ws, 'session/prompt', { sessionId: s.sessionId, prompt: [{ type: 'text', text: 'x' }] });
    await until(() => s.gw.audit.some((e) => e.event === 'push_failed'), 'push_failed after retries', 15000);
    assert.equal(s.fake.requests.length, 3, 'one try and two retries');
    assert.equal(s.gw.audit.find((e) => e.event === 'push_failed').status, 429);
    assert.equal(rows(s.gw.config.stateDir).length, 1, 'a throttled token is not removed');
  } finally {
    await s.cleanup();
  }
});

test('a 5xx that clears on retry sends the push', async () => {
  const s = await setup();
  s.fake.answers.push({ status: 503, reason: 'ServiceUnavailable' }, { status: 500, reason: 'InternalServerError' });
  try {
    await rpc(s.phone.ws, 'session/prompt', { sessionId: s.sessionId, prompt: [{ type: 'text', text: 'x' }] });
    await until(() => s.gw.audit.some((e) => e.event === 'push_sent'), 'push_sent after two 5xx', 15000);
    assert.equal(s.fake.requests.length, 3);
  } finally {
    await s.cleanup();
  }
});

test('403 ExpiredProviderToken rebuilds the provider token once and sends again', async () => {
  const s = await setup();
  s.fake.answers.push({ status: 403, reason: 'ExpiredProviderToken' });
  try {
    await rpc(s.phone.ws, 'session/prompt', { sessionId: s.sessionId, prompt: [{ type: 'text', text: 'x' }] });
    await until(() => s.gw.audit.some((e) => e.event === 'push_sent'), 'push_sent after a refresh');
    assert.equal(s.fake.requests.length, 2);
    assert.notEqual(s.fake.requests[0].headers.authorization, s.fake.requests[1].headers.authorization, 'a new token');
    for (const r of s.fake.requests) assert.equal(verifyProviderToken(r.headers.authorization.slice(7), s.material.publicPem).ok, true);
  } finally {
    await s.cleanup();
  }
});

test('two finished turns on one device send two pushes, in order', async () => {
  const s = await setup();
  try {
    await rpc(s.phone.ws, 'session/prompt', { sessionId: s.sessionId, prompt: [{ type: 'text', text: 'one' }] });
    await rpc(s.phone.ws, 'session/prompt', { sessionId: s.sessionId, prompt: [{ type: 'text', text: 'two' }] });
    await until(() => s.fake.requests.length === 2, 'two pushes');
    assert.deepEqual(events(s.fake), ['turn_ended', 'turn_ended']);
  } finally {
    await s.cleanup();
  }
});

test('a key readable by group or others stops the gateway from starting (PLAN 3.11)', async () => {
  const material = await makeMaterial();
  const dirs = await makeDirs();
  try {
    const readable = join(material.dir, 'readable.p8');
    copyFileSync(material.keyFile, readable);
    chmodSync(readable, 0o640);
    const config = rawConfig(dirs.root, { push: { ...pushConfig(material, 'https://127.0.0.1:9'), keyFile: readable } });
    const result = await dryRun(config);
    assert.equal(result.status, 1, result.stdout);
    assert.match(result.stderr, /group or others/);
    assert.ok(!result.stderr.includes('PRIVATE KEY'), 'no key bytes in the output');
    await assert.rejects(
      spawnGateway(config, { configDir: dirs.base }),
      /exited with 1 before listening/,
    );
  } finally {
    await dirs.cleanup();
    await material.cleanup();
  }
});

test('an unparsable key is refused and its bytes are not printed', async () => {
  const material = await makeMaterial();
  const dirs = await makeDirs();
  try {
    const bad = join(material.dir, 'bad.p8');
    writeFileSync(bad, '-----BEGIN TEST BLOB-----\nnot base64 at all !!\n-----END TEST BLOB-----\n');
    chmodSync(bad, 0o600);
    const result = await dryRun(rawConfig(dirs.root, { push: { ...pushConfig(material, 'https://127.0.0.1:9'), keyFile: bad } }));
    assert.equal(result.status, 1);
    assert.match(result.stderr, /cannot be parsed|not a PKCS#8/);
    assert.ok(!`${result.stdout}${result.stderr}`.includes('not base64'));
  } finally {
    await dirs.cleanup();
    await material.cleanup();
  }
});

test('the push block is validated: ids, topic, URLs and unknown keys are refused', async () => {
  const material = await makeMaterial();
  const dirs = await makeDirs();
  try {
    const good = pushConfig(material, 'https://127.0.0.1:9');
    const cases = [
      [{ keyId: 'short' }, /push\.keyId/],
      [{ teamId: 'lowercase1' }, /push\.teamId/],
      [{ topic: '' }, /push\.topic/],
      [{ keyFile: 'relative.p8' }, /push\.keyFile/],
      [{ sandboxURL: 'http://127.0.0.1:9' }, /push\.sandboxURL/],
      [{ productionURL: 'https://user:pw@example.com' }, /push\.productionURL/],
      [{ sandboxURL: 'https://example.com/path' }, /push\.sandboxURL/],
      [{ bogus: true }, /push\.bogus is not a known key/],
    ];
    for (const [patch, pattern] of cases) {
      const result = await dryRun(rawConfig(dirs.root, { push: { ...good, ...patch } }));
      assert.equal(result.status, 1, JSON.stringify(patch));
      assert.match(result.stderr, pattern);
    }
  } finally {
    await dirs.cleanup();
    await material.cleanup();
  }
});

test('the dry run shows the push settings with ids and paths, never key material', async () => {
  const material = await makeMaterial();
  const dirs = await makeDirs();
  try {
    const result = await dryRun(rawConfig(dirs.root, { push: pushConfig(material, 'https://127.0.0.1:9') }));
    assert.equal(result.status, 0, result.stderr);
    const summary = JSON.parse(result.stdout.split('\nConfig OK')[0]);
    assert.equal(summary.push.keyId, KEY_ID);
    assert.equal(summary.push.teamId, TEAM_ID);
    assert.equal(summary.push.topic, TOPIC);
    assert.equal(summary.push.keyFile, material.keyFile);
    assert.ok(!result.stdout.includes('PRIVATE KEY'));

    const off = await dryRun(rawConfig(dirs.root));
    assert.equal(JSON.parse(off.stdout.split('\nConfig OK')[0]).push, 'off');
  } finally {
    await dirs.cleanup();
    await material.cleanup();
  }
});
