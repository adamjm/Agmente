// MCP config list and disable (FR-41, D-084, D-085, D-086, SPEC 6.2). Wire-level: a real project
// folder and home, the gateway as a process, and the methods over the ACP socket.
// This suite passes only after the main session wires `serveMCPConfig` into handleExtension.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, readdirSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { auth, connect, rpc, startGateway } from './helpers.mjs';

const SECRET = 'MCP-SECRET-VALUE-7777';
const INVALID_PARAMS = -32602;

const FIXTURE = {
  theme: 'dark',
  mcpServers: {
    docs: { command: 'node', args: ['docs.js'], custom: { keep: 1 } },
    web: {
      url: 'https://secret.example.test/mcp',
      headers: { Authorization: `Bearer ${SECRET}` },
      alwaysAllow: ['search'],
    },
  },
};

/** A gateway, a connected phone, and one project. Returns the paths the tests write to. */
async function setup() {
  const gw = await startGateway({});
  const { ws } = await connect(gw.url, auth());
  const project = gw.dirs.project;
  const created = await rpc(ws, '_agmente/projects/create', { name: 'mcp', path: project });
  assert.ok(created.result?.project, JSON.stringify(created));
  const id = created.result.project.id;
  const home = join(gw.config.stateDir, 'homes', id);
  const paths = {
    projectFile: join(project, '.bob', 'mcp.json'),
    homeFile: join(home, '.bob', 'settings', 'mcp.json'),
    projectBob: join(project, '.bob'),
    homeSettings: join(home, '.bob', 'settings'),
  };
  mkdirSync(paths.homeSettings, { recursive: true });
  return { gw, ws, id, paths, outside: gw.dirs.outside };
}

async function stopAll(ctx) {
  ctx.ws.close();
  await ctx.gw.stop();
}

function write(path, data) {
  mkdirSync(join(path, '..'), { recursive: true, mode: 0o700 });
  writeFileSync(path, typeof data === 'string' ? data : JSON.stringify(data, null, 2));
}

const readJSON = (path) => JSON.parse(readFileSync(path, 'utf8'));

test('mcp list: both sources, name, disabled, alwaysAllow count, source and transport; no secrets', async () => {
  const ctx = await setup();
  try {
    write(ctx.paths.projectFile, FIXTURE);
    write(ctx.paths.homeFile, { mcpServers: { 'home-tool': { command: 'uvx', disabled: true, alwaysAllow: [] } } });
    const res = await rpc(ctx.ws, '_agmente/mcp/list', { projectId: ctx.id });
    assert.ok(res.result, JSON.stringify(res));
    const body = JSON.stringify(res.result);
    assert.equal(body.includes(SECRET), false, 'a header value reached the phone');
    assert.equal(body.includes('secret.example.test'), false, 'a URL reached the phone');
    assert.equal(body.includes('headers'), false);
    const byKey = Object.fromEntries(res.result.servers.map((s) => [`${s.source}/${s.name}`, s]));
    assert.deepEqual(byKey['project/docs'], { name: 'docs', disabled: false, alwaysAllow: 0, source: 'project', transport: 'stdio' });
    assert.deepEqual(byKey['project/web'], { name: 'web', disabled: false, alwaysAllow: 1, source: 'project', transport: 'http' });
    assert.deepEqual(byKey['home/home-tool'], { name: 'home-tool', disabled: true, alwaysAllow: 0, source: 'home', transport: 'stdio' });
  } finally {
    await stopAll(ctx);
  }
});

test('mcp list: no config files give an empty list', async () => {
  const ctx = await setup();
  try {
    const res = await rpc(ctx.ws, '_agmente/mcp/list', { projectId: ctx.id });
    assert.deepEqual(res.result, { servers: [] });
  } finally {
    await stopAll(ctx);
  }
});

test('mcp set: disable, then enable; other keys and the secret entries stay as they were', async () => {
  const ctx = await setup();
  try {
    write(ctx.paths.projectFile, FIXTURE);
    const off = await rpc(ctx.ws, '_agmente/mcp/set', { projectId: ctx.id, name: 'web', disabled: true });
    assert.ok(off.result, JSON.stringify(off));
    let file = readJSON(ctx.paths.projectFile);
    assert.equal(file.mcpServers.web.disabled, true);
    assert.equal(file.mcpServers.web.url, 'https://secret.example.test/mcp');
    assert.equal(file.theme, 'dark');
    assert.deepEqual(file.mcpServers.docs.custom, { keep: 1 });

    const on = await rpc(ctx.ws, '_agmente/mcp/set', { projectId: ctx.id, name: 'web', disabled: false });
    assert.ok(on.result, JSON.stringify(on));
    file = readJSON(ctx.paths.projectFile);
    assert.equal(file.mcpServers.web.disabled, false);
    assert.deepEqual(file.mcpServers.web.alwaysAllow, ['search']);
  } finally {
    await stopAll(ctx);
  }
});

