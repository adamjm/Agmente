// The approval queue (FR-22, NFR-10, T-22, T-23, PLAN 3.9, D-009, D-031).
// The fake agent's [permission] request offers proceed_once (allow_once), proceed_always
// (allow_always) and cancel (reject_once); [permission:allow-only] offers only the two allows.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { join } from 'node:path';
import { auth, connect, makeDirs, OTHER_TOKEN, rawConfig, rpc, sleep, spawnGateway, startGateway, useProject } from './helpers.mjs';

const collect = (ws) => {
  const seen = [];
  ws.on('message', (d) => seen.push(JSON.parse(d.toString())));
  return seen;
};
async function until(pred, what, ms = 10000) {
  for (const t0 = Date.now(); Date.now() - t0 < ms; await sleep(10)) if (await pred()) return;
  throw new Error(`timed out waiting for ${what}`);
}
function query(stateDir, sql, ...args) {
  const db = new DatabaseSync(join(stateDir, 'gateway.db'), { readOnly: true });
  try {
    return db.prepare(sql).all(...args);
  } finally {
    db.close();
  }
}
const approvalRow = (gw, id) => query(gw.config.stateDir, 'SELECT * FROM approvals WHERE id = ?', id)[0];
const agentAnswers = async (ws) => (await rpc(ws, '_test/permissions', {})).result.answers;
const answer = (ws, params) => rpc(ws, '_agmente/approvals/answer', params);
const ALLOW_KINDS = new Set(['allow_once', 'allow_always']);

/** Start a [permission] turn on `ws` and wait until `seen` has the request. Returns { turn, req }. */
async function askPermission(ws, seen, sessionId, text = 'run it [permission]') {
  const before = seen.filter((m) => m.method === 'session/request_permission').length;
  const turn = rpc(ws, 'session/prompt', { sessionId, prompt: [{ type: 'text', text }] });
  await until(() => seen.filter((m) => m.method === 'session/request_permission').length > before, 'the permission request');
  return { turn, req: seen.filter((m) => m.method === 'session/request_permission').at(-1) };
}

test('T-22: two devices answer one request: the first answer goes to the agent, the second gets "answered elsewhere"', async () => {
  const gw = await startGateway();
  try {
    const a = (await connect(gw.url, auth())).ws;
    const b = (await connect(gw.url, auth(OTHER_TOKEN))).ws;
    const { sessionId } = await useProject(gw, a);
    await rpc(b, '_test/echo', { sessionId });
    const seenA = collect(a);
    const seenB = collect(b);

    // Both through the answer method.
    let { turn, req } = await askPermission(a, seenA, sessionId);
    await until(() => seenB.some((m) => m.id === req.id), 'the request on B');
    assert.deepEqual((await answer(a, { approvalId: req.id, optionId: 'cancel' })).result, {});
    assert.deepEqual((await answer(b, { approvalId: req.id, optionId: 'proceed_once' })).error, { code: -32001, message: 'answered elsewhere' });
    assert.deepEqual((await turn).result, { stopReason: 'end_turn' });
    let answers = await agentAnswers(a);
    assert.equal(answers.length, 1, 'the agent got one answer');
    assert.deepEqual(answers[0].response.result.outcome, { outcome: 'selected', optionId: 'cancel' }, 'the first one');
    assert.equal(approvalRow(gw, req.id).answered_by, 'owner/phone');

    // A plain response after a method answer: dropped, and the phone is told why.
    ({ turn, req } = await askPermission(a, seenA, sessionId));
    assert.deepEqual((await answer(b, { approvalId: req.id, cancelled: true })).result, {});
    a.send(JSON.stringify({ jsonrpc: '2.0', id: req.id, result: { outcome: { outcome: 'selected', optionId: 'proceed_once' } } }));
    await until(() => seenA.some((m) => m.method === '_agmente/notice' && m.params.approvalId === req.id), 'the notice on A');
    assert.deepEqual(seenA.find((m) => m.method === '_agmente/notice').params, { approvalId: req.id, message: 'answered elsewhere' });
    await turn;
    answers = await agentAnswers(a);
    assert.equal(answers.length, 2);
    assert.deepEqual(answers[1].response.result.outcome, { outcome: 'cancelled' });
    assert.equal(approvalRow(gw, req.id).answered_by, 'guest/other');

    // Both at once, ten times: exactly one wins each time.
    for (let i = 0; i < 10; i += 1) {
      ({ turn, req } = await askPermission(a, seenA, sessionId));
      const [ra, rb] = await Promise.all([
        answer(a, { approvalId: req.id, optionId: 'cancel' }),
        answer(b, { approvalId: req.id, cancelled: true }),
      ]);
      assert.equal([ra, rb].filter((r) => r.result).length, 1, `round ${i}: one winner`);
      assert.deepEqual([ra, rb].find((r) => r.error).error, { code: -32001, message: 'answered elsewhere' });
      await turn;
    }
    assert.equal((await agentAnswers(a)).length, 12, 'one agent answer per request');
    for (const ws of [a, b]) ws.close();
  } finally {
    await gw.stop();
  }
});

