// Load and resume guard (FR-20, T-21, PLAN 3.7, D-029).
// The fake agent refuses session/load and session/resume while a turn runs and rebuilds the session
// (replaying its history) when idle, as Bob 2.0.9 does (F-12). The gateway must never send either
// for a session live in the agent: it answers them itself and replays the event log to that socket.
// After an agent restart it lets one load through, and the agent's replay stays out of the log.
// A fake-agent turn with [chunks:N] logs turn_started, N chunk updates, turn_ended, and on a
// session's first turn a session_info_update: N + 3 events, N + 2 for later turns.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { join } from 'node:path';
import { auth, connect, rpc, sleep, startGateway, useProject } from './helpers.mjs';

function readEvents(stateDir, sessionId) {
  const db = new DatabaseSync(join(stateDir, 'gateway.db'), { readOnly: true });
  try {
    return db.prepare('SELECT seq, kind, message FROM events WHERE session_id = ? ORDER BY seq').all(sessionId)
      .map((r) => ({ seq: Number(r.seq), kind: r.kind, message: JSON.parse(r.message) }));
  } finally {
    db.close();
  }
}
const collect = (ws) => {
  const seen = [];
  ws.on('message', (d) => seen.push(JSON.parse(d.toString())));
  return seen;
};
async function until(pred, what, ms = 15000) {
  for (const t0 = Date.now(); Date.now() - t0 < ms; await sleep(10)) if (pred()) return;
  throw new Error(`timed out waiting for ${what}`);
}
const updates = (seen, sid) => seen.filter((m) => m.method === 'session/update' && m.params.sessionId === sid).map((m) => m.params.update);
const textOf = (us, kind) => us.filter((u) => u.sessionUpdate === kind).map((u) => u.content.text).join('');
/** Methods the current agent process received from the gateway. */
const received = async (ws) => (await rpc(ws, '_test/received', {})).result.methods;
const reopens = (methods) => methods.filter((m) => m === 'session/load' || m === 'session/resume');
/** What a phone that does not subscribe should get from the log: prompts as user chunks, updates as they were. */
function expectedHistory(logged) {
  return logged.flatMap((e) => {
    if (e.kind === 'update') return [e.message.params.update];
    if (e.kind === 'turn_started') return e.message.params.prompt.map((content) => ({ sessionUpdate: 'user_message_chunk', content }));
    return [];
  });
}
const loadParams = (gw, sessionId) => ({ sessionId, cwd: gw.dirs.project, mcpServers: [] });

test('T-21: reopening a session while its turn runs: no load reaches the agent, the turn completes, history is replayed once', async () => {
  const gw = await startGateway();
  try {
    const a = (await connect(gw.url, auth())).ws;
    const { sessionId, newResult } = await (async () => {
      await rpc(a, '_agmente/projects/create', { name: 'test', path: gw.dirs.project });
      const res = await rpc(a, 'session/new', { cwd: gw.dirs.project, mcpServers: [] });
      return { sessionId: res.result.sessionId, newResult: res.result };
    })();
    const text = 'long [chunks:300][slow:5]';
    const turn = rpc(a, 'session/prompt', { sessionId, prompt: [{ type: 'text', text }] });
    await until(() => readEvents(gw.config.stateDir, sessionId).length >= 30, '30 logged events');

    const results = {};
    const seen = {};
    for (const method of ['session/load', 'session/resume']) {
      const ws = (await connect(gw.url, auth())).ws;
      seen[method] = collect(ws);
      const res = await rpc(ws, method, loadParams(gw, sessionId));
      results[method] = res;
      assert.equal(seen[method][0].id, res.id, `${method}: the response comes before the history`);
    }
    const { sessionId: _, ...cached } = newResult;
    for (const res of Object.values(results)) assert.deepEqual(res.result, cached, 'answered with the cached result, not a refusal');

    assert.deepEqual((await turn).result, { stopReason: 'end_turn' }, 'the turn completes');
    for (const method of Object.keys(seen)) {
      await until(() => updates(seen[method], sessionId).some((u) => u.sessionUpdate === 'session_info_update'), `${method}: the title update`);
      const us = updates(seen[method], sessionId);
      assert.equal(textOf(us, 'user_message_chunk'), text, `${method}: the prompt once`);
      assert.equal(textOf(us, 'agent_message_chunk'), `echo: ${text}`, `${method}: the reply once, no gap, no duplicate`);
      assert.deepEqual(us, expectedHistory(readEvents(gw.config.stateDir, sessionId)), `${method}: history then live, in log order`);
    }
    assert.deepEqual(reopens(await received(a)), [], 'the agent received no session/load or session/resume');
    const logged = readEvents(gw.config.stateDir, sessionId);
    assert.equal(logged.length, 303, 'the turn and nothing else');
    assert.equal(logged.filter((e) => ['user_message_chunk', 'available_commands_update'].includes(e.message.params?.update?.sessionUpdate)).length, 0, 'no replayed history in the log');
    assert.equal(gw.spawned(), 1);
    a.close();
  } finally {
    await gw.stop();
  }
});

