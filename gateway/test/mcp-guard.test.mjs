// The phone's MCP server list (D-084, D-088, D-089, F1, F2): the gateway refuses bad entries before
// anything reaches the agent, and its own session/load after a restart or an idle stop carries the
// list the phone last sent, not an empty one (F-23).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { auth, connect, FAKE_AGENT, rpc, sleep, startGateway } from './helpers.mjs';

const STDIO = { name: 'local-tool', command: '/usr/bin/true', args: ['--flag'], env: [{ name: 'MODE', value: 'x' }] };
const HTTP = { type: 'http', name: 'marker', url: 'http://127.0.0.1:8941/mcp', headers: [{ name: 'X-Marker', value: 'marker-value' }] };

/** A gateway whose fake agent writes the params of its session calls into a fresh folder. */
async function startRecording(overrides = {}) {
  const recordDir = await mkdtemp(join(tmpdir(), 'acpcode-mcp-rec-'));
  const gw = await startGateway({
    agent: { command: [process.execPath, FAKE_AGENT], envPassthrough: ['PATH', 'ACPCODE_TEST_RECORD_DIR'] },
    ...overrides,
  }, { env: { ACPCODE_TEST_RECORD_DIR: recordDir } });
  const stop = gw.stop;
  gw.stop = async () => {
    await stop();
    await rm(recordDir, { recursive: true, force: true });
  };
  return { gw, recordDir };
}

const recorded = (recordDir, name) => {
  const file = join(recordDir, `${name}.json`);
  return existsSync(file) ? JSON.parse(readFileSync(file, 'utf8')) : undefined;
};

async function createProject(gw, ws) {
  const res = await rpc(ws, '_acpcode/projects/create', { name: 'test', path: gw.dirs.project });
  assert.ok(res.result?.project, JSON.stringify(res));
}

