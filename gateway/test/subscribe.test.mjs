// Subscribe and replay (FR-19, NFR-6, T-18, T-19, PLAN 3.6, D-028).
// The tests read gateway.db read-only with node:sqlite to compare what phones received with the log.
// A fake-agent turn with [chunks:N] logs turn_started, N chunk updates, turn_ended, and on a session's
// first turn also a session_info_update: N + 3 events for the first turn, N + 2 after that.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { join } from 'node:path';
import { auth, connect, nextClose, rpc, sleep, startGateway, useProject } from './helpers.mjs';

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
const eventsOf = (seen, sid) => seen.filter((m) => m.method === '_agmente/event' && m.params.sessionId === sid);
const seqs = (evs) => evs.map((e) => e.params.seq);
const range = (from, to) => Array.from({ length: Math.max(0, to - from + 1) }, (_, i) => from + i);
async function until(pred, what, ms = 10000) {
  for (const t0 = Date.now(); Date.now() - t0 < ms; await sleep(10)) if (pred()) return;
  throw new Error(`timed out waiting for ${what}`);
}
const ended = (seen, sid) => eventsOf(seen, sid).some((e) => e.params.message.method === '_agmente/turn_ended');
/** Wait until the log's last event for the session is turn_ended. */
async function untilLoggedEnd(gw, sid, ms = 20000) {
  await until(() => readEvents(gw.config.stateDir, sid).at(-1)?.kind === 'turn_ended', 'turn_ended in the log', ms);
}

test('subscribe answers {headSeq} first, then replays each logged event as _agmente/event', async () => {
  const gw = await startGateway();
  try {
    const a = (await connect(gw.url, auth())).ws;
    const { sessionId } = await useProject(gw, a);
    await rpc(a, 'session/prompt', { sessionId, prompt: [{ type: 'text', text: 'hi [chunks:3]' }] });
    const b = (await connect(gw.url, auth())).ws;
    const seen = collect(b);
    const res = await rpc(b, '_agmente/sessions/subscribe', { sessionId, afterSeq: 0 });
    assert.deepEqual(res.result, { headSeq: 6 });
    await until(() => eventsOf(seen, sessionId).length === 6, '6 events');
    assert.equal(seen[0].id, res.id, 'the response comes before any event');
    const logged = readEvents(gw.config.stateDir, sessionId);
    assert.deepEqual(eventsOf(seen, sessionId).map((e) => e.params), logged.map((e) => ({ sessionId, seq: e.seq, message: e.message })));
    assert.deepEqual(Object.keys(seen[1]), ['jsonrpc', 'method', 'params']);
    assert.equal(seen.some((m) => m.method === 'session/update'), false, 'a subscriber gets no plain copies');
    for (const ws of [a, b]) ws.close();
  } finally {
    await gw.stop();
  }
});

test('afterSeq selects where the replay starts; at or past the head nothing is replayed', async () => {
  const gw = await startGateway();
  try {
    const a = (await connect(gw.url, auth())).ws;
    const { sessionId } = await useProject(gw, a);
    await rpc(a, 'session/prompt', { sessionId, prompt: [{ type: 'text', text: 'hi [chunks:3]' }] });
    for (const [afterSeq, want] of [[3, [4, 5, 6]], [6, []], [99, []]]) {
      const b = (await connect(gw.url, auth())).ws;
      const seen = collect(b);
      const res = await rpc(b, '_agmente/sessions/subscribe', { sessionId, afterSeq });
      assert.equal(res.result.headSeq, 6);
      await sleep(150);
      assert.deepEqual(seqs(eventsOf(seen, sessionId)), want, `afterSeq ${afterSeq}`);
      b.close();
    }
    // afterSeq may be left out: it means 0.
    const c = (await connect(gw.url, auth())).ws;
    const seen = collect(c);
    await rpc(c, '_agmente/sessions/subscribe', { sessionId });
    await until(() => eventsOf(seen, sessionId).length === 6, '6 events');
    for (const ws of [a, c]) ws.close();
  } finally {
    await gw.stop();
  }
});

