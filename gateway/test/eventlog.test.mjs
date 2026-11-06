// Event log (FR-18, NFR-7, T-20, PLAN 3.5, D-027). The tests read gateway.db read-only with
// node:sqlite, as an outside observer of the deployed file; no gateway code is imported.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { join } from 'node:path';
import { auth, connect, makeDirs, rawConfig, rpc, sleep, spawnGateway, startGateway, useProject } from './helpers.mjs';

function readEvents(stateDir, sessionId) {
  const db = new DatabaseSync(join(stateDir, 'gateway.db'), { readOnly: true });
  try {
    const rows = sessionId
      ? db.prepare('SELECT session_id, seq, kind, message FROM events WHERE session_id = ? ORDER BY seq').all(sessionId)
      : db.prepare('SELECT session_id, seq, kind, message FROM events ORDER BY session_id, seq').all();
    return rows.map((r) => ({ ...r, seq: Number(r.seq), message: JSON.parse(r.message) }));
  } finally {
    db.close();
  }
}

const collect = (ws) => {
  const seen = [];
  ws.on('message', (d) => seen.push(JSON.parse(d.toString())));
  return seen;
};

test('FR-18: a turn is logged in order with seq 1, 2, 3...: turn_started, the updates, turn_ended', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    const { sessionId } = await useProject(gw, ws);
    const seen = collect(ws);
    const prompt = [{ type: 'text', text: 'hi [chunks:3]' }];
    assert.equal((await rpc(ws, 'session/prompt', { sessionId, prompt })).result.stopReason, 'end_turn');
    const events = readEvents(gw.config.stateDir, sessionId);
    assert.deepEqual(events.map((e) => e.seq), [1, 2, 3, 4, 5, 6]);
    assert.deepEqual(events.map((e) => e.kind), ['turn_started', 'update', 'update', 'update', 'update', 'turn_ended']);
    assert.deepEqual(events[0].message, { jsonrpc: '2.0', method: '_agmente/turn_started', params: { sessionId, prompt } });
    assert.deepEqual(events[5].message, { jsonrpc: '2.0', method: '_agmente/turn_ended', params: { sessionId, stopReason: 'end_turn' } });
    // The logged updates are exactly what the phone received, in the same order.
    const updates = seen.filter((m) => m.method === 'session/update');
    assert.deepEqual(events.filter((e) => e.kind === 'update').map((e) => e.message), updates);
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('each session has its own sequence; messages without a session and responses are not logged', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    const { sessionId: s1 } = await useProject(gw, ws);
    const s2 = (await rpc(ws, 'session/new', { cwd: gw.dirs.project, mcpServers: [] })).result.sessionId;
    await rpc(ws, 'session/prompt', { sessionId: s1, prompt: [{ type: 'text', text: 'one' }] });
    await rpc(ws, 'session/prompt', { sessionId: s2, prompt: [{ type: 'text', text: 'two' }] });
    await rpc(ws, 'session/prompt', { sessionId: s1, prompt: [{ type: 'text', text: 'three' }] });
    // A notification with no session, and plain responses, are not session events.
    const one = JSON.stringify({ jsonrpc: '2.0', method: '_test/one', params: { v: 1 } });
    await rpc(ws, '_test/chunks', { parts: [`${one}\n`] });
    await rpc(ws, '_test/echo', { sessionId: s1 });
    const all = readEvents(gw.config.stateDir);
    const of = (sid) => all.filter((e) => e.session_id === sid);
    assert.deepEqual(of(s1).map((e) => e.seq), Array.from({ length: of(s1).length }, (_, i) => i + 1));
    assert.deepEqual(of(s2).map((e) => e.seq), Array.from({ length: of(s2).length }, (_, i) => i + 1));
    assert.deepEqual(of(s1).filter((e) => e.kind === 'turn_started').map((e) => e.message.params.prompt[0].text), ['one', 'three']);
    assert.deepEqual(of(s2).filter((e) => e.kind === 'turn_started').map((e) => e.message.params.prompt[0].text), ['two']);
    assert.deepEqual([...new Set(all.map((e) => e.session_id))].sort(), [s1, s2].sort());
    assert.equal(all.some((e) => e.message.method === '_test/one' || e.message.result), false);
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('a permission request is logged as phones see it, under the gateway id', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    const { sessionId } = await useProject(gw, ws);
    const seen = collect(ws);
    ws.send(JSON.stringify({ jsonrpc: '2.0', id: 'turn', method: 'session/prompt', params: { sessionId, prompt: [{ type: 'text', text: '[permission]' }] } }));
    let req;
    for (let i = 0; i < 100 && !(req = seen.find((m) => m.method === 'session/request_permission')); i++) await sleep(20);
    const logged = readEvents(gw.config.stateDir, sessionId).find((e) => e.kind === 'permission_request');
    assert.deepEqual(logged.message, req);
    assert.match(logged.message.id, /^agmente-perm-\d+$/);
    ws.send(JSON.stringify({ jsonrpc: '2.0', id: req.id, result: { outcome: { outcome: 'selected', optionId: 'cancel' } } }));
    for (let i = 0; i < 100 && !seen.find((m) => m.id === 'turn'); i++) await sleep(20);
    assert.equal(readEvents(gw.config.stateDir, sessionId).at(-1).kind, 'turn_ended');
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('a turn cut short by the agent exiting ends with turn_ended and the error', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    const { sessionId } = await useProject(gw, ws);
    const turn = rpc(ws, 'session/prompt', { sessionId, prompt: [{ type: 'text', text: 'long [chunks:50][slow:40]' }] });
    await sleep(300);
    const { pid } = (await rpc(ws, '_test/state', {})).result;
    process.kill(pid, 'SIGKILL');
    assert.deepEqual((await turn).error, { code: -32000, message: 'agent exited' });
    const last = readEvents(gw.config.stateDir, sessionId).at(-1);
    assert.deepEqual(last.message, { jsonrpc: '2.0', method: '_agmente/turn_ended', params: { sessionId, error: { code: -32000, message: 'agent exited' } } });
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('T-20: after SIGKILL of the gateway and a restart, every event a phone received is in the log', async () => {
  const dirs = await makeDirs();
  const config = rawConfig(dirs.root);
  let gw = await spawnGateway(config, { configDir: dirs.base });
  try {
    const { ws } = await connect(gw.url, auth());
    const { sessionId } = await useProject(gw, ws, dirs.project);
    const seen = collect(ws);
    ws.send(JSON.stringify({ jsonrpc: '2.0', id: 'long', method: 'session/prompt', params: { sessionId, prompt: [{ type: 'text', text: 'x [chunks:3000][slow:1]' }] } }));
    const updates = () => seen.filter((m) => m.method === 'session/update' && m.params.sessionId === sessionId);
    for (let i = 0; i < 500 && updates().length < 300; i++) await sleep(10);
    process.kill(gw.pid, 'SIGKILL');
    await gw.stop(); // waits for the exit
    const received = updates();
    assert.ok(received.length >= 300, `received ${received.length}`);

    gw = await spawnGateway(config, { configDir: dirs.base });
    const events = readEvents(config.stateDir, sessionId);
    assert.deepEqual(events.map((e) => e.seq), Array.from({ length: events.length }, (_, i) => i + 1), 'no gap');
    const logged = events.filter((e) => e.kind === 'update').map((e) => e.message);
    assert.ok(logged.length >= received.length, `logged ${logged.length}, received ${received.length}`);
    assert.deepEqual(logged.slice(0, received.length), received, 'each received event is logged, in order');
    // The restarted gateway serves the same project.
    const again = (await connect(gw.url, auth())).ws;
    assert.equal((await rpc(again, '_agmente/projects/list', {})).result.projects.length, 1);
    again.close();
    console.log(`# T-20: received ${received.length} updates before SIGKILL; logged ${logged.length}; ${events.length} events, seq 1..${events.length}`);
  } finally {
    await gw.stop();
    await dirs.cleanup();
  }
});
