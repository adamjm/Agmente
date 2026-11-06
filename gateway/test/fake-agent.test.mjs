// The fake agent copies Bob's recorded behaviour (PLAN 3.1, F-12, F-21). These tests talk to it
// directly over stdio, with no gateway, so phase 3 gateway tests can rely on it.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import { FAKE_AGENT } from './helpers.mjs';

/** Start the fake agent. Every line it writes is kept in `lines`, in order. */
function startAgent(args = []) {
  const child = spawn(process.execPath, [FAKE_AGENT, ...args], { stdio: ['pipe', 'pipe', 'inherit'], env: { PATH: process.env.PATH } });
  const lines = [];
  const waiters = new Set();
  createInterface({ input: child.stdout }).on('line', (line) => {
    lines.push(JSON.parse(line));
    for (const w of waiters) w();
  });
  const exited = new Promise((r) => child.once('exit', r));
  let nextId = 1;
  const agent = {
    lines,
    send: (obj) => child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', ...obj })}\n`),
    /** Wait for the first line (at or after index `from`) that matches. Returns its index and value. */
    waitFor(pred, from = 0, ms = 5000) {
      return new Promise((resolve, reject) => {
        const check = () => {
          const i = lines.findIndex((l, k) => k >= from && pred(l));
          if (i === -1) return;
          waiters.delete(check);
          clearTimeout(timer);
          resolve({ index: i, line: lines[i] });
        };
        const timer = setTimeout(() => { waiters.delete(check); reject(new Error(`timeout; saw ${JSON.stringify(lines.slice(from))}`)); }, ms);
        waiters.add(check);
        check();
      });
    },
    /** Send a request; resolve with the index and value of its response. */
    async call(method, params) {
      const id = nextId++;
      agent.send({ id, method, params });
      return agent.waitFor((l) => l.id === id && l.method === undefined);
    },
    async rpc(method, params) { return (await agent.call(method, params)).line; },
    updates: (sessionId, from = 0) => lines.slice(from).filter((l) => l.method === 'session/update' && l.params.sessionId === sessionId).map((l) => l.params.update),
    async stop() { child.stdin.end(); child.kill('SIGTERM'); await exited; },
  };
  return agent;
}

const prompt = (text) => [{ type: 'text', text }];

