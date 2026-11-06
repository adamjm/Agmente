// Protocol guard, over the wire: T-6, T-8, T-9 (FR-6, FR-7, NFR-3).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, symlink } from 'node:fs/promises';
import { join } from 'node:path';
import { auth, connect, nextClose, rpc, startGateway, useProject } from './helpers.mjs';

/** Send one raw payload on a fresh socket and return the close code. */
async function closeCodeFor(gw, payload, options) {
  const { ws } = await connect(gw.url, auth());
  const closed = nextClose(ws);
  ws.send(payload, options);
  return (await closed).code;
}

test('one JSON-RPC object per text message: each bad shape closes the socket', async () => {
  const gw = await startGateway({ limits: { maxMessageBytes: 1024 } });
  try {
    const cases = [
      ['array (batch)', '[{"jsonrpc":"2.0","id":1,"method":"_test/echo"}]', 1007],
      ['two lines', '{"jsonrpc":"2.0","id":1,"method":"_test/echo"}\n{"jsonrpc":"2.0","id":2,"method":"_test/echo"}', 1007],
      ['bare CR inside', '{"jsonrpc":"2.0","id":1,\r"method":"_test/echo"}', 1007],
      ['two trailing newlines', '{"jsonrpc":"2.0","id":1,"method":"_test/echo"}\n\n', 1007],
      ['invalid JSON', 'not json', 1007],
      ['no jsonrpc', '{"id":1}', 1007],
      ['wrong jsonrpc', '{"jsonrpc":"1.0","id":1,"method":"x"}', 1007],
      ['jsonrpc as number', '{"jsonrpc":2.0,"id":1,"method":"x"}', 1007],
      ['null', 'null', 1007],
      ['string', '"x"', 1007],
      ['number', '5', 1007],
      ['empty', '', 1007],
      ['trailing data', '{"jsonrpc":"2.0","id":1} {"jsonrpc":"2.0","id":2}', 1007],
      ['over the cap', ' '.repeat(2048), 1009],
    ];
    for (const [name, payload, code] of cases) {
      assert.equal(await closeCodeFor(gw, payload), code, name);
    }
    assert.equal(await closeCodeFor(gw, Buffer.from('{"jsonrpc":"2.0","id":1,"method":"_test/echo"}'), { binary: true }), 1003, 'binary frame');
    assert.equal(await closeCodeFor(gw, Buffer.from([0x7b, 0xff, 0xfe, 0x7d]), { binary: false }), 1007, 'invalid UTF-8');
    await gw.waitForAudit((l) => l.event === 'protocol_violation' && l.code === 1007);
  } finally {
    await gw.stop();
  }
});

