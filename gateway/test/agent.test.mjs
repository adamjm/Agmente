// Agent process control and audit, over the wire: FR-4, FR-9, T-13 (one agent per project, D-025).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { join } from 'node:path';
import { auth, connect, FAKE_AGENT, nextClose, rpc, sleep, startGateway, TOKEN, useProject } from './helpers.mjs';

test('the agent environment holds only allow-listed variables, and HOME is the project home', async () => {
  const gw = await startGateway(
    { agent: { command: [process.execPath, FAKE_AGENT], envPassthrough: ['PATH', 'HOME', 'AGMENTE_TEST_PASSED'] } },
    { env: { AGMENTE_TEST_SECRET: 'must-not-leak', AGMENTE_TEST_PASSED: 'yes' } },
  );
  try {
    const { ws } = await connect(gw.url, auth());
    const { project } = await useProject(gw, ws);
    const res = await rpc(ws, '_test/env', {});
    assert.equal(res.result.names.includes('AGMENTE_TEST_SECRET'), false);
    assert.equal(res.result.values.AGMENTE_TEST_PASSED, 'yes');
    // D-012: macOS adds __CF_USER_TEXT_ENCODING to every child process; the gateway does not pass it.
    const osSet = process.platform === 'darwin' ? ['__CF_USER_TEXT_ENCODING'] : [];
    assert.ok(res.result.names.every((n) => ['PATH', 'HOME', 'AGMENTE_TEST_PASSED'].includes(n) || osSet.includes(n)), res.result.names.join(','));
    const state = (await rpc(ws, '_test/state', {})).result;
    assert.equal(state.home, join(gw.config.stateDir, 'homes', project.id), 'HOME is the project home, never the gateway HOME');
    assert.equal(state.cwd, gw.dirs.project, 'the agent runs in the project folder');
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
    await useProject(gw, ws);
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
    const { sessionId } = await useProject(gw, ws);
    const updates = [];
    ws.on('message', (d) => {
      const m = JSON.parse(d.toString());
      if (m.method === 'session/update') updates.push(m);
    });
    const prompt = await rpc(ws, 'session/prompt', { sessionId, prompt: [{ type: 'text', text: 'hi' }] });
    assert.equal(prompt.result.stopReason, 'end_turn');
    assert.equal(updates[0].params.update.content.text, 'echo: hi');
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('ids and values pass through; notifications reach the agent; stray responses are dropped', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    const { sessionId } = await useProject(gw, ws);
    const params = { s: 'é ✓ \u2028 "q"', n: 12345678901, f: 1.5, neg: -0, nul: null, arr: [1, { a: [] }], nested: { deep: { x: true } } };
    for (const id of ['str-id', 0, 9007199254740991]) {
      const reply = await new Promise((resolve) => {
        ws.once('message', (d) => resolve(JSON.parse(d.toString())));
        ws.send(JSON.stringify({ jsonrpc: '2.0', id, method: '_test/echo', params }));
      });
      assert.equal(reply.id, id);
      assert.deepEqual(reply.result, JSON.parse(JSON.stringify(params)));
    }
    // A response to a request the gateway never sent is dropped (D-025): the agent never sees it.
    ws.send(JSON.stringify({ jsonrpc: '2.0', id: 'agent-req-1', result: { outcome: { outcome: 'cancelled' } } }));
    await gw.waitForAudit((l) => l.event === 'response_dropped');
    assert.deepEqual((await rpc(ws, '_test/responses', {})).result.responses.filter((r) => r.id === 'agent-req-1'), []);
    // A notification (no id) for a known session reaches the agent and gets no reply.
    ws.send(JSON.stringify({ jsonrpc: '2.0', method: 'session/cancel', params: { sessionId } }));
    // One for a session the gateway does not know cannot be routed, so it is dropped.
    ws.send(JSON.stringify({ jsonrpc: '2.0', method: 'session/cancel', params: { sessionId: 'unknown' } }));
    await gw.waitForAudit((l) => l.event === 'route_refused' && l.method === 'session/cancel');
    const after = await rpc(ws, '_test/received', {});
    assert.equal(after.result.methods.filter((m) => m === 'session/cancel').length, 1);
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('agent requests other than permission requests are refused by the gateway', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    await useProject(gw, ws);
    const seen = [];
    ws.on('message', (d) => seen.push(JSON.parse(d.toString())));
    const res = await rpc(ws, '_test/ask-client', { method: 'fs/read_text_file', params: { path: '/etc/passwd' } });
    assert.deepEqual(res.result.response.error, { code: -32601, message: 'Method not found' });
    assert.equal(seen.some((m) => m.method === 'fs/read_text_file'), false, 'the phone never saw it');
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('agent lines split across writes are joined; CRLF and blank lines are handled', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    await useProject(gw, ws);
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
    await useProject(gw, ws);
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

test('output written just before the agent exits still reaches the phone', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    await useProject(gw, ws);
    const reply = await rpc(ws, '_test/say-and-exit', {});
    assert.deepEqual(reply.result, { bye: true });
    await gw.waitForAudit((l) => l.event === 'agent_exit');
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('an agent command that cannot start gives a JSON-RPC error and frees its slot', async () => {
  const gw = await startGateway({
    agent: { command: ['/nonexistent/agmente-agent'], envPassthrough: ['PATH'] },
    limits: { maxAgentsPerIdentity: 1, maxAgentsTotal: 1 },
  });
  try {
    const { ws } = await connect(gw.url, auth());
    assert.ok((await rpc(ws, '_agmente/projects/create', { name: 'p', path: gw.dirs.project })).result);
    for (let i = 0; i < 2; i++) {
      const res = await rpc(ws, 'session/new', { cwd: gw.dirs.project, mcpServers: [] });
      assert.deepEqual(res.error, { code: -32000, message: 'agent failed to start' }, `attempt ${i + 1}`);
    }
    await gw.waitForAudit((l) => l.event === 'agent_error' && l.reason === 'ENOENT');
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('an agent that ignores SIGTERM is killed after the grace period', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    await useProject(gw, ws);
    await rpc(ws, '_test/ignore-sigterm', {});
    ws.send(JSON.stringify({ jsonrpc: '2.0', id: 'big', method: '_test/big', params: { bytes: 17 * 1024 * 1024 } }));
    const exit = await gw.waitForAudit((l) => l.event === 'agent_exit', 8000);
    assert.equal(exit.signal, 'SIGKILL');
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('stopping the gateway with SIGTERM stops its agents, logs shutdown and exits 0', async () => {
  const gw = await startGateway();
  const { ws } = await connect(gw.url, auth());
  await useProject(gw, ws);
  const { pid } = (await rpc(ws, '_test/state', {})).result;
  await gw.stop();
  assert.ok(gw.audit.some((l) => l.event === 'shutdown' && l.signal === 'SIGTERM'));
  assert.ok(gw.audit.some((l) => l.event === 'agent_exit' && l.pid === pid), 'the agent exited before the gateway');
  assert.throws(() => process.kill(pid, 0), /ESRCH/, 'no agent outlives the gateway');
});

test('T-13: the audit log holds method names but no prompt text or token', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    const { sessionId } = await useProject(gw, ws);
    await rpc(ws, 'session/prompt', { sessionId, prompt: [{ type: 'text', text: 'SECRET-PROMPT-TEXT' }] });
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
    const allowed = new Set(['ts', 'event', 'identity', 'device', 'client', 'conn', 'status', 'reason', 'method', 'dir', 'code', 'pid', 'exitCode', 'signal', 'project']);
    for (const line of gw.audit) {
      assert.match(line.ts, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/);
      assert.equal(typeof line.event, 'string');
      for (const k of Object.keys(line)) assert.ok(allowed.has(k), `unexpected audit field ${k}`);
    }
  } finally {
    await gw.stop();
  }
});