test('T-23: with no answer past the timeout the agent gets a reject option, or cancelled when there is none; never an allow', async () => {
  const gw = await startGateway({ limits: { approvalTimeoutSeconds: 1 } });
  try {
    const a = (await connect(gw.url, auth())).ws;
    const { sessionId } = await useProject(gw, a);
    const seen = collect(a);
    await rpc(a, '_agmente/sessions/subscribe', { sessionId, afterSeq: 0 });

    // A reject option lets the turn go on without the tool; a cancelled outcome cancels the turn (ACP).
    for (const [text, want, stopReason] of [
      ['run it [permission]', { outcome: 'selected', optionId: 'cancel' }, 'end_turn'],
      ['run it [permission:allow-only]', { outcome: 'cancelled' }, 'cancelled'],
    ]) {
      const t0 = Date.now();
      const turn = rpc(a, 'session/prompt', { sessionId, prompt: [{ type: 'text', text }] });
      await until(() => seen.some((m) => m.method === '_agmente/event' && m.params.message.method === 'session/request_permission' && !seen.handled?.has(m.params.seq)), 'the request');
      const ev = seen.filter((m) => m.method === '_agmente/event' && m.params.message.method === 'session/request_permission').at(-1);
      const req = ev.params.message;
      seen.handled = new Set([...(seen.handled ?? []), ev.params.seq]);
      assert.deepEqual((await turn).result, { stopReason }, 'the turn completes after the timeout');
      const waited = Date.now() - t0;
      assert.ok(waited >= 900 && waited < 5000, `answered at the timeout: ${waited} ms`);

      const last = (await agentAnswers(a)).at(-1);
      assert.deepEqual(last.response.result.outcome, want, text);
      const picked = req.params.options.find((o) => o.optionId === last.response.result.outcome.optionId);
      assert.equal(picked === undefined || !ALLOW_KINDS.has(picked.kind), true, 'never an allow option');
      assert.equal(approvalRow(gw, req.id).answered_by, 'timeout');
      assert.deepEqual(JSON.parse(approvalRow(gw, req.id).outcome), want);
      await until(() => seen.some((m) => m.params?.message?.method === '_agmente/approval_answered' && m.params.message.params.approvalId === req.id), 'approval_answered');
      const closed = seen.find((m) => m.params?.message?.params?.approvalId === req.id && m.params.message.method === '_agmente/approval_answered').params.message.params;
      assert.deepEqual(closed, { sessionId, approvalId: req.id, answeredBy: 'timeout', outcome: want });

      // A late answer changes nothing.
      assert.deepEqual((await answer(a, { approvalId: req.id, optionId: 'proceed_once' })).error, { code: -32001, message: 'timed out' });
      a.send(JSON.stringify({ jsonrpc: '2.0', id: req.id, result: { outcome: { outcome: 'selected', optionId: 'proceed_once' } } }));
      await until(() => seen.some((m) => m.method === '_agmente/notice' && m.params.approvalId === req.id), 'the notice');
      assert.equal(seen.find((m) => m.method === '_agmente/notice' && m.params.approvalId === req.id).params.message, 'timed out');
    }
    await sleep(100);
    const all = await agentAnswers(a);
    assert.equal(all.length, 2, 'one answer per request, none from the late answers');
    for (const ans of all) assert.notEqual(ans.response.result.outcome.optionId?.startsWith('proceed'), true, 'never an allow');
    a.close();
  } finally {
    await gw.stop();
  }
});