test('a single trailing LF or CRLF is allowed', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    await useProject(gw, ws);
    for (const [id, end] of [[1, '\n'], [2, '\r\n']]) {
      const reply = await new Promise((resolve) => {
        ws.once('message', (d) => resolve(JSON.parse(d.toString())));
        ws.send(`${JSON.stringify({ jsonrpc: '2.0', id, method: '_test/echo', params: { end } })}${end}`);
      });
      assert.equal(reply.id, id);
    }
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('the agent receives exactly one line per message, even for a message with escaped newlines', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    await useProject(gw, ws);
    const text = 'line1\nline2\r\n{"jsonrpc":"2.0","id":99,"method":"session/new","params":{"cwd":"/etc"}}';
    const reply = await rpc(ws, '_test/echo', { text });
    assert.equal(reply.result.text, text);
    const received = await rpc(ws, '_test/received', {});
    assert.deepEqual(received.result.methods.filter((m) => m === 'session/new'), ['session/new'], 'only the one from useProject');
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('U+2028 and U+2029 in a message cannot split it into two agent lines', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    await useProject(gw, ws);
    // The fake agent reads stdin with Node's readline, which ends a line at U+2028 and U+2029.
    for (const sep of ['\u2028', '\u2029']) {
      const text = `a${sep}{"jsonrpc":"2.0","id":5,"method":"_test/exit"}`;
      const reply = await rpc(ws, '_test/echo', { text });
      assert.equal(reply.result.text, text);
    }
    const received = await rpc(ws, '_test/received', {});
    assert.deepEqual(received.result.methods.filter((m) => m.startsWith('_test/')), ['_test/echo', '_test/echo', '_test/received']);
    ws.close();
  } finally {
    await gw.stop();
  }
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

test('T-6: a fragmented message over maxMessageBytes closes with 1009', async () => {
  const gw = await startGateway({ limits: { maxMessageBytes: 64 * 1024 } });
  try {
    const { ws } = await connect(gw.url, auth());
    const closed = nextClose(ws);
    const chunk = 'x'.repeat(40 * 1024);
    ws.send(chunk, { fin: false });
    ws.send(chunk, { fin: true });
    assert.equal((await closed).code, 1009);
  } finally {
    await gw.stop();
  }
});

test('T-6: a message of exactly maxMessageBytes is accepted', async () => {
  const gw = await startGateway({ limits: { maxMessageBytes: 64 * 1024 } });
  try {
    const { ws } = await connect(gw.url, auth());
    await useProject(gw, ws);
    const head = '{"jsonrpc":"2.0","id":7,"method":"_test/echo","params":{"pad":"';
    const tail = '"}}';
    const msg = head + 'x'.repeat(64 * 1024 - head.length - tail.length) + tail;
    assert.equal(Buffer.byteLength(msg), 64 * 1024);
    const reply = await new Promise((resolve, reject) => {
      ws.once('message', (d) => resolve(JSON.parse(d.toString())));
      ws.once('close', (code) => reject(new Error(`closed ${code}`)));
      ws.send(msg);
    });
    assert.equal(reply.id, 7);
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('T-6: an agent line over maxMessageBytes stops the agent; the phone socket stays open', async () => {
  const gw = await startGateway({ limits: { maxMessageBytes: 64 * 1024 } });
  try {
    const { ws } = await connect(gw.url, auth());
    await useProject(gw, ws);
    const reply = await rpc(ws, '_test/big', { bytes: 200 * 1024 });
    assert.deepEqual(reply.error, { code: -32000, message: 'agent exited' });
    await gw.waitForAudit((l) => l.event === 'agent_line_too_big');
    await gw.waitForAudit((l) => l.event === 'agent_exit');
    // The socket is still usable, and the next request starts a new agent.
    assert.deepEqual((await rpc(ws, '_test/echo', { ok: 1 })).result, { ok: 1 });
    assert.equal(gw.spawned(), 2);
    ws.close();
  } finally {
    await gw.stop();
  }
});
test('T-8: cwd inside a project is forwarded; outside the roots, a symlink escape and an unregistered folder are refused', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    await useProject(gw, ws); // session/new in the project: forwarded
    const sub = join(gw.dirs.project, 'sub');
    await mkdir(sub);
    const inSub = await rpc(ws, 'session/new', { cwd: sub, mcpServers: [] });
    assert.match(inSub.result.sessionId, /^sess-/, 'a folder inside a project belongs to it');

    const outside = await rpc(ws, 'session/new', { cwd: gw.dirs.outside, mcpServers: [] });
    assert.equal(outside.error.code, -32602);
    assert.equal(outside.error.message, 'cwd is outside the allowed project roots');

    const link = join(gw.dirs.project, 'escape');
    await symlink(gw.dirs.outside, link);
    const viaLink = await rpc(ws, 'session/new', { cwd: link, mcpServers: [] });
    assert.equal(viaLink.error.code, -32602);
    assert.equal(viaLink.error.message, 'cwd is outside the allowed project roots');

    // A sibling whose name starts with the root's name is outside.
    const sibling = `${gw.dirs.root}-evil`;
    await mkdir(sibling);
    const viaSibling = await rpc(ws, 'session/new', { cwd: sibling, mcpServers: [] });
    assert.equal(viaSibling.error.code, -32602);

    // Inside a root but in no registered project: refused by routing (D-025).
    const atRoot = await rpc(ws, 'session/new', { cwd: gw.dirs.root, mcpServers: [] });
    assert.deepEqual(atRoot.error, { code: -32602, message: 'cwd is not inside a registered project' });

    for (const cwd of ['relative/path', `${gw.dirs.project}/../../outside`, '/', `${gw.dirs.project}/missing`, '', 42, true, {}, []]) {
      const res = await rpc(ws, 'session/load', { cwd, sessionId: 'x', mcpServers: [] });
      assert.equal(res.error?.code, -32602, JSON.stringify(cwd));
    }

    // A refused notification is dropped silently.
    ws.send(JSON.stringify({ jsonrpc: '2.0', method: 'session/new', params: { cwd: gw.dirs.outside } }));

    // The agent never received the refused requests.
    const received = await rpc(ws, '_test/received', {});
    assert.deepEqual(received.result.methods.filter((m) => m.startsWith('session/')), ['session/new', 'session/new']);
    await gw.waitForAudit((l) => l.event === 'cwd_rejected' && l.method === 'session/load');
    ws.close();
  } finally {
    await gw.stop();
  }
});
test('T-8: a refusal echoes the request id unchanged', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    for (const id of ['abc', 0, 12.5]) {
      const reply = await new Promise((resolve) => {
        ws.once('message', (d) => resolve(JSON.parse(d.toString())));
        ws.send(JSON.stringify({ jsonrpc: '2.0', id, method: 'session/new', params: { cwd: '/etc' } }));
      });
      assert.deepEqual(reply, { jsonrpc: '2.0', id, error: { code: -32602, message: 'cwd is outside the allowed project roots' } });
    }
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('T-8: a root that does not exist allows nothing', async () => {
  const gw = await startGateway({}, { configFn: (dirs, config) => { config.projects.roots = [join(dirs.base, 'no-such-root')]; } });
  try {
    const { ws } = await connect(gw.url, auth());
    const res = await rpc(ws, 'session/new', { cwd: gw.dirs.project, mcpServers: [] });
    assert.equal(res.error.code, -32602);
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
    await gw.waitForAudit((l) => l.event === 'protocol_violation');
    await gw.settle();
    assert.equal(gw.audit.some((l) => l.event === 'rpc' && l.dir === 'in'), false);
  } finally {
    await gw.stop();
  }
});

test('backpressure: a stalled agent pauses the phone socket and nothing is lost', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    await useProject(gw, ws);
    const replies = new Set();
    ws.on('message', (d) => replies.add(JSON.parse(d.toString()).id));
    ws.send(JSON.stringify({ jsonrpc: '2.0', id: 'stall', method: '_test/stall', params: { ms: 300 } }));
    const pad = 'x'.repeat(60 * 1024);
    const N = 40; // about 2.4 MB, far more than a pipe buffer
    for (let i = 0; i < N; i += 1) ws.send(JSON.stringify({ jsonrpc: '2.0', id: i, method: '_test/echo', params: { pad } }));
    const deadline = Date.now() + 10_000;
    while (replies.size < N + 1 && Date.now() < deadline) await new Promise((r) => setTimeout(r, 20));
    assert.equal(replies.size, N + 1, 'every request got a reply');
    await gw.waitForAudit((l) => l.event === 'backpressure' && l.dir === 'in');
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
    for (const payload of cases) assert.equal(await closeCodeFor(gw, payload), 1007, payload.slice(0, 40));
  } finally {
    await gw.stop();
  }
});
