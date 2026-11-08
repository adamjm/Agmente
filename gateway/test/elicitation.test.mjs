// Elicitation relay (FR-44, PLAN 6C.2, D-026 elicitation exception). The fake agent asks the client
// for a form (elicitation/create) on every session/prompt when ACPCODE_TEST_ELICITATION names a file,
// and appends the client's whole answer to that file as one JSON line. The gateway relays the request
// to the session's subscribers and forwards the first answer under the agent's id.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { auth, connect, FAKE_AGENT, OTHER_TOKEN, rpc, sleep, startGateway, useProject } from './helpers.mjs';

const SCHEMA = {
  type: 'object',
  properties: {
    accept_license: { type: 'boolean', title: 'Accept the licence' },
    seats: { type: 'number', title: 'Seats' },
    name: { type: 'string', title: 'Name' },
    tags: { type: 'array', items: { type: 'string' }, title: 'Tags' },
  },
  required: ['accept_license'],
};

const collect = (ws) => {
  const seen = [];
  ws.on('message', (d) => seen.push(JSON.parse(d.toString())));
  return seen;
};
async function until(pred, what, ms = 10000) {
  for (const t0 = Date.now(); Date.now() - t0 < ms; await sleep(10)) if (await pred()) return;
  throw new Error(`timed out waiting for ${what}`);
}
/** The elicitation requests a subscriber has received, as the gateway relayed them. */
const requests = (seen) => seen
  .filter((m) => m.method === '_acpcode/event' && m.params.message.method === 'elicitation/create')
  .map((m) => m.params.message);
/** The closing events a subscriber has received. */
const closed = (seen) => seen
  .filter((m) => m.method === '_acpcode/event' && m.params.message.method === '_acpcode/elicitation_answered')
  .map((m) => m.params.message.params);
/** Every answer the fake agent recorded, one per line. */
const recorded = (file) => (existsSync(file)
  ? readFileSync(file, 'utf8').trim().split('\n').filter(Boolean).map((line) => JSON.parse(line))
  : []);

async function startElicitation(limits = {}) {
  const dir = await mkdtemp(join(tmpdir(), 'acpcode-elic-'));
  const record = join(dir, 'answers.jsonl');
  const gw = await startGateway({
    agent: { command: [process.execPath, FAKE_AGENT], envPassthrough: ['PATH', 'ACPCODE_TEST_ELICITATION'] },
    limits,
  }, { env: { ACPCODE_TEST_ELICITATION: record } });
  const stop = gw.stop;
  gw.stop = async () => {
    await stop();
    await rm(dir, { recursive: true, force: true });
  };
  return { gw, record };
}

/** A phone socket subscribed to a new session of the project. */
async function subscribed(gw) {
  const a = (await connect(gw.url, auth())).ws;
  const { sessionId } = await useProject(gw, a);
  const seen = collect(a);
  await rpc(a, '_acpcode/sessions/subscribe', { sessionId, afterSeq: 0 });
  return { a, sessionId, seen };
}

/** Start a turn and wait until the subscriber has the elicitation. */
async function prompt(a, sessionId, seen) {
  const before = requests(seen).length;
  const turn = rpc(a, 'session/prompt', { sessionId, prompt: [{ type: 'text', text: 'license' }] });
  await until(() => requests(seen).length > before, 'the elicitation');
  return { turn, req: requests(seen).at(-1) };
}

const answer = (ws, params) => rpc(ws, '_acpcode/elicitation/answer', params);

test('(a) an elicitation is relayed to a subscriber with its requestedSchema', async () => {
  const { gw } = await startElicitation();
  try {
    const { a, sessionId, seen } = await subscribed(gw);
    const { turn, req } = await prompt(a, sessionId, seen);
    assert.equal(req.jsonrpc, '2.0');
    assert.match(req.id, /^acpcode-elic-/, 'a gateway id, not the agent id');
    assert.deepEqual(req.params, {
      sessionId, mode: 'form', message: 'Accept the licence to continue', requestedSchema: SCHEMA,
    });
    assert.deepEqual((await answer(a, { elicitationId: req.id, action: 'decline' })).result, {});
    assert.deepEqual((await turn).result, { stopReason: 'end_turn' });
    a.close();
  } finally {
    await gw.stop();
  }
});

