// Session index and read markers (FR-21, FR-25, PLAN 3.8, D-030).
// A fake-agent turn with [chunks:N] logs turn_started, N chunk updates, turn_ended, and on a
// session's first turn a session_info_update with the first 50 characters of the prompt as title.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdir } from 'node:fs/promises';
import { join } from 'node:path';
import { auth, connect, hashToken, makeDirs, OTHER_TOKEN, rawConfig, rpc, sleep, spawnGateway, startGateway, TOKEN, useProject } from './helpers.mjs';

const TABLET_TOKEN = 'tablet-token-abcdefghijklmnop';
const tokens = [
  { id: 'phone', identity: 'owner', sha256: hashToken(TOKEN) },
  { id: 'tablet', identity: 'owner', sha256: hashToken(TABLET_TOKEN) },
  { id: 'other', identity: 'guest', sha256: hashToken(OTHER_TOKEN) },
];
const index = async (ws, params = {}) => {
  const res = await rpc(ws, '_acpcode/sessions/index', params);
  if (!res.result) throw new Error(JSON.stringify(res.error));
  return res.result.sessions;
};
const byId = (sessions, id) => sessions.find((s) => s.sessionId === id);
async function until(pred, what, ms = 10000) {
  for (const t0 = Date.now(); Date.now() - t0 < ms; await sleep(10)) if (await pred()) return;
  throw new Error(`timed out waiting for ${what}`);
}
const ISO = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/;

test('index lists every session with project, title, status, last activity and unread, newest first', async () => {
  const gw = await startGateway();
  try {
    const a = (await connect(gw.url, auth())).ws;
    const { project, sessionId: s1 } = await useProject(gw, a);
    let sessions = await index(a);
    assert.deepEqual(Object.keys(sessions[0]), ['sessionId', 'projectId', 'title', 'status', 'lastActivity', 'headSeq', 'unread']);
    assert.deepEqual({ ...sessions[0], lastActivity: 'x' }, { sessionId: s1, projectId: project.id, title: null, status: 'idle', lastActivity: 'x', headSeq: 0, unread: 0 });
    assert.match(sessions[0].lastActivity, ISO);

    await rpc(a, 'session/prompt', { sessionId: s1, prompt: [{ type: 'text', text: 'fix the login page [chunks:2]' }] });
    sessions = await index(a);
    assert.equal(byId(sessions, s1).title, 'fix the login page [chunks:2]', 'the title from session_info_update');
    assert.equal(byId(sessions, s1).headSeq, 5);
    assert.equal(byId(sessions, s1).unread, 1, 'one turn ended and nothing was marked read');
    const after1 = byId(sessions, s1).lastActivity;

    // A second project with a newer session; then the first session gets newer activity again.
    const other = join(gw.dirs.root, 'other');
    await mkdir(other);
    const p2 = (await rpc(a, '_acpcode/projects/create', { name: 'other', path: other })).result.project;
    const s2 = (await rpc(a, 'session/new', { cwd: other, mcpServers: [] })).result.sessionId;
    await sleep(5);
    assert.deepEqual((await index(a)).map((s) => s.sessionId), [s2, s1], 'newest first');
    await rpc(a, 'session/prompt', { sessionId: s1, prompt: [{ type: 'text', text: 'again' }] });
    sessions = await index(a);
    assert.deepEqual(sessions.map((s) => s.sessionId), [s1, s2]);
    assert.ok(byId(sessions, s1).lastActivity > after1, 'last activity moved forward');
    assert.equal(byId(sessions, s1).title, 'fix the login page [chunks:2]', 'a later turn keeps the title');
    assert.equal(byId(sessions, s1).unread, 2);

    assert.deepEqual((await index(a, { projectId: p2.id })).map((s) => s.sessionId), [s2]);
    assert.deepEqual((await index(a, { projectId: project.id })).map((s) => s.sessionId), [s1]);
    a.close();
  } finally {
    await gw.stop();
  }
});

test('index status: running during a turn, awaiting_approval during a permission request, error after an agent death, idle again after a turn', async () => {
  const gw = await startGateway();
  try {
    const a = (await connect(gw.url, auth())).ws;
    const { sessionId } = await useProject(gw, a);
    const status = async () => byId(await index(a), sessionId).status;

    const turn = rpc(a, 'session/prompt', { sessionId, prompt: [{ type: 'text', text: 'slow [chunks:50][slow:10]' }] });
    await until(async () => (await status()) === 'running', 'running');
    await turn;
    assert.equal(await status(), 'idle');

    const seen = [];
    a.on('message', (d) => seen.push(JSON.parse(d.toString())));
    const asking = rpc(a, 'session/prompt', { sessionId, prompt: [{ type: 'text', text: 'go [permission]' }] });
    await until(() => seen.some((m) => m.method === 'session/request_permission'), 'the permission request');
    assert.equal(await status(), 'awaiting_approval', 'an open request wins over running');
    const req = seen.find((m) => m.method === 'session/request_permission');
    a.send(JSON.stringify({ jsonrpc: '2.0', id: req.id, result: { outcome: { outcome: 'selected', optionId: 'proceed_once' } } }));
    await asking;
    assert.equal(await status(), 'idle');

    const dying = rpc(a, 'session/prompt', { sessionId, prompt: [{ type: 'text', text: 'long [chunks:500][slow:10]' }] });
    await until(async () => (await status()) === 'running', 'running');
    await rpc(a, '_test/exit', {});
    assert.equal((await dying).error.code, -32000);
    assert.equal(await status(), 'error', 'the turn died with the agent');
    assert.equal(gw.spawned(), 1, 'index started no agent');

    await rpc(a, 'session/load', { sessionId, cwd: gw.dirs.project, mcpServers: [] });
    await rpc(a, 'session/prompt', { sessionId, prompt: [{ type: 'text', text: 'ok' }] });
    assert.equal(await status(), 'idle', 'a completed turn clears the error');
    a.close();
  } finally {
    await gw.stop();
  }
});

