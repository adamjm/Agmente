// One agent per project, independent of sockets (PLAN 3.4, FR-16, FR-45, D-015, D-025, D-026).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { auth, connect, makeDirs, nextClose, OTHER_TOKEN, rawConfig, rpc, sleep, spawnGateway, startGateway, useProject } from './helpers.mjs';

/** Collect every message a socket receives. */
const collect = (ws) => {
  const seen = [];
  ws.on('message', (d) => seen.push(JSON.parse(d.toString())));
  return seen;
};
const waitFor = async (seen, pred, ms = 5000) => {
  for (const t0 = Date.now(); Date.now() - t0 < ms; await sleep(20)) {
    const hit = seen.find(pred);
    if (hit) return hit;
  }
  throw new Error(`no matching message in ${JSON.stringify(seen.map((m) => m.method ?? m.id))}`);
};

test('two sockets for one project share one agent process; other identities too (FR-25)', async () => {
  const gw = await startGateway();
  try {
    const a = (await connect(gw.url, auth())).ws;
    const b = (await connect(gw.url, auth())).ws;
    const c = (await connect(gw.url, auth(OTHER_TOKEN))).ws;
    await useProject(gw, a);
    await rpc(b, 'session/new', { cwd: gw.dirs.project, mcpServers: [] });
    await rpc(c, 'session/new', { cwd: gw.dirs.project, mcpServers: [] });
    const pids = await Promise.all([a, b, c].map(async (ws) => (await rpc(ws, '_test/state', {})).result.pid));
    assert.equal(new Set(pids).size, 1);
    assert.equal(gw.spawned(), 1);
    for (const ws of [a, b, c]) ws.close();
  } finally {
    await gw.stop();
  }
});

test('each socket gets its own responses, even when both use the same request id', async () => {
  const gw = await startGateway();
  try {
    const a = (await connect(gw.url, auth())).ws;
    const b = (await connect(gw.url, auth())).ws;
    await useProject(gw, a);
    await rpc(b, 'session/new', { cwd: gw.dirs.project, mcpServers: [] });
    const seenA = collect(a);
    const seenB = collect(b);
    for (let i = 0; i < 20; i++) {
      a.send(JSON.stringify({ jsonrpc: '2.0', id: i, method: '_test/echo', params: { from: 'a', i } }));
      b.send(JSON.stringify({ jsonrpc: '2.0', id: i, method: '_test/echo', params: { from: 'b', i } }));
    }
    for (let t = 0; t < 100 && (seenA.length < 20 || seenB.length < 20); t++) await sleep(20);
    assert.deepEqual(seenA.map((m) => [m.id, m.result.from, m.result.i]), Array.from({ length: 20 }, (_, i) => [i, 'a', i]));
    assert.deepEqual(seenB.map((m) => [m.id, m.result.from, m.result.i]), Array.from({ length: 20 }, (_, i) => [i, 'b', i]));
    a.close();
    b.close();
  } finally {
    await gw.stop();
  }
});

test('closing a socket does not stop the agent; a new socket continues the session by id', async () => {
  const gw = await startGateway();
  try {
    const a = (await connect(gw.url, auth())).ws;
    const { sessionId } = await useProject(gw, a);
    const pid = (await rpc(a, '_test/state', {})).result.pid;
    a.close();
    await nextClose(a);
    await gw.waitForAudit((l) => l.event === 'disconnect');
    await sleep(200);
    assert.equal(gw.audit.some((l) => l.event === 'agent_exit'), false, 'the agent keeps running');

    const b = (await connect(gw.url, auth())).ws;
    const seen = collect(b);
    const res = await rpc(b, 'session/prompt', { sessionId, prompt: [{ type: 'text', text: 'again' }] });
    assert.equal(res.result.stopReason, 'end_turn');
    assert.ok(seen.some((m) => m.params?.update?.content?.text === 'echo: again'), 'updates reach the socket attached by sessionId');
    assert.equal((await rpc(b, '_test/state', {})).result.pid, pid);
    b.close();
  } finally {
    await gw.stop();
  }
});