test('(b) an accept with content reaches the agent as the response to the agent id; subscribers see only the action', async () => {
  const { gw, record } = await startElicitation();
  try {
    const { a, sessionId, seen } = await subscribed(gw);
    const { turn, req } = await prompt(a, sessionId, seen);
    const content = { accept_license: true, seats: 3, name: 'Ada', tags: ['x', 'y'] };
    assert.deepEqual((await answer(a, { elicitationId: req.id, action: 'accept', content })).result, {});
    assert.deepEqual((await turn).result, { stopReason: 'end_turn' });

    const got = recorded(record);
    assert.equal(got.length, 1, 'the agent got one answer');
    assert.match(got[0].id, /^agent-\d+$/, 'the agent id, not the gateway id');
    assert.deepEqual(got[0].result, { action: 'accept', content });
    assert.equal(got[0].error, undefined);

    await until(() => closed(seen).length === 1, 'the closing event');
    assert.deepEqual(closed(seen)[0], { sessionId, elicitationId: req.id, answeredBy: 'owner/phone', action: 'accept' });
    const line = await gw.waitForAudit((x) => x.event === 'elicitation_answered');
    assert.equal(line.reason, 'accept');
    assert.equal(gw.audit.some((x) => JSON.stringify(x).includes('Ada')), false, 'no content value is logged');
    a.close();
  } finally {
    await gw.stop();
  }
});

test('(c) a later answer gets -32001 "answered elsewhere"; the agent gets one answer', async () => {
  const { gw, record } = await startElicitation();
  try {
    const { a, sessionId, seen } = await subscribed(gw);
    const b = (await connect(gw.url, auth(OTHER_TOKEN))).ws;
    const { turn, req } = await prompt(a, sessionId, seen);
    assert.deepEqual((await answer(a, { elicitationId: req.id, action: 'decline' })).result, {});
    assert.deepEqual((await answer(b, { elicitationId: req.id, action: 'accept', content: { accept_license: true } })).error,
      { code: -32001, message: 'answered elsewhere' });
    assert.deepEqual((await answer(a, { elicitationId: req.id, action: 'accept' })).error,
      { code: -32001, message: 'answered elsewhere' });
    assert.deepEqual((await turn).result, { stopReason: 'end_turn' });
    await sleep(100);
    const got = recorded(record);
    assert.equal(got.length, 1);
    assert.deepEqual(got[0].result, { action: 'decline' }, 'the first answer won');

    // Two devices answering at once, five times: exactly one wins each time.
    for (let i = 0; i < 5; i += 1) {
      const next = await prompt(a, sessionId, seen);
      const [ra, rb] = await Promise.all([
        answer(a, { elicitationId: next.req.id, action: 'decline' }),
        answer(b, { elicitationId: next.req.id, action: 'cancel' }),
      ]);
      assert.equal([ra, rb].filter((r) => r.result).length, 1, `round ${i}: one winner`);
      assert.deepEqual([ra, rb].find((r) => r.error).error, { code: -32001, message: 'answered elsewhere' });
      await next.turn;
    }
    await sleep(100);
    assert.equal(recorded(record).length, 6, 'one agent answer per request');
    a.close();
    b.close();
  } finally {
    await gw.stop();
  }
});

test('(d) with no answer past the timeout the agent gets decline, never accept or content', async () => {
  const { gw, record } = await startElicitation({ approvalTimeoutSeconds: 1 });
  try {
    const { a, sessionId, seen } = await subscribed(gw);
    const t0 = Date.now();
    const { turn, req } = await prompt(a, sessionId, seen);
    await until(() => recorded(record).length === 1, 'the decline', 10000);
    const waited = Date.now() - t0;
    assert.ok(waited >= 900 && waited < 5000, `answered at the timeout: ${waited} ms`);

    const got = recorded(record)[0];
    assert.deepEqual(got.result, { action: 'decline' });
    assert.equal(got.error, undefined);
    assert.deepEqual((await turn).result, { stopReason: 'end_turn' });

    await until(() => closed(seen).length === 1, 'the closing event');
    assert.deepEqual(closed(seen)[0], { sessionId, elicitationId: req.id, answeredBy: 'timeout', action: 'decline' });

    // A late answer changes nothing.
    assert.deepEqual((await answer(a, { elicitationId: req.id, action: 'accept', content: { accept_license: true } })).error,
      { code: -32001, message: 'timed out' });
    await sleep(100);
    assert.equal(recorded(record).length, 1, 'still one answer');
    a.close();
  } finally {
    await gw.stop();
  }
});