test('T-21: reopening an idle session: answered with the current mode, history from the log, nothing logged, nothing sent to the agent', async () => {
  const gw = await startGateway();
  try {
    const a = (await connect(gw.url, auth())).ws;
    const { sessionId } = await useProject(gw, a);
    await rpc(a, 'session/prompt', { sessionId, prompt: [{ type: 'text', text: 'hi [chunks:3]' }] });
    assert.deepEqual((await rpc(a, 'session/set_mode', { sessionId, modeId: 'plan' })).result, {});
    await until(() => readEvents(gw.config.stateDir, sessionId).length === 7, '7 events');
    const before = readEvents(gw.config.stateDir, sessionId);

    for (const method of ['session/load', 'session/resume', 'session/load']) {
      const ws = (await connect(gw.url, auth())).ws;
      const seen = collect(ws);
      const res = await rpc(ws, method, loadParams(gw, sessionId));
      assert.equal(res.result.modes.currentModeId, 'plan', `${method}: the cached mode follows set_mode`);
      assert.equal(res.result.modes.availableModes.length, 3);
      await until(() => updates(seen, sessionId).length === 6, `${method}: 6 history updates`);
      assert.deepEqual(updates(seen, sessionId), expectedHistory(before));
      assert.deepEqual(updates(seen, sessionId).map((u) => u.sessionUpdate),
        ['user_message_chunk', 'agent_message_chunk', 'agent_message_chunk', 'agent_message_chunk', 'session_info_update', 'current_mode_update']);
      assert.equal(seen.some((m) => m.method?.startsWith('_agmente/')), false, 'no gateway turn markers on a plain socket');
      ws.close();
    }
    // A load sent as a notification has nothing to answer and is dropped.
    a.send(JSON.stringify({ jsonrpc: '2.0', method: 'session/load', params: loadParams(gw, sessionId) }));
    // A subscriber already has the events: it gets the response and no plain history.
    const s = (await connect(gw.url, auth())).ws;
    const seenS = collect(s);
    await rpc(s, '_agmente/sessions/subscribe', { sessionId, afterSeq: 7 });
    assert.equal((await rpc(s, 'session/load', loadParams(gw, sessionId))).result.modes.currentModeId, 'plan');
    // The reopened socket gets live updates as plain messages, and the prompt works.
    const b = (await connect(gw.url, auth())).ws;
    const seenB = collect(b);
    await rpc(b, 'session/load', loadParams(gw, sessionId));
    assert.deepEqual((await rpc(b, 'session/prompt', { sessionId, prompt: [{ type: 'text', text: 'again' }] })).result, { stopReason: 'end_turn' });
    await until(() => textOf(updates(seenB, sessionId), 'agent_message_chunk').endsWith('echo: again'), 'live reply on B');
    await sleep(100);
    assert.equal(updates(seenS, sessionId).length, 0, 'the subscriber got no plain copies');
    assert.equal(seenS.filter((m) => m.method === '_agmente/event').length, 3, 'the subscriber got the new turn as events');

    assert.deepEqual(reopens(await received(a)), [], 'the agent received no session/load or session/resume');
    assert.equal(readEvents(gw.config.stateDir, sessionId).length, 10, 'the 7 events and the new turn only');
    for (const ws of [a, s, b]) ws.close();
  } finally {
    await gw.stop();
  }
});