test('mcp set on a server only in the home file changes the home file', async () => {
  const ctx = await setup();
  try {
    write(ctx.paths.homeFile, { mcpServers: { 'home-tool': { command: 'uvx' } } });
    const res = await rpc(ctx.ws, '_agmente/mcp/set', { projectId: ctx.id, name: 'home-tool', disabled: true, source: 'home' });
    assert.ok(res.result, JSON.stringify(res));
    assert.equal(readJSON(ctx.paths.homeFile).mcpServers['home-tool'].disabled, true);
  } finally {
    await stopAll(ctx);
  }
});

test('mcp set on a name that is not in the file is refused and adds nothing (D-084)', async () => {
  const ctx = await setup();
  try {
    write(ctx.paths.projectFile, FIXTURE);
    const before = readFileSync(ctx.paths.projectFile, 'utf8');
    const res = await rpc(ctx.ws, '_agmente/mcp/set', { projectId: ctx.id, name: 'absent', disabled: true });
    assert.equal(res.error?.code, INVALID_PARAMS, JSON.stringify(res));
    assert.equal(readFileSync(ctx.paths.projectFile, 'utf8'), before);
    rmSync(ctx.paths.projectFile);
    const none = await rpc(ctx.ws, '_agmente/mcp/set', { projectId: ctx.id, name: 'docs', disabled: true });
    assert.equal(none.error?.code, INVALID_PARAMS);
    assert.equal(readdirSync(ctx.paths.projectBob).length, 0);
  } finally {
    await stopAll(ctx);
  }
});

test('mcp set with alwaysAllow writes the list (D-089); mcp list reports the count, never the names', async () => {
  const ctx = await setup();
  try {
    write(ctx.paths.projectFile, FIXTURE);
    const res = await rpc(ctx.ws, '_agmente/mcp/set', { projectId: ctx.id, name: 'web', disabled: false, alwaysAllow: ['tool-alpha', 'tool-beta'] });
    assert.ok(res.result, JSON.stringify(res));
    const file = readJSON(ctx.paths.projectFile);
    assert.deepEqual(file.mcpServers.web.alwaysAllow, ['tool-alpha', 'tool-beta']);
    assert.equal(file.mcpServers.web.url, 'https://secret.example.test/mcp');
    const list = await rpc(ctx.ws, '_agmente/mcp/list', { projectId: ctx.id });
    const web = list.result.servers.find((s) => s.name === 'web' && s.source === 'project');
    assert.equal(web.alwaysAllow, 2);
    assert.equal(JSON.stringify(list.result).includes('tool-alpha'), false, 'a tool name reached the phone');
    assert.equal(JSON.stringify(ctx.gw.audit).includes('tool-alpha'), false, 'a tool name reached the audit log');
    const line = ctx.gw.audit.filter((a) => a.event === 'mcp_set').at(-1);
    assert.match(line.reason, /alwaysAllow=2/);

    const cleared = await rpc(ctx.ws, '_agmente/mcp/set', { projectId: ctx.id, name: 'web', disabled: false, alwaysAllow: [] });
    assert.ok(cleared.result, JSON.stringify(cleared));
    assert.deepEqual(readJSON(ctx.paths.projectFile).mcpServers.web.alwaysAllow, []);
  } finally {
    await stopAll(ctx);
  }
});

test('mcp set refuses a bad alwaysAllow (D-089) and the file is unchanged', async () => {
  const ctx = await setup();
  try {
    write(ctx.paths.projectFile, FIXTURE);
    const before = readFileSync(ctx.paths.projectFile, 'utf8');
    const bad = [
      'search',
      ['search', 7],
      [''],
      ['x'.repeat(129)],
      Array.from({ length: 65 }, (_, i) => `t${i}`),
    ];
    for (const alwaysAllow of bad) {
      const res = await rpc(ctx.ws, '_agmente/mcp/set', { projectId: ctx.id, name: 'web', disabled: true, alwaysAllow });
      assert.equal(res.error?.code, INVALID_PARAMS, JSON.stringify(res));
      assert.match(res.error.message, /alwaysAllow/);
    }
    assert.equal(readFileSync(ctx.paths.projectFile, 'utf8'), before);
  } finally {
    await stopAll(ctx);
  }
});

test('mcp set writes mode 0600 and leaves no temp file', async () => {
  const ctx = await setup();
  try {
    write(ctx.paths.projectFile, FIXTURE);
    const res = await rpc(ctx.ws, '_agmente/mcp/set', { projectId: ctx.id, name: 'docs', disabled: true });
    assert.ok(res.result, JSON.stringify(res));
    assert.equal(statSync(ctx.paths.projectFile).mode & 0o777, 0o600);
    assert.deepEqual(readdirSync(ctx.paths.projectBob), ['mcp.json']);
  } finally {
    await stopAll(ctx);
  }
});