test('(e) an invalid action gets -32602 and nothing reaches the agent; a valid answer still works', async () => {
  const { gw, record } = await startElicitation();
  try {
    const { a, sessionId, seen } = await subscribed(gw);
    const { turn, req } = await prompt(a, sessionId, seen);
    for (const params of [
      { elicitationId: req.id, action: 'Accept' },
      { elicitationId: req.id, action: 'maybe' },
      { elicitationId: req.id, action: 7 },
      { elicitationId: req.id },
    ]) {
      const res = await answer(a, params);
      assert.equal(res.error?.code, -32602, JSON.stringify(params));
      assert.equal(res.result, undefined, JSON.stringify(params));
    }
    await sleep(150);
    assert.equal(existsSync(record), false, 'nothing reached the agent');

    assert.deepEqual((await answer(a, { elicitationId: req.id, action: 'accept', content: { accept_license: true } })).result, {});
    assert.deepEqual((await turn).result, { stopReason: 'end_turn' });
    assert.equal(recorded(record).length, 1);
    assert.deepEqual(recorded(record)[0].result, { action: 'accept', content: { accept_license: true } });
    a.close();
  } finally {
    await gw.stop();
  }
});

test('(f) a content value that is an object gets -32602 and nothing reaches the agent', async () => {
  const { gw, record } = await startElicitation();
  try {
    const { a, sessionId, seen } = await subscribed(gw);
    const { turn, req } = await prompt(a, sessionId, seen);
    for (const content of [
      { accept_license: { yes: true } },
      { accept_license: true, name: null },
      { tags: [1, 2] },
      ['accept_license'],
    ]) {
      const res = await answer(a, { elicitationId: req.id, action: 'accept', content });
      assert.equal(res.error?.code, -32602, JSON.stringify(content));
    }
    await sleep(150);
    assert.equal(existsSync(record), false, 'nothing reached the agent');

    assert.deepEqual((await answer(a, { elicitationId: req.id, action: 'decline' })).result, {});
    assert.deepEqual((await turn).result, { stopReason: 'end_turn' });
    assert.deepEqual(recorded(record)[0].result, { action: 'decline' });
    a.close();
  } finally {
    await gw.stop();
  }
});

test('(g) a late subscriber gets no question that was already answered; an open one once; a replayed close is marked replay', async () => {
  const { gw } = await startElicitation();
  try {
    const { a, sessionId, seen } = await subscribed(gw);
    const first = await prompt(a, sessionId, seen);
    assert.deepEqual((await answer(a, { elicitationId: first.req.id, action: 'decline' })).result, {});
    assert.deepEqual((await first.turn).result, { stopReason: 'end_turn' });
    const second = await prompt(a, sessionId, seen);

    const late = (await connect(gw.url, auth())).ws;
    const lateSeen = collect(late);
    await rpc(late, '_acpcode/sessions/subscribe', { sessionId, afterSeq: 0 });
    await until(() => closed(lateSeen).length === 1, 'the replayed close');
    await sleep(100);

    assert.deepEqual(requests(lateSeen).map((r) => r.id), [second.req.id], 'only the open question is replayed');
    const closeEvent = lateSeen.find((m) => m.method === '_acpcode/event'
      && m.params.message.method === '_acpcode/elicitation_answered');
    assert.equal(closeEvent.params.replay, true, 'the replayed close is marked as history');
    assert.equal(closeEvent.params.message.params.elicitationId, first.req.id);

    assert.deepEqual((await answer(late, { elicitationId: second.req.id, action: 'decline' })).result, {});
    await until(() => closed(lateSeen).length === 2, 'the live close');
    const liveClose = lateSeen.filter((m) => m.method === '_acpcode/event'
      && m.params.message.method === '_acpcode/elicitation_answered').at(-1);
    assert.equal(liveClose.params.replay, undefined, 'a live close is not marked replay');
    assert.equal(liveClose.params.message.params.elicitationId, second.req.id);
    assert.deepEqual((await second.turn).result, { stopReason: 'end_turn' });
    a.close();
    late.close();
  } finally {
    await gw.stop();
  }
});
