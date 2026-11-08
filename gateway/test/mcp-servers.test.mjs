// The gateway's own MCP server list (D-107): the phone lists it and picks ids per session; the
// gateway sends the full entries to the agent, per session, from the stored set. The Mac admin
// edits the list with `acpcode-gateway mcp-server`; these tests use that command, as the admin does.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { auth, connect, FAKE_AGENT, gatewayCommand, makeDirs, rawConfig, rpc, sleep, spawnGateway } from './helpers.mjs';

const DOCS = { name: 'docs', transport: 'http', url: 'https://mcp.example.test/mcp', headers: [{ name: 'X-Api-Key', value: 'SECRET-HEADER-7731' }], defaultEnabled: true };
const LOCAL = { name: 'local', transport: 'stdio', command: '/opt/acp/SECRET-CMD-4410', args: ['--token', 'SECRET-ARG-5520'], env: [{ name: 'API_KEY', value: 'SECRET-ENV-6631' }], defaultEnabled: false };
const SECRET_TEXT = ['SECRET-HEADER-7731', 'SECRET-CMD-4410', 'SECRET-ARG-5520', 'SECRET-ENV-6631', '/opt/acp'];

/** A gateway whose fake agent records every session request into recDir/calls.jsonl. */
async function boot() {
  const dirs = await makeDirs();
  const recDir = join(dirs.base, 'rec');
  const config = rawConfig(dirs.root, { agent: { command: [process.execPath, FAKE_AGENT], envPassthrough: ['PATH', 'ACPCODE_TEST_RECORD_DIR'] } });
  const h = { dirs, recDir, configFile: join(dirs.base, 'config.json'), gw: null };
  h.start = async () => {
    h.gw = await spawnGateway(config, { env: { ACPCODE_TEST_RECORD_DIR: recDir }, configDir: dirs.base });
    return h.gw;
  };
  h.stop = async () => {
    if (h.gw) await h.gw.stop();
    h.gw = null;
  };
  h.cleanup = async () => {
    await h.stop();
    await dirs.cleanup();
  };
  await h.start();
  return h;
}

/** Run the admin command against the same config, as the Mac admin would. */
function admin(h, args, stdin = '') {
  const [cmd, ...pre] = gatewayCommand();
  const run = spawnSync(cmd, [...pre, '--config', h.configFile, 'mcp-server', ...args], { input: stdin, encoding: 'utf8', timeout: 10_000 });
  return { status: run.status, stdout: run.stdout, stderr: run.stderr };
}

function putEntry(h, entry) {
  const res = admin(h, ['put'], JSON.stringify(entry));
  assert.equal(res.status, 0, res.stderr);
  return JSON.parse(res.stdout).id;
}

const calls = (h) => (existsSync(join(h.recDir, 'calls.jsonl')) ? readFileSync(join(h.recDir, 'calls.jsonl'), 'utf8').trim().split('\n').filter(Boolean).map((l) => JSON.parse(l)) : []);
const callsOf = (h, method) => calls(h).filter((c) => c.method === method);
const names = (params) => (params.mcpServers ?? []).map((s) => s.name);

async function project(h, ws) {
  const res = await rpc(ws, '_acpcode/projects/create', { name: 'test', path: h.dirs.project });
  assert.ok(res.result?.project, JSON.stringify(res));
}

async function newSession(h, ws, enabled) {
  const params = { cwd: h.dirs.project, mcpServers: [] };
  if (enabled) params._meta = { 'acpcode/mcpEnabled': enabled };
  const res = await rpc(ws, 'session/new', params);
  assert.ok(res.result?.sessionId, JSON.stringify(res));
  return res.result.sessionId;
}

const prompt = (ws, sessionId, text = 'hello') => rpc(ws, 'session/prompt', { sessionId, prompt: [{ type: 'text', text }] });