test('mcp: a symlinked folder in the path is refused and the target is not written', async () => {
  const ctx = await setup();
  try {
    const outsideBob = join(ctx.outside, 'bob');
    write(join(outsideBob, 'mcp.json'), FIXTURE);
    symlinkSync(outsideBob, ctx.paths.projectBob);
    const before = readFileSync(join(outsideBob, 'mcp.json'), 'utf8');
    const list = await rpc(ctx.ws, '_agmente/mcp/list', { projectId: ctx.id });
    assert.equal(list.error?.code, INVALID_PARAMS, JSON.stringify(list));
    const set = await rpc(ctx.ws, '_agmente/mcp/set', { projectId: ctx.id, name: 'docs', disabled: true });
    assert.equal(set.error?.code, INVALID_PARAMS, JSON.stringify(set));
    assert.equal(readFileSync(join(outsideBob, 'mcp.json'), 'utf8'), before);
  } finally {
    await stopAll(ctx);
  }
});

test('mcp: a file that is a symlink to a file outside is refused', async () => {
  const ctx = await setup();
  try {
    const target = join(ctx.outside, 'mcp.json');
    write(target, FIXTURE);
    mkdirSync(ctx.paths.projectBob, { recursive: true });
    symlinkSync(target, ctx.paths.projectFile);
    const before = readFileSync(target, 'utf8');
    const set = await rpc(ctx.ws, '_agmente/mcp/set', { projectId: ctx.id, name: 'docs', disabled: true });
    assert.equal(set.error?.code, INVALID_PARAMS, JSON.stringify(set));
    const list = await rpc(ctx.ws, '_agmente/mcp/list', { projectId: ctx.id });
    assert.equal(list.error?.code, INVALID_PARAMS);
    assert.equal(readFileSync(target, 'utf8'), before);
  } finally {
    await stopAll(ctx);
  }
});

test('mcp: a file over 256 KiB is refused', async () => {
  const ctx = await setup();
  try {
    write(ctx.paths.projectFile, ' '.repeat(256 * 1024) + JSON.stringify(FIXTURE));
    const list = await rpc(ctx.ws, '_agmente/mcp/list', { projectId: ctx.id });
    assert.equal(list.error?.code, INVALID_PARAMS, JSON.stringify(list));
    const set = await rpc(ctx.ws, '_agmente/mcp/set', { projectId: ctx.id, name: 'docs', disabled: true });
    assert.equal(set.error?.code, INVALID_PARAMS);
  } finally {
    await stopAll(ctx);
  }
});

test('mcp: invalid JSON is refused', async () => {
  const ctx = await setup();
  try {
    write(ctx.paths.projectFile, '{"mcpServers": {"docs": ');
    const list = await rpc(ctx.ws, '_agmente/mcp/list', { projectId: ctx.id });
    assert.equal(list.error?.code, INVALID_PARAMS, JSON.stringify(list));
    const set = await rpc(ctx.ws, '_agmente/mcp/set', { projectId: ctx.id, name: 'docs', disabled: true });
    assert.equal(set.error?.code, INVALID_PARAMS);
  } finally {
    await stopAll(ctx);
  }
});

test('mcp: a file that is not regular (a named pipe) is refused and never opened', async () => {
  const ctx = await setup();
  try {
    mkdirSync(ctx.paths.projectBob, { recursive: true });
    execFileSync('mkfifo', [ctx.paths.projectFile]);
    const list = await rpc(ctx.ws, '_agmente/mcp/list', { projectId: ctx.id });
    assert.equal(list.error?.code, INVALID_PARAMS, JSON.stringify(list));
  } finally {
    await stopAll(ctx);
  }
});

test('mcp: the audit line names the project, the server and the value, never the file', async () => {
  const ctx = await setup();
  try {
    write(ctx.paths.projectFile, FIXTURE);
    const res = await rpc(ctx.ws, '_agmente/mcp/set', { projectId: ctx.id, name: 'web', disabled: true });
    assert.ok(res.result, JSON.stringify(res));
    const line = ctx.gw.audit.find((a) => a.event === 'mcp_set');
    assert.ok(line, 'no mcp_set line');
    assert.equal(line.project, ctx.id);
    assert.match(line.reason, /name=web/);
    assert.match(line.reason, /disabled=true/);
    assert.equal(JSON.stringify(ctx.gw.audit).includes(SECRET), false, 'a header value reached the audit log');
    assert.equal(JSON.stringify(ctx.gw.audit).includes('secret.example.test'), false);
  } finally {
    await stopAll(ctx);
  }
});

test('mcp: list and set need a known projectId', async () => {
  const ctx = await setup();
  try {
    const noId = await rpc(ctx.ws, '_agmente/mcp/list', {});
    assert.equal(noId.error?.code, INVALID_PARAMS, JSON.stringify(noId));
    const unknown = await rpc(ctx.ws, '_agmente/mcp/set', { projectId: 'nope', name: 'docs', disabled: true });
    assert.equal(unknown.error?.code, INVALID_PARAMS);
  } finally {
    await stopAll(ctx);
  }
});