test('subscribe refuses an unknown session and a bad afterSeq, and starts no agent', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    const bad = [
      [{ sessionId: 'sess-nope', afterSeq: 0 }, 'unknown session'],
      [{ afterSeq: 0 }, 'sessionId is required'],
      [{ sessionId: 'sess-nope', afterSeq: -1 }, 'afterSeq must be a non-negative integer'],
      [{ sessionId: 'sess-nope', afterSeq: 1.5 }, 'afterSeq must be a non-negative integer'],
      [{ sessionId: 'sess-nope', afterSeq: '3' }, 'afterSeq must be a non-negative integer'],
    ];
    for (const [params, message] of bad) {
      assert.deepEqual((await rpc(ws, '_agmente/sessions/subscribe', params)).error, { code: -32602, message }, JSON.stringify(params));
    }
    await gw.settle();
    assert.equal(gw.spawned(), 0);
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('T-18: disconnect mid-turn, reconnect and subscribe with the last seq: the turn completes with no gap', async () => {
  const gw = await startGateway();
  try {
    const a = (await connect(gw.url, auth())).ws;
    const { sessionId } = await useProject(gw, a);
    const seenA = collect(a);
    assert.deepEqual((await rpc(a, '_agmente/sessions/subscribe', { sessionId, afterSeq: 0 })).result, { headSeq: 0 });
    a.send(JSON.stringify({ jsonrpc: '2.0', id: 'turn', method: 'session/prompt', params: { sessionId, prompt: [{ type: 'text', text: 'long [chunks:200][slow:5]' }] } }));
    await until(() => eventsOf(seenA, sessionId).length >= 40, '40 events on A');
    a.close();
    await nextClose(a);
    const fromA = eventsOf(seenA, sessionId);
    const last = fromA.at(-1).params.seq;
    assert.deepEqual(seqs(fromA), range(1, last), 'A saw 1..last with no gap');
    assert.equal(ended(seenA, sessionId), false, 'A left mid-turn');

    await sleep(100); // the turn keeps running with no phone attached
    const b = (await connect(gw.url, auth())).ws;
    const seenB = collect(b);
    const res = await rpc(b, '_agmente/sessions/subscribe', { sessionId, afterSeq: last });
    assert.ok(res.result.headSeq > last, 'events were logged while no phone was connected');
    await until(() => ended(seenB, sessionId), 'turn_ended on B');
    const fromB = eventsOf(seenB, sessionId);
    const logged = readEvents(gw.config.stateDir, sessionId);
    assert.deepEqual(seqs(fromB), range(last + 1, logged.length), 'B saw last+1..head with no gap and no duplicate');
    assert.deepEqual([...fromA, ...fromB].map((e) => e.params.message), logged.map((e) => e.message), 'together: the whole log, in order');
    assert.deepEqual(fromB.at(-1).params.message.params, { sessionId, stopReason: 'end_turn' }, 'the turn completed');
    assert.equal(logged.filter((e) => e.kind === 'update').length, 201, '200 chunks and the title update');
    assert.equal(gw.spawned(), 1, 'one agent throughout');
    b.close();
  } finally {
    await gw.stop();
  }
});

test('subscribing while events stream: each subscriber gets 1..head exactly once, in order', async () => {
  const gw = await startGateway();
  try {
    const a = (await connect(gw.url, auth())).ws;
    const { sessionId } = await useProject(gw, a);
    a.send(JSON.stringify({ jsonrpc: '2.0', id: 'turn', method: 'session/prompt', params: { sessionId, prompt: [{ type: 'text', text: 'x [chunks:1500][slow:1]' }] } }));
    a.close(); // the phone that started the turn is gone; the turn runs on
    const subs = [];
    for (const delay of [20, 60, 150, 400]) {
      await sleep(delay);
      const ws = (await connect(gw.url, auth())).ws;
      const seen = collect(ws);
      const res = await rpc(ws, '_agmente/sessions/subscribe', { sessionId, afterSeq: 0 });
      subs.push({ ws, seen, head: res.result.headSeq });
    }
    assert.ok(subs.some((s) => s.head > 0) && subs.some((s) => s.head < 1503), `subscribed mid-stream: heads ${subs.map((s) => s.head)}`);
    for (const s of subs) await until(() => ended(s.seen, sessionId), 'turn_ended');
    const logged = readEvents(gw.config.stateDir, sessionId);
    assert.equal(logged.length, 1503);
    for (const s of subs) {
      assert.deepEqual(seqs(eventsOf(s.seen, sessionId)), range(1, 1503), `subscriber with head ${s.head}`);
      assert.deepEqual(eventsOf(s.seen, sessionId).map((e) => e.params.message), logged.map((e) => e.message));
      s.ws.close();
    }
  } finally {
    await gw.stop();
  }
});

test('a subscribed socket gets events instead of plain messages; an attached socket still gets plain ones', async () => {
  const gw = await startGateway();
  try {
    const a = (await connect(gw.url, auth())).ws;
    const { sessionId } = await useProject(gw, a);
    const b = (await connect(gw.url, auth())).ws;
    await rpc(b, '_test/echo', { sessionId }); // b attaches by sending for the session, and does not subscribe
    const seenA = collect(a);
    const seenB = collect(b);
    await rpc(a, '_agmente/sessions/subscribe', { sessionId, afterSeq: 0 });
    const res = await rpc(a, 'session/prompt', { sessionId, prompt: [{ type: 'text', text: 'hi [chunks:3]' }] });
    assert.equal(res.result.stopReason, 'end_turn', 'the prompt response still reaches the subscriber');
    await until(() => ended(seenA, sessionId), 'turn_ended on A');
    assert.equal(seenA.some((m) => m.method === 'session/update'), false);
    assert.deepEqual(eventsOf(seenA, sessionId).map((e) => e.params.message.method),
      ['_agmente/turn_started', 'session/update', 'session/update', 'session/update', 'session/update', '_agmente/turn_ended']);
    await until(() => seenB.filter((m) => m.method === 'session/update').length === 4, 'plain updates on B');
    assert.equal(seenB.some((m) => m.method === '_agmente/event'), false);
    for (const ws of [a, b]) ws.close();
  } finally {
    await gw.stop();
  }
});

test('a permission request reaches a subscriber as an event and is answered with its gateway id', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    const { sessionId } = await useProject(gw, ws);
    const seen = collect(ws);
    await rpc(ws, '_agmente/sessions/subscribe', { sessionId, afterSeq: 0 });
    ws.send(JSON.stringify({ jsonrpc: '2.0', id: 'turn', method: 'session/prompt', params: { sessionId, prompt: [{ type: 'text', text: '[permission]' }] } }));
    const isReq = (e) => e.params.message.method === 'session/request_permission';
    await until(() => eventsOf(seen, sessionId).some(isReq), 'the permission event');
    const req = eventsOf(seen, sessionId).find(isReq).params.message;
    assert.match(req.id, /^agmente-perm-\d+$/);
    assert.equal(seen.some((m) => m.method === 'session/request_permission'), false, 'no plain copy');
    ws.send(JSON.stringify({ jsonrpc: '2.0', id: req.id, result: { outcome: { outcome: 'selected', optionId: 'cancel' } } }));
    await until(() => seen.some((m) => m.id === 'turn'), 'the prompt response');
    const answers = (await rpc(ws, '_test/permissions', {})).result.answers;
    assert.equal(answers.length, 1);
    assert.equal(answers[0].response.result.outcome.optionId, 'cancel');
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('a second subscribe on one socket replaces the first: live events arrive once', async () => {
  const gw = await startGateway();
  try {
    const a = (await connect(gw.url, auth())).ws;
    const { sessionId } = await useProject(gw, a);
    await rpc(a, 'session/prompt', { sessionId, prompt: [{ type: 'text', text: 'one [chunks:50]' }] });
    const h1 = readEvents(gw.config.stateDir, sessionId).length;
    const b = (await connect(gw.url, auth())).ws;
    const seen = collect(b);
    await rpc(b, '_agmente/sessions/subscribe', { sessionId, afterSeq: 0 });
    assert.equal((await rpc(b, '_agmente/sessions/subscribe', { sessionId, afterSeq: h1 })).result.headSeq, h1);
    await rpc(a, 'session/prompt', { sessionId, prompt: [{ type: 'text', text: 'two [chunks:3]' }] });
    const head = readEvents(gw.config.stateDir, sessionId).length;
    await until(() => eventsOf(seen, sessionId).some((e) => e.params.seq === head), `seq ${head}`);
    await sleep(100);
    const got = seqs(eventsOf(seen, sessionId));
    // The first subscription may have replayed part of 1..h1 before it was replaced. The events
    // after h1 come once each, from the second subscription.
    assert.deepEqual(got.filter((s) => s > h1), range(h1 + 1, head));
    const early = got.filter((s) => s <= h1);
    assert.deepEqual(early, range(1, early.length));
    for (const ws of [a, b]) ws.close();
  } finally {
    await gw.stop();
  }
});

test('T-19: replaying 10,000 events takes at most 1 s, and the phone is not closed as slow', async () => {
  const gw = await startGateway();
  try {
    const a = (await connect(gw.url, auth())).ws;
    const { sessionId } = await useProject(gw, a);
    // turn_started, 9,997 chunks, the title update and turn_ended. The phone that sent it goes away at once.
    a.send(JSON.stringify({ jsonrpc: '2.0', id: 'turn', method: 'session/prompt', params: { sessionId, prompt: [{ type: 'text', text: `${'x'.repeat(9997)} [chunks:9997]` }] } }));
    a.close();
    await untilLoggedEnd(gw, sessionId, 60000);
    assert.equal(readEvents(gw.config.stateDir, sessionId).length, 10000);

    const b = (await connect(gw.url, auth())).ws;
    let closed = null;
    b.once('close', (code) => { closed = code; });
    let count = 0;
    let lastSeq = 0;
    let inOrder = true;
    let done;
    const finished = new Promise((r) => { done = r; });
    let t1;
    b.on('message', (d) => {
      const m = JSON.parse(d.toString());
      if (m.method !== '_agmente/event') return;
      count += 1;
      if (m.params.seq !== lastSeq + 1) inOrder = false;
      lastSeq = m.params.seq;
      if (lastSeq === 10000) { t1 = performance.now(); done(); }
    });
    const t0 = performance.now();
    b.send(JSON.stringify({ jsonrpc: '2.0', id: 'sub', method: '_agmente/sessions/subscribe', params: { sessionId, afterSeq: 0 } }));
    await Promise.race([finished, sleep(10000)]);
    const elapsed = t1 - t0;
    assert.equal(closed, null, `the socket was closed with ${closed}`);
    assert.equal(count, 10000);
    assert.ok(inOrder, 'seq 1..10000 in order');
    console.log(`# T-19: replayed 10000 events in ${elapsed.toFixed(1)} ms`);
    assert.ok(elapsed <= 1000, `replay took ${elapsed.toFixed(1)} ms`);
    b.close();
  } finally {
    await gw.stop();
  }
});