test('list: the phone sees names and transports, and no secret, command, argument or environment value', async () => {
  const h = await boot();
  try {
    putEntry(h, DOCS);
    putEntry(h, LOCAL);
    const { ws } = await connect(h.gw.url, auth());
    const res = await rpc(ws, '_acpcode/mcp/servers/list', {});
    const text = JSON.stringify(res.result);
    assert.deepEqual(res.result.servers.map((s) => [s.name, s.transport]), [['docs', 'http'], ['local', 'stdio']]);
    assert.equal(res.result.servers[0].url, 'https://mcp.example.test/mcp');
    for (const secret of SECRET_TEXT) assert.equal(text.includes(secret), false, `the list holds ${secret}`);
    assert.equal(text.includes('command'), false, 'the list holds no command field');
    assert.equal(text.includes('headers'), false);
    ws.close();
  } finally {
    await h.cleanup();
  }
});

test('put and delete are refused to every socket client, and the list does not change', async () => {
  const h = await boot();
  try {
    const id = putEntry(h, DOCS);
    const { ws } = await connect(h.gw.url, auth());
    const put = await rpc(ws, '_acpcode/mcp/servers/put', { name: 'phone', transport: 'http', url: 'https://x.example.test/mcp' });
    assert.equal(put.error?.code, -32001, JSON.stringify(put));
    assert.equal(put.error.data?.reason, 'admin_only');
    const del = await rpc(ws, '_acpcode/mcp/servers/delete', { id });
    assert.equal(del.error?.code, -32001, JSON.stringify(del));
    const list = await rpc(ws, '_acpcode/mcp/servers/list', {});
    assert.deepEqual(list.result.servers.map((s) => s.id), [id]);
    assert.ok(h.gw.audit.find((l) => l.event === 'mcp_refused' && l.reason === 'admin_only'));
    ws.close();
  } finally {
    await h.cleanup();
  }
});

test('session/new: an id the gateway does not have is refused with -32602, and the agent gets no session', async () => {
  const h = await boot();
  try {
    putEntry(h, DOCS);
    const { ws } = await connect(h.gw.url, auth());
    await project(h, ws);
    for (const bad of ['0'.repeat(32), 'not-an-id']) {
      const res = await rpc(ws, 'session/new', { cwd: h.dirs.project, mcpServers: [], _meta: { 'acpcode/mcpEnabled': [bad] } });
      assert.equal(res.error?.code, -32602, JSON.stringify(res));
    }
    assert.equal(callsOf(h, 'session/new').length, 0, 'no session reached the agent');
    ws.close();
  } finally {
    await h.cleanup();
  }
});

test('two sessions in one project carry different sets; a session with no ids takes the defaults', async () => {
  const h = await boot();
  try {
    const docsId = putEntry(h, DOCS);
    const localId = putEntry(h, LOCAL);
    const { ws } = await connect(h.gw.url, auth());
    await project(h, ws);
    const first = await newSession(h, ws, [docsId]);
    const second = await newSession(h, ws, [localId]);
    const third = await newSession(h, ws, null);
    assert.notEqual(first, second);
    const news = callsOf(h, 'session/new').map((c) => c.params);
    assert.deepEqual(news.map(names), [['docs'], ['local'], ['docs']], 'each session carries its own set; no ids means the defaults');
    const docsSent = news[0].mcpServers[0];
    assert.equal(docsSent.type, 'http');
    assert.equal(docsSent.url, DOCS.url);
    assert.deepEqual(docsSent.headers, [{ name: 'X-Api-Key', value: 'SECRET-HEADER-7731' }], 'the agent gets the header value');
    const localSent = news[1].mcpServers[0];
    assert.equal(localSent.command, LOCAL.command);
    assert.deepEqual(localSent.args, LOCAL.args);
    assert.deepEqual(localSent.env, LOCAL.env);
    assert.equal(news[0]._meta, undefined, 'the gateway removes its own _meta key before the agent sees it');
    const text = JSON.stringify(h.gw.audit);
    for (const secret of SECRET_TEXT) assert.equal(text.includes(secret), false, `the audit log holds ${secret}`);
    assert.ok(third);
    ws.close();
  } finally {
    await h.cleanup();
  }
});