async function withStore(fn) {
  const dir = await mkdtemp(join(tmpdir(), 'agmente-fake-'));
  try {
    await fn(join(dir, 'store.json'));
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

test('initialize returns the captured Bob 2.0.9 capabilities; session/new returns modes', async () => {
  const a = startAgent();
  try {
    const init = await a.rpc('initialize', { protocolVersion: 1, clientCapabilities: {} });
    assert.equal(init.result.agentInfo.version, '2.0.9');
    assert.equal(init.result.agentCapabilities.loadSession, true);
    const created = await a.rpc('session/new', { cwd: '/tmp', mcpServers: [] });
    assert.match(created.result.sessionId, /^sess-[0-9a-f]{16}$/);
    assert.deepEqual(created.result.modes.availableModes.map((m) => m.id), ['agent', 'plan', 'ask']);
  } finally {
    await a.stop();
  }
});

test('a turn streams chunks over time, then ends; the first turn sets the title', async () => {
  const a = startAgent();
  try {
    const { result: { sessionId } } = await a.rpc('session/new', { cwd: '/tmp', mcpServers: [] });
    const t0 = Date.now();
    const done = await a.rpc('session/prompt', { sessionId, prompt: prompt('hello [chunks:5][slow:60]') });
    assert.equal(done.result.stopReason, 'end_turn');
    assert.ok(Date.now() - t0 >= 4 * 60 - 20, 'the turn took time');
    const ups = a.updates(sessionId);
    const chunks = ups.filter((u) => u.sessionUpdate === 'agent_message_chunk');
    assert.equal(chunks.length, 5);
    assert.equal(chunks.map((c) => c.content.text).join(''), 'echo: hello [chunks:5][slow:60]');
    assert.deepEqual(ups.filter((u) => u.sessionUpdate === 'session_info_update').map((u) => u.title), ['hello [chunks:5][slow:60]']);
    // Every update arrives before the prompt response.
    const respIndex = a.lines.findIndex((l) => l.id !== undefined && l.result?.stopReason);
    assert.ok(a.lines.slice(respIndex + 1).every((l) => l.method !== 'session/update'));
  } finally {
    await a.stop();
  }
});

test('F-12: load and resume are refused while a turn runs, and the turn goes on', async () => {
  const a = startAgent();
  try {
    const { result: { sessionId } } = await a.rpc('session/new', { cwd: '/tmp', mcpServers: [] });
    const turn = a.call('session/prompt', { sessionId, prompt: prompt('long [chunks:6][slow:80]') });
    await a.waitFor((l) => l.params?.update?.sessionUpdate === 'agent_message_chunk');
    for (const method of ['session/load', 'session/resume']) {
      const res = await a.rpc(method, { sessionId, cwd: '/tmp', mcpServers: [] });
      assert.deepEqual(res.error, { code: -32600, message: 'Invalid request: Session is already running a prompt', data: { sessionId } }, method);
    }
    assert.equal((await turn).line.result.stopReason, 'end_turn');
    assert.equal(a.updates(sessionId).filter((u) => u.sessionUpdate === 'agent_message_chunk').length, 6);
  } finally {
    await a.stop();
  }
});

test('F-12: an idle load answers first, then replays one coalesced update per message', async () => {
  const a = startAgent();
  try {
    const { result: { sessionId } } = await a.rpc('session/new', { cwd: '/tmp', mcpServers: [] });
    await a.rpc('session/prompt', { sessionId, prompt: prompt('one [chunks:4]') });
    await a.rpc('session/prompt', { sessionId, prompt: prompt('two [chunks:3]') });
    for (const method of ['session/load', 'session/resume']) {
      const { index, line } = await a.call(method, { sessionId, cwd: '/tmp', mcpServers: [] });
      assert.deepEqual(Object.keys(line.result), ['modes'], method);
      await a.waitFor((l) => l.params?.update?.content?.text === 'echo: two [chunks:3]', index);
      const replay = a.updates(sessionId, index + 1);
      assert.deepEqual(replay.map((u) => u.sessionUpdate), ['available_commands_update', 'user_message_chunk', 'agent_message_chunk', 'user_message_chunk', 'agent_message_chunk'], method);
      assert.deepEqual(replay.slice(1).map((u) => u.content.text), ['one [chunks:4]', 'echo: one [chunks:4]', 'two [chunks:3]', 'echo: two [chunks:3]']);
    }
  } finally {
    await a.stop();
  }
});

test('sessions persist across a restart with the same store; list and delete', async () => {
  await withStore(async (store) => {
    const a = startAgent(['--store', store]);
    const { result: { sessionId } } = await a.rpc('session/new', { cwd: '/w', mcpServers: [] });
    await a.rpc('session/prompt', { sessionId, prompt: prompt('remember me') });
    await a.stop();

    const b = startAgent(['--store', store]);
    try {
      assert.equal((await b.rpc('session/prompt', { sessionId, prompt: prompt('x') })).error.code, -32602, 'not live until loaded');
      const listed = await b.rpc('session/list', {});
      assert.deepEqual(listed.result.sessions.map((s) => [s.sessionId, s.title, s.cwd]), [[sessionId, 'remember me', '/w']]);
      const { index } = await b.call('session/load', { sessionId, cwd: '/w', mcpServers: [] });
      await b.waitFor((l) => l.params?.update?.content?.text === 'echo: remember me', index);
      assert.equal((await b.rpc('session/prompt', { sessionId, prompt: prompt('again') })).result.stopReason, 'end_turn');
      assert.deepEqual(await b.rpc('session/delete', { sessionId }).then((r) => r.result), {});
      assert.deepEqual((await b.rpc('session/list', {})).result.sessions, []);
      assert.equal((await b.rpc('session/load', { sessionId, cwd: '/w', mcpServers: [] })).error.code, -32602);
    } finally {
      await b.stop();
    }
  });
});

test('permission: the agent asks, waits, and acts on allow or reject', async () => {
  const a = startAgent();
  try {
    const { result: { sessionId } } = await a.rpc('session/new', { cwd: '/tmp', mcpServers: [] });
    for (const [optionId, status, stopReason] of [['proceed_once', 'completed', 'end_turn'], ['cancel', 'failed', 'end_turn']]) {
      const from = a.lines.length;
      const turn = a.call('session/prompt', { sessionId, prompt: prompt('run it [permission]') });
      const { line: req } = await a.waitFor((l) => l.method === 'session/request_permission', from);
      assert.equal(req.params.sessionId, sessionId);
      assert.deepEqual(req.params.options.map((o) => o.kind), ['allow_once', 'allow_always', 'reject_once']);
      assert.equal(req.params.toolCall.kind, 'execute');
      await new Promise((r) => setTimeout(r, 100));
      assert.equal(a.lines.slice(from).some((l) => l.result?.stopReason), false, 'the turn waits for the answer');
      a.send({ id: req.id, result: { outcome: { outcome: 'selected', optionId } } });
      assert.equal((await turn).line.result.stopReason, stopReason);
      const tcu = a.updates(sessionId, from).find((u) => u.sessionUpdate === 'tool_call_update');
      assert.equal(tcu.status, status, optionId);
    }
    const log = (await a.rpc('_test/permissions', {})).result.answers;
    assert.deepEqual(log.map((x) => x.response.result.outcome.optionId), ['proceed_once', 'cancel']);
  } finally {
    await a.stop();
  }
});

test('session/cancel ends a turn waiting for permission, and a streaming turn, with "cancelled"', async () => {
  const a = startAgent();
  try {
    const { result: { sessionId } } = await a.rpc('session/new', { cwd: '/tmp', mcpServers: [] });
    const waiting = a.call('session/prompt', { sessionId, prompt: prompt('[permission]') });
    await a.waitFor((l) => l.method === 'session/request_permission');
    a.send({ method: 'session/cancel', params: { sessionId } });
    assert.equal((await waiting).line.result.stopReason, 'cancelled');

    const streaming = a.call('session/prompt', { sessionId, prompt: prompt('[chunks:20][slow:50]') });
    const from = a.lines.length;
    await a.waitFor((l) => l.params?.update?.sessionUpdate === 'agent_message_chunk', from);
    a.send({ method: 'session/cancel', params: { sessionId } });
    assert.equal((await streaming).line.result.stopReason, 'cancelled');
    assert.ok(a.updates(sessionId, from).filter((u) => u.sessionUpdate === 'agent_message_chunk').length < 20);
  } finally {
    await a.stop();
  }
});

test('F-21: two processes on one store lose the earlier writer\'s turn, with no error', async () => {
  await withStore(async (store) => {
    const a = startAgent(['--store', store]);
    const b = startAgent(['--store', store]);
    try {
      const { result: { sessionId } } = await a.rpc('session/new', { cwd: '/w', mcpServers: [] });
      await a.rpc('session/prompt', { sessionId, prompt: prompt('[P0]') });
      // A starts a long turn. B, a second process, is not refused: the check is per process.
      const aTurn = a.call('session/prompt', { sessionId, prompt: prompt('[P1] [chunks:5][slow:80]') });
      await a.waitFor((l) => l.params?.update?.sessionUpdate === 'agent_message_chunk' && l.params.update.content.text.includes('[P1'));
      const load = await b.rpc('session/load', { sessionId, cwd: '/w', mcpServers: [] });
      assert.ok(load.result, 'second process loads the running session');
      assert.equal((await b.rpc('session/prompt', { sessionId, prompt: prompt('[PB]') })).result.stopReason, 'end_turn');
      assert.equal((await aTurn).line.result.stopReason, 'end_turn');
      await a.rpc('session/prompt', { sessionId, prompt: prompt('[P2]') });
    } finally {
      await a.stop();
      await b.stop();
    }
    // A third process sees A's saves; B's completed turn is gone.
    const c = startAgent(['--store', store]);
    try {
      const { result: { sessions: [{ sessionId }] } } = await c.rpc('session/list', {});
      const { index } = await c.call('session/load', { sessionId, cwd: '/w', mcpServers: [] });
      await c.waitFor((l) => l.params?.update?.content?.text === 'echo: [P2]', index);
      const prompts = c.updates(sessionId, index).filter((u) => u.sessionUpdate === 'user_message_chunk').map((u) => u.content.text.match(/\[P\w+\]/)[0]);
      assert.deepEqual(prompts, ['[P0]', '[P1]', '[P2]']);
    } finally {
      await c.stop();
    }
  });
});

test('the default store is $HOME/.fake-agent/store.json; without HOME it is memory only', async () => {
  const home = await mkdtemp(join(tmpdir(), 'agmente-fake-home-'));
  try {
    const child = spawn(process.execPath, [FAKE_AGENT], { stdio: ['pipe', 'pipe', 'inherit'], env: { PATH: process.env.PATH, HOME: home } });
    const rl = createInterface({ input: child.stdout });
    const first = new Promise((r) => rl.once('line', (l) => r(JSON.parse(l))));
    child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id: 1, method: '_test/state' })}\n`);
    assert.equal((await first).result.store, join(home, '.fake-agent', 'store.json'));
    child.kill();
    const a = startAgent();
    try {
      assert.equal((await a.rpc('_test/state', {})).result.store, null);
    } finally {
      await a.stop();
    }
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});
