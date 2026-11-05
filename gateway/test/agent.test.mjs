// Agent process control and audit: FR-4, FR-9, T-13.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildAgentEnv, LineSplitter } from '../src/agent-process.js';
import { auth, connect, nextClose, rpc, sleep, startGateway, TOKEN } from './helpers.mjs';

test('buildAgentEnv passes only allow-listed names', () => {
  const env = buildAgentEnv(['PATH', 'BOB_API_KEY'], { PATH: '/bin', BOB_API_KEY: 'k', AWS_SECRET_ACCESS_KEY: 's' });
  assert.deepEqual(env, { PATH: '/bin', BOB_API_KEY: 'k' });
});

test('LineSplitter joins chunks, splits lines and stops on overflow', () => {
  const lines = [];
  let overflow = 0;
  const s = new LineSplitter(10, (l) => lines.push(l), () => { overflow += 1; });
  s.push(Buffer.from('ab'));
  s.push(Buffer.from('c\r\nde\n\nf'));
  assert.deepEqual(lines, ['abc', 'de']);
  s.push(Buffer.from('123456789012'));
  assert.equal(overflow, 1);
  s.push(Buffer.from('\nmore\n'));
  assert.deepEqual(lines, ['abc', 'de']);
});

test('the agent environment holds only allow-listed variables', async () => {
  process.env.AGMENTE_TEST_SECRET = 'must-not-leak';
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    const res = await rpc(ws, '_test/env', {});
    assert.equal(res.result.names.includes('AGMENTE_TEST_SECRET'), false);
    // D-012: macOS adds __CF_USER_TEXT_ENCODING to every child process; the gateway does not pass it.
    const osSet = process.platform === 'darwin' ? ['__CF_USER_TEXT_ENCODING'] : [];
    assert.ok(res.result.names.every((n) => n === 'PATH' || osSet.includes(n)));
    ws.close();
  } finally {
    delete process.env.AGMENTE_TEST_SECRET;
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

test('non-JSON agent output is dropped, not forwarded', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    const seen = [];
    ws.on('message', (d) => seen.push(d.toString()));
    await rpc(ws, '_test/noise', {});
    assert.ok(seen.every((m) => m.startsWith('{')));
    assert.ok(gw.auditLines.some((l) => l.event === 'agent_noise'));
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
    assert.equal((await closed).code, 1011);
    await sleep(50);
    const again = await connect(gw.url, auth());
    assert.equal(again.status, 101);
    again.ws.close();
  } finally {
    await gw.stop();
  }
});

test('closing the socket kills the agent (D-006)', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    await rpc(ws, '_test/echo', {});
    ws.close();
    await nextClose(ws);
    await sleep(200);
    const exit = gw.auditLines.find((l) => l.event === 'agent_exit');
    assert.ok(exit, 'agent_exit logged');
    assert.equal(gw.gateway.stats.active, 0);
  } finally {
    await gw.stop();
  }
});

test('T-13: the audit log holds method names but no prompt text or token', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    const { result } = await rpc(ws, 'session/new', { cwd: gw.dirs.project, mcpServers: [] });
    await rpc(ws, 'session/prompt', { sessionId: result.sessionId, prompt: [{ type: 'text', text: 'SECRET-PROMPT-TEXT' }] });
    ws.close();
    await nextClose(ws);
    const text = JSON.stringify(gw.auditLines);
    assert.ok(text.includes('"method":"session/prompt"'));
    assert.ok(text.includes('"method":"session/update"'));
    assert.equal(text.includes('SECRET-PROMPT-TEXT'), false);
    assert.equal(text.includes(TOKEN), false);
  } finally {
    await gw.stop();
  }
});