test('setEnabled: refused while a turn is open; once it ends, the next prompt loads the new set', async () => {
  const h = await boot();
  try {
    const docsId = putEntry(h, DOCS);
    const localId = putEntry(h, LOCAL);
    const { ws } = await connect(h.gw.url, auth());
    await project(h, ws);
    const sid = await newSession(h, ws, [docsId]);
    const running = prompt(ws, sid, 'a long turn [chunks:4][slow:400]');
    await sleep(150);
    const refused = await rpc(ws, '_acpcode/mcp/servers/setEnabled', { sessionId: sid, ids: [localId] });
    assert.equal(refused.error?.code, -32001, JSON.stringify(refused));
    assert.equal(refused.error.data?.reason, 'turn_open');
    assert.equal((await running).result?.stopReason, 'end_turn');

    const set = await rpc(ws, '_acpcode/mcp/servers/setEnabled', { sessionId: sid, ids: [localId] });
    assert.deepEqual(set.result, { sessionId: sid, enabled: [localId], closed: true }, JSON.stringify(set));
    assert.equal((await prompt(ws, sid)).result?.stopReason, 'end_turn');
    const loads = callsOf(h, 'session/load');
    assert.equal(loads.length, 1, 'one load, sent by the gateway before the prompt');
    assert.deepEqual(names(loads[0].params), ['local'], 'the reload carries the new set only');
    assert.ok(callsOf(h, 'session/close').length >= 1, 'the session was closed in the agent first');
    ws.close();
  } finally {
    await h.cleanup();
  }
});

test('restart: each session keeps its set, and its next load carries it', async () => {
  const h = await boot();
  try {
    const docsId = putEntry(h, DOCS);
    const localId = putEntry(h, LOCAL);
    let { ws } = await connect(h.gw.url, auth());
    await project(h, ws);
    const one = await newSession(h, ws, [docsId]);
    const two = await newSession(h, ws, [localId]);
    assert.equal((await prompt(ws, one)).result?.stopReason, 'end_turn');
    assert.equal((await prompt(ws, two)).result?.stopReason, 'end_turn');
    ws.close();
    const before = calls(h).length;
    await h.stop();

    await h.start();
    ({ ws } = await connect(h.gw.url, auth()));
    assert.equal((await prompt(ws, two)).result?.stopReason, 'end_turn');
    assert.equal((await prompt(ws, one)).result?.stopReason, 'end_turn');
    const loads = calls(h).slice(before).filter((c) => c.method === 'session/load').map((c) => [c.params.sessionId, names(c.params)]);
    assert.deepEqual(loads, [[two, ['local']], [one, ['docs']]], 'each session reloads with its own set after the restart');
    ws.close();
  } finally {
    await h.cleanup();
  }
});

test('a removed entry is dropped with an audit line, and the session still works', async () => {
  const h = await boot();
  try {
    const docsId = putEntry(h, DOCS);
    const localId = putEntry(h, LOCAL);
    let { ws } = await connect(h.gw.url, auth());
    await project(h, ws);
    const sid = await newSession(h, ws, [docsId, localId]);
    assert.equal((await prompt(ws, sid)).result?.stopReason, 'end_turn');
    ws.close();
    await h.stop();

    assert.equal(admin(h, ['delete', docsId]).status, 0);
    await h.start();
    ({ ws } = await connect(h.gw.url, auth()));
    const res = await prompt(ws, sid);
    assert.equal(res.result?.stopReason, 'end_turn', 'the removed entry does not fail the turn');
    const loads = callsOf(h, 'session/load');
    assert.deepEqual(names(loads.at(-1).params), ['local'], 'the removed entry is not sent to the agent');
    const dropped = h.gw.audit.find((l) => l.event === 'mcp_missing');
    assert.equal(dropped?.reason, `id=${docsId}`, 'the audit line names the id only');
    assert.equal(JSON.stringify(h.gw.audit).includes('SECRET-HEADER-7731'), false);
    ws.close();
  } finally {
    await h.cleanup();
  }
});
