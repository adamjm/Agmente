// Protocol guard: T-6, T-8, T-9 (FR-6, FR-7, NFR-3).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { symlink } from 'node:fs/promises';
import { join } from 'node:path';
import { parseClientMessage, isInsideRoots } from '../src/acp-guard.js';
import { auth, connect, nextClose, rpc, startGateway } from './helpers.mjs';

test('parseClientMessage unit cases', () => {
  const ok = parseClientMessage(Buffer.from('{"jsonrpc":"2.0","id":1,"method":"x"}\n'), false, 1024);
  assert.equal(ok.ok, true);
  assert.equal(parseClientMessage(Buffer.from('[{"jsonrpc":"2.0"}]'), false, 1024).closeCode, 1007);
  assert.equal(parseClientMessage(Buffer.from('{"jsonrpc":"2.0"}\n{"jsonrpc":"2.0"}'), false, 1024).closeCode, 1007);
  assert.equal(parseClientMessage(Buffer.from('not json'), false, 1024).closeCode, 1007);
  assert.equal(parseClientMessage(Buffer.from('{"id":1}'), false, 1024).closeCode, 1007);
  assert.equal(parseClientMessage(Buffer.from('null'), false, 1024).closeCode, 1007);
  assert.equal(parseClientMessage(Buffer.from('{}'), true, 1024).closeCode, 1003);
  assert.equal(parseClientMessage(Buffer.alloc(2048, 0x20), false, 1024).closeCode, 1009);
});

test('isInsideRoots does not accept a sibling with the same prefix', () => {
  assert.equal(isInsideRoots('/srv/root', ['/srv/root']), true);
  assert.equal(isInsideRoots('/srv/root/a/b', ['/srv/root']), true);
  assert.equal(isInsideRoots('/srv/root-evil', ['/srv/root']), false);
  assert.equal(isInsideRoots('/srv', ['/srv/root']), false);
});

test('T-6: a message over maxMessageBytes closes with 1009', async () => {
  const gw = await startGateway({ limits: { maxMessageBytes: 64 * 1024 } });
  try {
    const { ws } = await connect(gw.url, auth());
    const closed = nextClose(ws);
    ws.send(JSON.stringify({ jsonrpc: '2.0', id: 1, method: '_test/echo', params: { pad: 'x'.repeat(70 * 1024) } }));
    assert.equal((await closed).code, 1009);
  } finally {
    await gw.stop();
  }
});

test('T-6: an agent line over maxMessageBytes closes with 1009', async () => {
  const gw = await startGateway({ limits: { maxMessageBytes: 64 * 1024 } });
  try {
    const { ws } = await connect(gw.url, auth());
    const closed = nextClose(ws);
    ws.send(JSON.stringify({ jsonrpc: '2.0', id: 1, method: '_test/big', params: { bytes: 200 * 1024 } }));
    assert.equal((await closed).code, 1009);
    assert.ok(gw.auditLines.some((l) => l.event === 'agent_line_too_big'));
  } finally {
    await gw.stop();
  }
});

test('T-8: cwd inside a root is forwarded; outside and symlink escape are refused', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    const inside = await rpc(ws, 'session/new', { cwd: gw.dirs.project, mcpServers: [] });
    assert.match(inside.result.sessionId, /^sess-/);

    const outside = await rpc(ws, 'session/new', { cwd: gw.dirs.outside, mcpServers: [] });
    assert.equal(outside.error.code, -32602);

    const link = join(gw.dirs.project, 'escape');
    await symlink(gw.dirs.outside, link);
    const viaLink = await rpc(ws, 'session/new', { cwd: link, mcpServers: [] });
    assert.equal(viaLink.error.code, -32602);

    for (const cwd of ['relative/path', `${gw.dirs.project}/../../outside`, '/', 42]) {
      const res = await rpc(ws, 'session/load', { cwd, sessionId: 'x', mcpServers: [] });
      assert.equal(res.error?.code, -32602, String(cwd));
    }

    // The agent never received the refused requests.
    const received = await rpc(ws, '_test/received', {});
    assert.deepEqual(received.result.methods.filter((m) => m.startsWith('session/')), ['session/new']);
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('T-9: a message queued behind a violation never reaches the agent', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    const closed = nextClose(ws);
    ws.send('{not json');
    ws.send(JSON.stringify({ jsonrpc: '2.0', id: 2, method: '_test/echo', params: {} }));
    assert.equal((await closed).code, 1007);
    assert.equal(gw.auditLines.some((l) => l.event === 'rpc' && l.dir === 'in'), false);
  } finally {
    await gw.stop();
  }
});

test('backpressure: a stalled agent pauses the phone socket and nothing is lost', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    const replies = new Set();
    ws.on('message', (d) => replies.add(JSON.parse(d.toString()).id));
    ws.send(JSON.stringify({ jsonrpc: '2.0', id: 'stall', method: '_test/stall', params: { ms: 300 } }));
    const pad = 'x'.repeat(60 * 1024);
    const N = 40; // about 2.4 MB, far more than a pipe buffer
    for (let i = 0; i < N; i += 1) ws.send(JSON.stringify({ jsonrpc: '2.0', id: i, method: '_test/echo', params: { pad } }));
    const deadline = Date.now() + 10_000;
    while (replies.size < N + 1 && Date.now() < deadline) await new Promise((r) => setTimeout(r, 20));
    assert.equal(replies.size, N + 1, 'every request got a reply');
    assert.ok(gw.gateway.stats.backpressureEvents > 0, 'the gateway paused at least once');
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('T-9: arrays, two lines and invalid JSON each close with 1007', async () => {
  const gw = await startGateway();
  try {
    const cases = [
      JSON.stringify([{ jsonrpc: '2.0', id: 1, method: 'session/new', params: { cwd: '/etc' } }]),
      `${JSON.stringify({ jsonrpc: '2.0', id: 1, method: '_test/echo' })}\n${JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'session/new', params: { cwd: '/etc' } })}`,
      '{not json',
    ];
    for (const payload of cases) {
      const { ws } = await connect(gw.url, auth());
      const closed = nextClose(ws);
      ws.send(payload);
      assert.equal((await closed).code, 1007, payload.slice(0, 40));
    }
  } finally {
    await gw.stop();
  }
});
