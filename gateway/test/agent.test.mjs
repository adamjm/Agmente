// Agent process control and audit, over the wire: FR-4, FR-9, T-13.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { auth, connect, FAKE_AGENT, nextClose, rpc, sleep, startGateway, TOKEN } from './helpers.mjs';

test('the agent environment holds only allow-listed variables', async () => {
  const gw = await startGateway(
    { agent: { command: [process.execPath, FAKE_AGENT], envPassthrough: ['PATH', 'AGMENTE_TEST_PASSED'] } },
    { env: { AGMENTE_TEST_SECRET: 'must-not-leak', AGMENTE_TEST_PASSED: 'yes' } },
  );
  try {
    const { ws } = await connect(gw.url, auth());
    const res = await rpc(ws, '_test/env', {});
    assert.equal(res.result.names.includes('AGMENTE_TEST_SECRET'), false);
    assert.equal(res.result.values.AGMENTE_TEST_PASSED, 'yes');
    // D-012: macOS adds __CF_USER_TEXT_ENCODING to every child process; the gateway does not pass it.
    const osSet = process.platform === 'darwin' ? ['__CF_USER_TEXT_ENCODING'] : [];
    assert.ok(res.result.names.every((n) => n === 'PATH' || n === 'AGMENTE_TEST_PASSED' || osSet.includes(n)), res.result.names.join(','));
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('the agent gets exactly the configured arguments', async () => {
  const gw = await startGateway({
    agent: { command: [process.execPath, FAKE_AGENT, '--flag', 'a b', '$HOME'], envPassthrough: ['PATH'] },
  });
  try {
    const { ws } = await connect(gw.url, auth());
    const res = await rpc(ws, '_test/argv', {});
    // No shell: the space and the `$HOME` reach the agent unchanged.
    assert.deepEqual(res.result.args, ['--flag', 'a b', '$HOME']);
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('a full ACP round trip works through the gateway', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    const init = await rpc(ws, 'initialize', { protocolVersion: 1, clientCapabilities: {} });
    assert.equal(init.result.agentInfo.name, 'bob-shell');
    assert.equal(init.result.agentCapabilities.loadSession, true);
    const { result } = await rpc(ws, 'session/new', { cwd: gw.dirs.project, mcpServers: [] });
    const updates = [];
    ws.on('message', (d) => {
      const m = JSON.parse(d.toString());
      if (m.method === 'session/update') updates.push(m);
    });
    const prompt = await rpc(ws, 'session/prompt', { sessionId: result.sessionId, prompt: [{ type: 'text', text: 'hi' }] });
    assert.equal(prompt.result.stopReason, 'end_turn');
    assert.equal(updates[0].params.update.content.text, 'echo: hi');
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('requests, responses and notifications pass through with their ids and values', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    const params = { s: 'é ✓ \u2028 "q"', n: 12345678901, f: 1.5, neg: -0, nul: null, arr: [1, { a: [] }], nested: { deep: { x: true } } };
    for (const id of ['str-id', 0, 9007199254740991]) {
      const reply = await new Promise((resolve) => {
        ws.once('message', (d) => resolve(JSON.parse(d.toString())));
        ws.send(JSON.stringify({ jsonrpc: '2.0', id, method: '_test/echo', params }));
      });
      assert.equal(reply.id, id);
      assert.deepEqual(reply.result, JSON.parse(JSON.stringify(params)));
    }
    // A client response (no method) reaches the agent, which reports it.
    ws.send(JSON.stringify({ jsonrpc: '2.0', id: 'agent-req-1', result: { outcome: { outcome: 'cancelled' } } }));
    const received = await rpc(ws, '_test/responses', {});
    assert.deepEqual(received.result.responses, [{ jsonrpc: '2.0', id: 'agent-req-1', result: { outcome: { outcome: 'cancelled' } } }]);
    // A notification (no id) reaches the agent and gets no reply.
    ws.send(JSON.stringify({ jsonrpc: '2.0', method: 'session/cancel', params: { sessionId: 'x' } }));
    const after = await rpc(ws, '_test/received', {});
    assert.ok(after.result.methods.includes('session/cancel'));
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('agent lines split across writes are joined; CRLF and blank lines are handled', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    const seen = [];
    ws.on('message', (d) => seen.push(JSON.parse(d.toString())));
    const one = JSON.stringify({ jsonrpc: '2.0', method: '_test/one', params: { v: 1 } });
    const two = JSON.stringify({ jsonrpc: '2.0', method: '_test/two', params: { v: 2 } });
    const parts = [one.slice(0, 10), one.slice(10), '\r\n', '\n', two.slice(0, 5), `${two.slice(5)}\n`];
    await rpc(ws, '_test/chunks', { parts, delayMs: 30 });
    for (let i = 0; i < 40 && seen.filter((m) => m.method).length < 2; i++) await sleep(25);
    assert.deepEqual(seen.filter((m) => m.method).map((m) => m.method), ['_test/one', '_test/two']);
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('non-JSON agent output is dropped, not forwarded', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    const seen = [];
    ws.on('message', (d) => seen.push(d.toString()));
    await rpc(ws, '_test/noise', {});
    assert.ok(seen.every((m) => m.startsWith('{')));
    await gw.waitForAudit((l) => l.event === 'agent_noise');
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('the socket closes with 1011 when the agent exits, and the slot is freed', async () => {
  const gw = await startGateway({ limits: { maxAgentsPerIdentity: 1, maxAgentsTotal: 1 } });
  try {
    const { ws } = await connect(gw.url, auth());
    const closed = nextClose(ws);
    ws.send(JSON.stringify({ jsonrpc: '2.0', id: 1, method: '_test/exit' }));
    const { code, reason } = await closed;
    assert.equal(code, 1011);
    assert.equal(reason, 'agent exited');
    const exit = await gw.waitForAudit((l) => l.event === 'agent_exit');
    assert.equal(exit.exitCode, 3);
    await sleep(50);
    const again = await connect(gw.url, auth());
    assert.equal(again.status, 101);
    again.ws.close();
  } finally {
    await gw.stop();
  }
});

test('output written just before the agent exits still reaches the phone', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    const seen = [];
    ws.on('message', (d) => seen.push(JSON.parse(d.toString())));
    const closed = nextClose(ws);
    ws.send(JSON.stringify({ jsonrpc: '2.0', id: 'last', method: '_test/say-and-exit' }));
    assert.equal((await closed).code, 1011);
    assert.deepEqual(seen.map((m) => m.id), ['last']);
  } finally {
    await gw.stop();
  }
});

test('an agent command that cannot start closes the socket with 1011 and frees the slot', async () => {
  const gw = await startGateway({
    agent: { command: ['/nonexistent/agmente-agent'], envPassthrough: ['PATH'] },
    limits: { maxAgentsPerIdentity: 1, maxAgentsTotal: 1 },
  });
  try {
    for (let i = 0; i < 2; i++) {
      const res = await connect(gw.url, auth());
      assert.equal(res.status, 101);
      const { code, reason } = await nextClose(res.ws);
      assert.equal(code, 1011);
      assert.equal(reason, 'agent failed to start');
      await sleep(50);
    }
  } finally {
    await gw.stop();
  }
});

test('closing the socket kills the agent (D-006)', async () => {
  const gw = await startGateway({ limits: { maxAgentsPerIdentity: 1, maxAgentsTotal: 1 } });
  try {
    const { ws } = await connect(gw.url, auth());
    await rpc(ws, '_test/echo', {});
    ws.close();
    await nextClose(ws);
    const exit = await gw.waitForAudit((l) => l.event === 'agent_exit');
    assert.ok(exit.signal === 'SIGTERM' || exit.exitCode !== null, JSON.stringify(exit));
    await gw.waitForAudit((l) => l.event === 'disconnect');
    // The slot is free: a new agent may start.
    await sleep(50);
    const again = await connect(gw.url, auth());
    assert.equal(again.status, 101);
    again.ws.close();
  } finally {
    await gw.stop();
  }
});

test('an agent that ignores SIGTERM is killed after the grace period', async () => {
  const gw = await startGateway({ limits: { maxAgentsPerIdentity: 1, maxAgentsTotal: 1 } });
  try {
    const { ws } = await connect(gw.url, auth());
    await rpc(ws, '_test/ignore-sigterm', {});
    ws.close();
    await nextClose(ws);
    const exit = await gw.waitForAudit((l) => l.event === 'agent_exit', 6000);
    assert.equal(exit.signal, 'SIGKILL');
  } finally {
    await gw.stop();
  }
});

test('stopping the gateway with SIGTERM logs shutdown and exits 0', async () => {
  const gw = await startGateway();
  const { ws } = await connect(gw.url, auth());
  await rpc(ws, '_test/echo', {});
  await gw.stop();
  assert.ok(gw.audit.some((l) => l.event === 'shutdown' && l.signal === 'SIGTERM'));
});

test('T-13: the audit log holds method names but no prompt text or token', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    const { result } = await rpc(ws, 'session/new', { cwd: gw.dirs.project, mcpServers: [] });
    await rpc(ws, 'session/prompt', { sessionId: result.sessionId, prompt: [{ type: 'text', text: 'SECRET-PROMPT-TEXT' }] });
    ws.close();
    await nextClose(ws);
    await gw.waitForAudit((l) => l.event === 'disconnect');
    await gw.waitForAudit((l) => l.event === 'rpc' && l.dir === 'out' && l.method === 'session/update');
    await gw.waitForAudit((l) => l.event === 'rpc' && l.dir === 'in' && l.method === 'session/prompt');
    const text = JSON.stringify(gw.audit);
    assert.equal(text.includes('SECRET-PROMPT-TEXT'), false);
    assert.equal(text.includes(TOKEN), false);
    assert.equal(text.includes(gw.dirs.project), false, 'no paths from params');
    // Each line has a timestamp and an event name, and only known fields.
    const allowed = new Set(['ts', 'event', 'identity', 'device', 'client', 'conn', 'status', 'reason', 'method', 'dir', 'code', 'pid', 'exitCode', 'signal']);
    for (const line of gw.audit) {
      assert.match(line.ts, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/);
      assert.equal(typeof line.event, 'string');
      for (const k of Object.keys(line)) assert.ok(allowed.has(k), `unexpected audit field ${k}`);
    }
  } finally {
    await gw.stop();
  }
});