test('T-21: after an agent restart, one load reaches the agent; its replay goes to that phone and stays out of the log', async () => {
  const gw = await startGateway();
  try {
    const a = (await connect(gw.url, auth())).ws;
    const { sessionId } = await useProject(gw, a);
    await rpc(a, 'session/prompt', { sessionId, prompt: [{ type: 'text', text: 'hi [chunks:3]' }] });
    assert.equal((await rpc(a, '_test/exit', {})).error.code, -32000);
    const before = readEvents(gw.config.stateDir, sessionId);
    assert.equal(before.length, 6);

    // Two phones reopen at once; one also prompts straight after its load, without waiting.
    const b = (await connect(gw.url, auth())).ws;
    const c = (await connect(gw.url, auth())).ws;
    const seenB = collect(b);
    const seenC = collect(c);
    const [resB, resC, turn] = await Promise.all([
      rpc(b, 'session/load', loadParams(gw, sessionId)),
      rpc(c, 'session/load', loadParams(gw, sessionId)),
      (async () => { await sleep(0); return rpc(b, 'session/prompt', { sessionId, prompt: [{ type: 'text', text: 'again' }] }); })(),
    ]);
    assert.equal(resB.result.modes.currentModeId, 'agent');
    assert.deepEqual(resC.result, resB.result);
    assert.deepEqual(turn.result, { stopReason: 'end_turn' }, 'the prompt sent during the load ran after it');
    assert.equal(gw.spawned(), 2);
    assert.deepEqual(reopens(await received(a)), ['session/load'], 'the new agent received exactly one load');

    // One phone got the agent's own replay (it starts with available_commands_update); the other got the log.
    await until(() => [seenB, seenC].every((s) => textOf(updates(s, sessionId), 'agent_message_chunk').includes('echo: hi [chunks:3]')), 'history on both');
    const fromAgent = [seenB, seenC].filter((s) => updates(s, sessionId)[0]?.sessionUpdate === 'available_commands_update');
    assert.equal(fromAgent.length, 1, 'exactly one phone got the agent replay');
    for (const s of [seenB, seenC]) {
      const us = updates(s, sessionId);
      assert.equal(us.filter((u) => u.sessionUpdate === 'available_commands_update').length, s === fromAgent[0] ? 1 : 0);
      assert.ok(textOf(us, 'user_message_chunk').startsWith('hi [chunks:3]'), 'the old prompt once');
    }

    const logged = readEvents(gw.config.stateDir, sessionId);
    assert.deepEqual(logged.slice(0, 6), before);
    assert.deepEqual(logged.slice(6).map((e) => e.kind), ['turn_started', 'update', 'turn_ended'], 'only the new turn was logged');
    assert.equal(logged.filter((e) => ['user_message_chunk', 'available_commands_update'].includes(e.message.params?.update?.sessionUpdate)).length, 0, 'no replayed history in the log');

    // The session is live again: a later reopen is answered by the gateway.
    const d = (await connect(gw.url, auth())).ws;
    assert.equal((await rpc(d, 'session/resume', loadParams(gw, sessionId))).result.modes.currentModeId, 'agent');
    assert.deepEqual(reopens(await received(a)), ['session/load']);
    for (const ws of [a, b, c, d]) ws.close();
  } finally {
    await gw.stop();
  }
});

test('T-21: a phone that reopens during a permission request gets the open request and can answer it', async () => {
  const gw = await startGateway();
  try {
    const a = (await connect(gw.url, auth())).ws;
    const { sessionId } = await useProject(gw, a);
    const seenA = collect(a);
    const turn = rpc(a, 'session/prompt', { sessionId, prompt: [{ type: 'text', text: 'run it [permission]' }] });
    await until(() => seenA.some((m) => m.method === 'session/request_permission'), 'the permission request on A');

    const b = (await connect(gw.url, auth())).ws;
    const seenB = collect(b);
    await rpc(b, 'session/load', loadParams(gw, sessionId));
    await until(() => seenB.some((m) => m.method === 'session/request_permission'), 'the permission request on B');
    const req = seenB.find((m) => m.method === 'session/request_permission');
    assert.equal(req.id, seenA.find((m) => m.method === 'session/request_permission').id, 'the same gateway id');
    b.send(JSON.stringify({ jsonrpc: '2.0', id: req.id, result: { outcome: { outcome: 'selected', optionId: 'proceed_once' } } }));
    assert.deepEqual((await turn).result, { stopReason: 'end_turn' });

    // Once answered, it is not replayed.
    const c = (await connect(gw.url, auth())).ws;
    const seenC = collect(c);
    await rpc(c, 'session/load', loadParams(gw, sessionId));
    await until(() => updates(seenC, sessionId).some((u) => u.sessionUpdate === 'session_info_update'), 'history on C');
    await sleep(100);
    assert.equal(seenC.some((m) => m.method === 'session/request_permission'), false);
    assert.deepEqual(reopens(await received(a)), []);
    for (const ws of [a, b, c]) ws.close();
  } finally {
    await gw.stop();
  }
});