test('when the agent exits, pending requests fail, sockets stay open, and the next request restarts it', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    await useProject(gw, ws);
    const first = (await rpc(ws, '_test/state', {})).result.pid;
    const res = await rpc(ws, '_test/exit', {});
    assert.deepEqual(res.error, { code: -32000, message: 'agent exited' });
    const exit = await gw.waitForAudit((l) => l.event === 'agent_exit');
    assert.equal(exit.exitCode, 3);
    const second = (await rpc(ws, '_test/state', {})).result.pid;
    assert.notEqual(second, first);
    assert.equal(gw.spawned(), 2);
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('D-015: a second gateway on the same project is refused while the first one\'s agent runs', async () => {
  const dirs = await makeDirs();
  const config = rawConfig(dirs.root);
  const gw1 = await spawnGateway(config, { configDir: dirs.base });
  let gw2;
  try {
    const a = (await connect(gw1.url, auth())).ws;
    await useProject(gw1, a, dirs.project);
    gw2 = await spawnGateway(config); // same stateDir, so the same project and HOME
    const b = (await connect(gw2.url, auth())).ws;
    const refused = await rpc(b, 'session/new', { cwd: dirs.project, mcpServers: [] });
    assert.equal(refused.error.code, -32000);
    assert.match(refused.error.message, /already running/);
    await gw2.waitForAudit((l) => l.event === 'agent_error' && l.reason === 'locked');
    // When the first gateway stops (and its agent exits), the second one can start the agent.
    a.close();
    await gw1.stop();
    const ok = await rpc(b, 'session/new', { cwd: dirs.project, mcpServers: [] });
    assert.match(ok.result.sessionId, /^sess-/);
    b.close();
  } finally {
    await gw1.stop();
    await gw2?.stop();
    await dirs.cleanup();
  }
});

test('the gateway answers initialize itself, with the captured agent capabilities and its own _meta', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    const before = await rpc(ws, 'initialize', { protocolVersion: 1, clientCapabilities: { fs: { readTextFile: true } } });
    assert.equal(before.result.agentInfo.version, '2.0.9', 'the Bob 2.0.9 fixture before any agent ran');
    assert.deepEqual(before.result._meta['agmente/gateway'], { version: '0.3.0-dev', extensions: ['projects', 'sessions', 'approvals', 'git', 'push'] });
    await gw.settle();
    assert.equal(gw.spawned(), 0, 'initialize starts no agent');
    await useProject(gw, ws);
    const received = (await rpc(ws, '_test/received', {})).result.methods;
    assert.deepEqual(received.filter((m) => m === 'initialize'), ['initialize'], "only the gateway's own initialize reached the agent");
    const captured = JSON.parse(readFileSync(join(gw.config.stateDir, 'agent-initialize.json'), 'utf8'));
    assert.equal(captured.agentInfo.name, 'bob-shell');
    const after = await rpc(ws, 'initialize', { protocolVersion: 1, clientCapabilities: {} });
    assert.deepEqual(after.result.agentCapabilities, captured.agentCapabilities);
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('a permission request goes to every socket attached to the session; the first answer wins (D-009)', async () => {
  const gw = await startGateway();
  try {
    const a = (await connect(gw.url, auth())).ws;
    const b = (await connect(gw.url, auth())).ws;
    const { sessionId } = await useProject(gw, a);
    await rpc(b, '_test/echo', { sessionId }); // b attaches to the session by sending for it
    const seenA = collect(a);
    const seenB = collect(b);
    a.send(JSON.stringify({ jsonrpc: '2.0', id: 'turn', method: 'session/prompt', params: { sessionId, prompt: [{ type: 'text', text: 'go [permission]' }] } }));
    const reqA = await waitFor(seenA, (m) => m.method === 'session/request_permission');
    const reqB = await waitFor(seenB, (m) => m.method === 'session/request_permission');
    assert.equal(reqA.id, reqB.id);
    assert.match(reqA.id, /^agmente-perm-\d+$/, 'a gateway id, not the agent id');
    b.send(JSON.stringify({ jsonrpc: '2.0', id: reqB.id, result: { outcome: { outcome: 'selected', optionId: 'cancel' } } }));
    // The two sockets are read independently, so send a's answer only once b's has reached the agent.
    for (const t0 = Date.now(); (await rpc(a, '_test/permissions', {})).result.answers.length === 0; await sleep(10)) {
      if (Date.now() - t0 > 5000) throw new Error("b's answer never reached the agent");
    }
    a.send(JSON.stringify({ jsonrpc: '2.0', id: reqA.id, result: { outcome: { outcome: 'selected', optionId: 'proceed_once' } } }));
    const done = await waitFor(seenA, (m) => m.id === 'turn');
    assert.equal(done.result.stopReason, 'end_turn');
    await gw.waitForAudit((l) => l.event === 'response_dropped');
    const answers = (await rpc(a, '_test/permissions', {})).result.answers;
    assert.equal(answers.length, 1);
    assert.equal(answers[0].response.result.outcome.optionId, 'cancel', "b's answer came first and won");
    assert.notEqual(answers[0].requestId, reqA.id);
    a.close();
    b.close();
  } finally {
    await gw.stop();
  }
});

test('routing: unknown sessions, unregistered folders and a socket with no project are refused', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    assert.deepEqual((await rpc(ws, '_test/echo', {})).error, { code: -32602, message: 'no project: send a cwd inside a registered project or a sessionId' });
    assert.deepEqual((await rpc(ws, 'session/prompt', { sessionId: 'sess-nope', prompt: [] })).error, { code: -32602, message: 'unknown session' });
    assert.deepEqual((await rpc(ws, 'session/new', { mcpServers: [] })).error, { code: -32602, message: 'session/new needs a cwd inside a registered project' });
    const { sessionId } = await useProject(gw, ws);
    // A session cannot be moved to another project by sending another cwd.
    const other = join(gw.dirs.root, 'other');
    await (await import('node:fs/promises')).mkdir(other);
    await rpc(ws, '_agmente/projects/create', { name: 'other', path: other });
    assert.deepEqual((await rpc(ws, 'session/load', { sessionId, cwd: other, mcpServers: [] })).error, { code: -32602, message: 'the session belongs to another project' });
    await gw.settle();
    assert.equal(gw.spawned(), 1, 'no refused request started an agent');
    assert.equal(existsSync(join(gw.config.stateDir, 'gateway.db')), true);
    ws.close();
  } finally {
    await gw.stop();
  }
});
