// _acpcode/sessions/create and _acpcode/sessions/prompt: a session and its first prompt in one call,
// a prompt to an existing session, and the busy guard (-32010). The reply comes once the agent has
// the prompt, not at turn end. Refusals that come before any side effect are checked for that too.
// A fake-agent turn with [chunks:N][slow:MS] lasts about N * MS milliseconds.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdir } from 'node:fs/promises';
import { join } from 'node:path';
import { auth, connect, rpc, sleep, startGateway } from './helpers.mjs';

const create = (ws, params) => rpc(ws, '_acpcode/sessions/create', params);
const promptOf = (ws, params) => rpc(ws, '_acpcode/sessions/prompt', params);
const text = (t) => [{ type: 'text', text: t }];
const index = async (ws) => (await rpc(ws, '_acpcode/sessions/index', {})).result.sessions;
const statusOf = async (ws, sessionId) => (await index(ws)).find((s) => s.sessionId === sessionId)?.status;
async function until(pred, what, ms = 10000) {
  for (const t0 = Date.now(); Date.now() - t0 < ms; await sleep(10)) if (await pred()) return;
  throw new Error(`timed out waiting for ${what}`);
}
async function addProject(ws, path) {
  const res = await rpc(ws, '_acpcode/projects/create', { name: 'test', path });
  assert.ok(res.result?.project, JSON.stringify(res.error));
  return res.result.project;
}

test('create: the session is made and its first prompt accepted in one call; the reply comes before the turn ends', async () => {
  const gw = await startGateway();
  try {
    const a = (await connect(gw.url, auth())).ws;
    await addProject(a, gw.dirs.project);
    const r = await create(a, { cwd: gw.dirs.project, mcpServers: [], prompt: text('[chunks:20][slow:100] long reply') });
    assert.equal(r.error, undefined, JSON.stringify(r.error));
    assert.ok(r.result.sessionId, 'the session/new fields are in the result');
    assert.ok(r.result.modes, 'modes come from session/new');
    assert.match(r.result.turnId, /^[0-9a-f]{32}$/);
    assert.equal(r.result.status, 'accepted');
    assert.equal(await statusOf(a, r.result.sessionId), 'running', 'the reply came while the turn was still running');
    await until(async () => (await statusOf(a, r.result.sessionId)) === 'idle', 'the turn to end');
    assert.equal(gw.spawned(), 1, 'one agent for the project');
    a.close();
  } finally {
    await gw.stop();
  }
});

test('create with an empty prompt gives -32602 and no side effect', async () => {
  const gw = await startGateway();
  try {
    const a = (await connect(gw.url, auth())).ws;
    await addProject(a, gw.dirs.project);
    for (const prompt of [[], text('   '), [{ type: 'image', data: 'x' }], 'not an array']) {
      const r = await create(a, { cwd: gw.dirs.project, prompt });
      assert.equal(r.error?.code, -32602, JSON.stringify(r));
    }
    assert.deepEqual(await index(a), [], 'no session was recorded');
    assert.equal(gw.spawned(), 0, 'no agent started');
    a.close();
  } finally {
    await gw.stop();
  }
});

test('create with a bad cwd gives -32602 and no side effect', async () => {
  const gw = await startGateway();
  try {
    const a = (await connect(gw.url, auth())).ws;
    await addProject(a, gw.dirs.project);
    // Outside the roots: refused by the guard before anything else.
    const outside = await create(a, { cwd: gw.dirs.outside, prompt: text('hi') });
    assert.equal(outside.error?.code, -32602);
    // Inside a root but not inside a registered project.
    const loose = join(gw.dirs.root, 'loose');
    await mkdir(loose);
    const notProject = await create(a, { cwd: loose, prompt: text('hi') });
    assert.equal(notProject.error?.code, -32602);
    // No cwd at all.
    const none = await create(a, { prompt: text('hi') });
    assert.equal(none.error?.code, -32602);
    assert.deepEqual(await index(a), [], 'no session was recorded');
    assert.equal(gw.spawned(), 0, 'no agent started');
    a.close();
  } finally {
    await gw.stop();
  }
});

test('create when the agent is unavailable gives -32000, and the session does not exist', async () => {
  const gw = await startGateway({}, {
    configFn: (dirs, config) => {
      config.agent.command = ['/bin/false']; // exits at once: the agent can never start
    },
  });
  try {
    const a = (await connect(gw.url, auth())).ws;
    await addProject(a, gw.dirs.project);
    const r = await create(a, { cwd: gw.dirs.project, prompt: text('hi') });
    assert.equal(r.error?.code, -32000, JSON.stringify(r));
    assert.deepEqual(await index(a), [], 'no session was recorded, so a retry is safe');
    a.close();
  } finally {
    await gw.stop();
  }
});