test('(a) session/new with a stdio entry is forwarded unchanged, and the agent receives it', async () => {
  const { gw, recordDir } = await startRecording();
  try {
    const { ws } = await connect(gw.url, auth());
    await createProject(gw, ws);
    const res = await rpc(ws, 'session/new', { cwd: gw.dirs.project, mcpServers: [STDIO] });
    assert.match(res.result.sessionId, /^sess-/);
    assert.deepEqual(recorded(recordDir, 'new').mcpServers, [STDIO]);
    const audit = gw.audit.find((l) => l.event === 'mcp_servers');
    assert.equal(audit?.method, 'session/new');
    assert.equal(audit?.reason, 'stdio=1 http=0', 'the audit line holds counts only');
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('(b) session/new with alwaysAllow is accepted (D-089): the agent receives the list unchanged, and the audit holds a count only', async () => {
  const { gw, recordDir } = await startRecording();
  try {
    const { ws } = await connect(gw.url, auth());
    await createProject(gw, ws);
    const allowed = { ...HTTP, alwaysAllow: ['marker_tool'] };
    const res = await rpc(ws, 'session/new', { cwd: gw.dirs.project, mcpServers: [allowed] });
    assert.match(res.result.sessionId, /^sess-/);
    assert.deepEqual(recorded(recordDir, 'new').mcpServers, [allowed]);
    const audit = gw.audit.find((l) => l.event === 'mcp_servers');
    assert.equal(audit?.method, 'session/new');
    assert.equal(audit?.reason, 'stdio=0 http=1 alwaysAllow=1', 'the audit line holds counts only');
    assert.equal(gw.audit.find((l) => l.event === 'mcp_refused'), undefined);
    assert.equal(JSON.stringify(gw.audit).includes('marker_tool'), false, 'no tool name in the audit log');
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('(b2) session/new with a bad alwaysAllow gets -32602, and the agent receives nothing (D-089)', async () => {
  const { gw, recordDir } = await startRecording();
  try {
    const { ws } = await connect(gw.url, auth());
    await createProject(gw, ws);
    const bad = [
      { ...HTTP, alwaysAllow: ['ok_tool', 7] },
      { ...STDIO, alwaysAllow: Array.from({ length: 65 }, (_, i) => `tool_${i}`) },
    ];
    for (const entry of bad) {
      const res = await rpc(ws, 'session/new', { cwd: gw.dirs.project, mcpServers: [entry] });
      assert.equal(res.error.code, -32602);
      assert.match(res.error.message, /alwaysAllow/);
    }
    // Routing by cwd starts the agent, so an agent that had seen session/new would show it here.
    const seen = (await rpc(ws, '_test/received', { cwd: gw.dirs.project })).result.methods;
    assert.equal(seen.includes('session/new'), false, 'the agent received no session/new');
    assert.equal(recorded(recordDir, 'new'), undefined, 'the agent wrote no session/new params');
    const refusals = gw.audit.filter((l) => l.event === 'mcp_refused');
    assert.equal(refusals.length, 2);
    assert.ok(refusals.every((l) => l.reason === 'alwaysAllow' && l.method === 'session/new'));
    assert.equal(JSON.stringify(gw.audit).includes('ok_tool'), false, 'no tool name in the audit log');
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('(c) an unknown type gets -32602 and the agent receives nothing', async () => {
  const { gw, recordDir } = await startRecording();
  try {
    const { ws } = await connect(gw.url, auth());
    await createProject(gw, ws);
    const sse = { type: 'sse', name: 'old', url: 'https://mcp.example.com/sse', headers: [] };
    const res = await rpc(ws, 'session/new', { cwd: gw.dirs.project, mcpServers: [sse] });
    assert.equal(res.error.code, -32602);
    assert.equal(recorded(recordDir, 'new'), undefined);
    assert.equal((await rpc(ws, '_test/received', { cwd: gw.dirs.project })).result.methods.includes('session/new'), false);
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('(c2) session/load and session/resume are checked the same way before they reach the agent', async () => {
  const { gw, recordDir } = await startRecording();
  try {
    const { ws } = await connect(gw.url, auth());
    await createProject(gw, ws);
    const made = await rpc(ws, 'session/new', { cwd: gw.dirs.project, mcpServers: [HTTP] });
    const sessionId = made.result.sessionId;
    const bad = [{ name: 'a', command: 'c', args: [], env: [], alwaysAllow: [1] }];
    assert.equal((await rpc(ws, 'session/load', { sessionId, cwd: gw.dirs.project, mcpServers: bad })).error.code, -32602);
    assert.equal((await rpc(ws, 'session/resume', { sessionId, cwd: gw.dirs.project, mcpServers: bad })).error.code, -32602);
    assert.equal(recorded(recordDir, 'load'), undefined);
    assert.equal(recorded(recordDir, 'resume'), undefined);
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('(d) after the agent restarts, the gateway\'s own session/load carries the list the phone sent, not []', async () => {
  const { gw, recordDir } = await startRecording();
  try {
    const { ws } = await connect(gw.url, auth());
    await createProject(gw, ws);
    const made = await rpc(ws, 'session/new', { cwd: gw.dirs.project, mcpServers: [STDIO, HTTP] });
    const sessionId = made.result.sessionId;
    assert.deepEqual(recorded(recordDir, 'new').mcpServers, [STDIO, HTTP]);

    const exited = await rpc(ws, '_test/exit', { sessionId });
    assert.equal(exited.error?.code, -32000);
    await gw.waitForAudit((l) => l.event === 'agent_exit');

    const prompt = await rpc(ws, 'session/prompt', { sessionId, prompt: [{ type: 'text', text: 'after restart' }] });
    assert.equal(prompt.result.stopReason, 'end_turn');
    const load = recorded(recordDir, 'load');
    assert.ok(load, 'the gateway sent its own session/load');
    assert.equal(load.sessionId, sessionId);
    assert.deepEqual(load.mcpServers, [STDIO, HTTP], 'the own load carries the phone\'s list');
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('(d2) a session/resume the phone sends while the session is live updates the list the own load uses', async () => {
  const { gw, recordDir } = await startRecording();
  try {
    const { ws } = await connect(gw.url, auth());
    await createProject(gw, ws);
    const made = await rpc(ws, 'session/new', { cwd: gw.dirs.project, mcpServers: [HTTP] });
    const sessionId = made.result.sessionId;
    const changed = [STDIO];
    const resumed = await rpc(ws, 'session/resume', { sessionId, cwd: gw.dirs.project, mcpServers: changed });
    assert.ok(resumed.result, 'a live session is answered by the gateway (D-029)');
    await rpc(ws, '_test/exit', { sessionId });
    await gw.waitForAudit((l) => l.event === 'agent_exit');
    await rpc(ws, 'session/prompt', { sessionId, prompt: [{ type: 'text', text: 'x' }] });
    assert.deepEqual(recorded(recordDir, 'load').mcpServers, changed);
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('(d3) after an idle stop, the gateway\'s own session/load carries the kept list', async () => {
  const { gw, recordDir } = await startRecording({ limits: { idleSeconds: 1 } });
  try {
    const { ws } = await connect(gw.url, auth());
    await createProject(gw, ws);
    const made = await rpc(ws, 'session/new', { cwd: gw.dirs.project, mcpServers: [HTTP] });
    const sessionId = made.result.sessionId;
    await gw.waitForAudit((l) => l.event === 'agent_idle_stop', 8000);
    await sleep(100);
    const prompt = await rpc(ws, 'session/prompt', { sessionId, prompt: [{ type: 'text', text: 'after idle' }] });
    assert.equal(prompt.result.stopReason, 'end_turn');
    assert.deepEqual(recorded(recordDir, 'load').mcpServers, [HTTP]);
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('(d4) a session the phone closed loses its list: the own load after that sends []', async () => {
  const { gw, recordDir } = await startRecording();
  try {
    const { ws } = await connect(gw.url, auth());
    await createProject(gw, ws);
    const made = await rpc(ws, 'session/new', { cwd: gw.dirs.project, mcpServers: [HTTP] });
    const sessionId = made.result.sessionId;
    const closed = await rpc(ws, 'session/close', { sessionId });
    assert.ok(closed.result, JSON.stringify(closed));
    // The session is closed by the phone; a prompt for it now needs the gateway's own load.
    const prompt = await rpc(ws, 'session/prompt', { sessionId, prompt: [{ type: 'text', text: 'after close' }] });
    assert.equal(prompt.result.stopReason, 'end_turn');
    assert.deepEqual(recorded(recordDir, 'load').mcpServers, [], 'the list was dropped with the session');
    ws.close();
  } finally {
    await gw.stop();
  }
});