test('pending lists open approvals; the answer method checks its params', async () => {
  const gw = await startGateway();
  try {
    const a = (await connect(gw.url, auth())).ws;
    const { project, sessionId } = await useProject(gw, a);
    const seen = collect(a);
    assert.deepEqual((await rpc(a, '_agmente/approvals/pending', {})).result, { approvals: [] });
    const { turn, req } = await askPermission(a, seen, sessionId);
    const pending = (await rpc(a, '_agmente/approvals/pending', {})).result.approvals;
    assert.equal(pending.length, 1);
    assert.deepEqual({ ...pending[0], since: 'x' }, {
      approvalId: req.id, sessionId, projectId: project.id, toolCall: req.params.toolCall, options: req.params.options, since: 'x',
    });
    assert.match(pending[0].since, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/);

    const bad = [
      [{ optionId: 'cancel' }, -32602, 'approvalId is required'],
      [{ approvalId: req.id }, -32602, 'give exactly one of optionId and cancelled: true'],
      [{ approvalId: req.id, optionId: 'cancel', cancelled: true }, -32602, 'give exactly one of optionId and cancelled: true'],
      [{ approvalId: req.id, cancelled: false }, -32602, 'give exactly one of optionId and cancelled: true'],
      [{ approvalId: req.id, optionId: 'rm -rf' }, -32602, "optionId is not one of the request's options"],
      [{ approvalId: 'agmente-perm-999', optionId: 'cancel' }, -32602, 'unknown approval'],
    ];
    for (const [params, code, message] of bad) {
      assert.deepEqual((await answer(a, params)).error, { code, message }, JSON.stringify(params));
    }
    assert.equal((await rpc(a, '_agmente/approvals/pending', {})).result.approvals.length, 1, 'a refused answer leaves it open');
    assert.deepEqual((await answer(a, { approvalId: req.id, optionId: 'proceed_once' })).result, {});
    await turn;
    assert.deepEqual((await rpc(a, '_agmente/approvals/pending', {})).result, { approvals: [] });
    a.close();
  } finally {
    await gw.stop();
  }
});

test('session/cancel answers the open approval with cancelled; an agent exit closes it', async () => {
  const gw = await startGateway();
  try {
    const a = (await connect(gw.url, auth())).ws;
    const { sessionId } = await useProject(gw, a);
    const seen = collect(a);
    let { turn, req } = await askPermission(a, seen, sessionId);
    a.send(JSON.stringify({ jsonrpc: '2.0', method: 'session/cancel', params: { sessionId } }));
    assert.deepEqual((await turn).result, { stopReason: 'cancelled' });
    await until(() => approvalRow(gw, req.id).answered_by === 'cancel', 'closed by the cancel');
    assert.deepEqual(JSON.parse(approvalRow(gw, req.id).outcome), { outcome: 'cancelled' });
    const responses = (await rpc(a, '_test/responses', {})).result.responses;
    assert.ok(responses.some((r) => r.result?.outcome?.outcome === 'cancelled'), 'the agent received cancelled');
    assert.equal(responses.some((r) => r.result?.outcome?.outcome === 'selected'), false);
    assert.deepEqual((await rpc(a, '_agmente/approvals/pending', {})).result, { approvals: [] });

    ({ turn, req } = await askPermission(a, seen, sessionId));
    await rpc(a, '_test/exit', {});
    assert.equal((await turn).error.code, -32000);
    await until(() => approvalRow(gw, req.id).answered_by === 'agent_exit', 'closed by the exit');
    assert.deepEqual((await rpc(a, '_agmente/approvals/pending', {})).result, { approvals: [] });
    assert.deepEqual((await answer(a, { approvalId: req.id, optionId: 'proceed_once' })).error, { code: -32001, message: 'the agent exited' });
    a.close();
  } finally {
    await gw.stop();
  }
});

test('a gateway restart closes open approvals, and new approval ids do not repeat old ones', async () => {
  const dirs = await makeDirs();
  const config = rawConfig(dirs.root);
  let gw = await spawnGateway(config, { configDir: dirs.base });
  try {
    let a = (await connect(gw.url, auth())).ws;
    const { sessionId } = await useProject(gw, a, dirs.project);
    let seen = collect(a);
    const asked = await askPermission(a, seen, sessionId);
    asked.turn.catch(() => {}); // the socket dies with the gateway
    const first = asked.req;
    process.kill(gw.pid, 'SIGKILL'); // a crash: no shutdown path closes the approval
    await gw.stop();
    a.close();

    gw = await spawnGateway(config, { configDir: dirs.base });
    const stateDir = config.stateDir;
    const row = query(stateDir, 'SELECT answered_by FROM approvals WHERE id = ?', first.id)[0];
    assert.equal(row.answered_by, 'gateway_restart');
    a = (await connect(gw.url, auth())).ws;
    seen = collect(a);
    await rpc(a, 'session/load', { sessionId, cwd: dirs.project, mcpServers: [] });
    const { turn, req } = await askPermission(a, seen, sessionId);
    assert.ok(Number(req.id.split('-').at(-1)) > Number(first.id.split('-').at(-1)), `${req.id} after ${first.id}`);
    assert.deepEqual((await answer(a, { approvalId: first.id, optionId: 'cancel' })).error, { code: -32001, message: 'the agent exited' });
    assert.deepEqual((await answer(a, { approvalId: req.id, optionId: 'cancel' })).result, {});
    await turn;
    a.close();
  } finally {
    await gw.stop();
    await dirs.cleanup();
  }
});