test('create with a prompt too large gives -32012 and no side effect', async () => {
  const gw = await startGateway();
  try {
    const a = (await connect(gw.url, auth())).ws;
    await addProject(a, gw.dirs.project);
    const r = await create(a, { cwd: gw.dirs.project, prompt: text('x'.repeat(70 * 1024)) });
    assert.equal(r.error?.code, -32012, JSON.stringify(r.error));
    assert.equal(r.error.data.maxBytes, 64 * 1024);
    assert.deepEqual(await index(a), []);
    assert.equal(gw.spawned(), 0);
    a.close();
  } finally {
    await gw.stop();
  }
});

test('prompt to an unknown session gives -32602 with reason unknown_session', async () => {
  const gw = await startGateway();
  try {
    const a = (await connect(gw.url, auth())).ws;
    await addProject(a, gw.dirs.project);
    const r = await promptOf(a, { sessionId: 'no-such-session', prompt: text('hi') });
    assert.equal(r.error?.code, -32602);
    assert.equal(r.error.data.reason, 'unknown_session');
    assert.equal(gw.spawned(), 0);
    a.close();
  } finally {
    await gw.stop();
  }
});

test('prompt to an existing session gives accepted with a turnId, and the reply comes before turn end', async () => {
  const gw = await startGateway();
  try {
    const a = (await connect(gw.url, auth())).ws;
    await addProject(a, gw.dirs.project);
    const sessionId = (await rpc(a, 'session/new', { cwd: gw.dirs.project, mcpServers: [] })).result.sessionId;
    const r = await promptOf(a, { sessionId, prompt: text('[chunks:20][slow:100] again') });
    assert.equal(r.error, undefined, JSON.stringify(r.error));
    assert.deepEqual(Object.keys(r.result).sort(), ['status', 'turnId']);
    assert.match(r.result.turnId, /^[0-9a-f]{32}$/);
    assert.equal(r.result.status, 'accepted');
    assert.equal(await statusOf(a, sessionId), 'running');
    await until(async () => (await statusOf(a, sessionId)) === 'idle', 'the turn to end');
    a.close();
  } finally {
    await gw.stop();
  }
});

test('busy guard: a prompt while a turn is pending gets -32010 with the running turn, from the phone path and from the gateway call', async () => {
  const gw = await startGateway();
  try {
    const a = (await connect(gw.url, auth())).ws;
    const b = (await connect(gw.url, auth())).ws;
    await addProject(a, gw.dirs.project);
    const sessionId = (await rpc(a, 'session/new', { cwd: gw.dirs.project, mcpServers: [] })).result.sessionId;
    const first = await promptOf(a, { sessionId, prompt: text('[chunks:30][slow:100] first') });
    assert.equal(first.error, undefined);
    const turnId = first.result.turnId;
    assert.equal(await statusOf(b, sessionId), 'running');

    const gatewayCall = await promptOf(b, { sessionId, prompt: text('second') });
    assert.equal(gatewayCall.error?.code, -32010, JSON.stringify(gatewayCall));
    assert.deepEqual(gatewayCall.error.data, { sessionId, turnId });

    const phone = await rpc(b, 'session/prompt', { sessionId, prompt: text('second, phone path') });
    assert.equal(phone.error?.code, -32010, 'the phone path is guarded too');
    assert.equal(phone.error.data.turnId, turnId);

    await until(async () => (await statusOf(b, sessionId)) === 'idle', 'the first turn to end');
    const after = await promptOf(b, { sessionId, prompt: text('[chunks:1] third') });
    assert.equal(after.error, undefined, 'a prompt is accepted once the turn has ended');
    a.close();
    b.close();
  } finally {
    await gw.stop();
  }
});

test('two concurrent prompts to one session: only one is accepted, the other gets -32010', async () => {
  const gw = await startGateway();
  try {
    const a = (await connect(gw.url, auth())).ws;
    const b = (await connect(gw.url, auth())).ws;
    await addProject(a, gw.dirs.project);
    const sessionId = (await rpc(a, 'session/new', { cwd: gw.dirs.project, mcpServers: [] })).result.sessionId;
    const [x, y] = await Promise.all([
      promptOf(a, { sessionId, prompt: text('[chunks:30][slow:100] one') }),
      promptOf(b, { sessionId, prompt: text('[chunks:30][slow:100] two') }),
    ]);
    const results = [x, y];
    const accepted = results.filter((r) => r.result?.status === 'accepted');
    const busy = results.filter((r) => r.error?.code === -32010);
    assert.equal(accepted.length, 1, JSON.stringify(results));
    assert.equal(busy.length, 1, JSON.stringify(results));
    assert.equal(busy[0].error.data.turnId, accepted[0].result.turnId);
    await until(async () => (await statusOf(a, sessionId)) === 'idle', 'the accepted turn to end');
    a.close();
    b.close();
  } finally {
    await gw.stop();
  }
});