test('read markers are shared by every device of an identity, not by other identities', async () => {
  const gw = await startGateway({ tokens });
  try {
    const phone = (await connect(gw.url, auth(TOKEN))).ws;
    const tablet = (await connect(gw.url, auth(TABLET_TOKEN))).ws;
    const guest = (await connect(gw.url, auth(OTHER_TOKEN))).ws;
    const { sessionId } = await useProject(gw, phone);
    for (const text of ['one', 'two', 'three']) await rpc(phone, 'session/prompt', { sessionId, prompt: [{ type: 'text', text }] });
    // Turns end at seq 4 (first turn: started, chunk, title, ended), 7 and 10.
    const unread = async (ws) => byId(await index(ws), sessionId).unread;
    assert.deepEqual([await unread(phone), await unread(tablet), await unread(guest)], [3, 3, 3]);

    assert.deepEqual((await rpc(phone, '_acpcode/sessions/read', { sessionId, seq: 7 })).result, { lastSeenSeq: 7 });
    assert.deepEqual([await unread(phone), await unread(tablet), await unread(guest)], [1, 1, 3], 'FR-25: the tablet sees what the phone read');
    assert.deepEqual((await rpc(tablet, '_acpcode/sessions/read', { sessionId, seq: 2 })).result, { lastSeenSeq: 7 }, 'never moves back');
    assert.deepEqual((await rpc(tablet, '_acpcode/sessions/read', { sessionId, seq: 999 })).result, { lastSeenSeq: 10 }, 'stops at the head');
    assert.deepEqual([await unread(phone), await unread(guest)], [0, 3]);
    await rpc(phone, 'session/prompt', { sessionId, prompt: [{ type: 'text', text: 'four' }] });
    assert.equal(await unread(tablet), 1, 'a new turn is unread again');

    const bad = [
      [{ seq: 1 }, 'sessionId is required'],
      [{ sessionId, seq: -1 }, 'seq must be a non-negative integer'],
      [{ sessionId, seq: 1.5 }, 'seq must be a non-negative integer'],
      [{ sessionId, seq: '3' }, 'seq must be a non-negative integer'],
      [{ sessionId }, 'seq must be a non-negative integer'],
      [{ sessionId: 'sess-nope', seq: 1 }, 'unknown session'],
    ];
    for (const [params, message] of bad) {
      assert.deepEqual((await rpc(guest, '_acpcode/sessions/read', params)).error, { code: -32602, message }, JSON.stringify(params));
    }
    for (const [params, message] of [[{ projectId: 'nope' }, 'unknown project'], [{ projectId: 7 }, 'projectId must be a project id']]) {
      assert.deepEqual((await rpc(guest, '_acpcode/sessions/index', params)).error, { code: -32602, message });
    }
    for (const ws of [phone, tablet, guest]) ws.close();
  } finally {
    await gw.stop();
  }
});

test('index survives a gateway restart and starts no agent; a deleted session leaves the index', async () => {
  const dirs = await makeDirs();
  const config = rawConfig(dirs.root);
  let gw = await spawnGateway(config, { configDir: dirs.base });
  try {
    let ws = (await connect(gw.url, auth())).ws;
    const { sessionId } = await useProject(gw, ws, dirs.project);
    const keep = (await rpc(ws, 'session/new', { cwd: dirs.project, mcpServers: [] })).result.sessionId;
    await rpc(ws, 'session/prompt', { sessionId, prompt: [{ type: 'text', text: 'hello' }] });
    await rpc(ws, '_acpcode/sessions/read', { sessionId, seq: 2 });
    const before = await index(ws);
    ws.close();
    await gw.stop();

    gw = await spawnGateway(config, { configDir: dirs.base });
    ws = (await connect(gw.url, auth())).ws;
    assert.deepEqual(await index(ws), before, 'the same index from the database');
    await gw.settle();
    assert.equal(gw.spawned(), 0, 'index started no agent after the restart');

    await rpc(ws, 'session/load', { sessionId, cwd: dirs.project, mcpServers: [] });
    assert.deepEqual((await rpc(ws, 'session/delete', { sessionId })).result, {});
    assert.deepEqual((await index(ws)).map((s) => s.sessionId), [keep]);
    assert.deepEqual((await rpc(ws, '_acpcode/sessions/read', { sessionId, seq: 1 })).error.message, 'unknown session');
    ws.close();
  } finally {
    await gw.stop();
    await dirs.cleanup();
  }
});
