// Project registry over the wire: T-25 (FR-17, PLAN 3.3, D-024).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync, statSync } from 'node:fs';
import { mkdir, symlink, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { auth, connect, dryRun, makeDirs, rawConfig, rpc, spawnGateway, startGateway, useProject } from './helpers.mjs';

const homesOf = (gw) => join(gw.config.stateDir, 'homes');

test('T-25: a project outside the roots, or reached through a symlink that leaves them, is refused', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    const escape = join(gw.dirs.root, 'escape');
    await symlink(gw.dirs.outside, escape);
    const sibling = `${gw.dirs.root}-evil`;
    await mkdir(sibling);
    const file = join(gw.dirs.project, 'a-file');
    await writeFile(file, 'x');
    const cases = [
      [gw.dirs.outside, /outside the allowed project roots/],
      [escape, /outside the allowed project roots/],
      [`${escape}/`, /outside the allowed project roots/],
      [sibling, /outside the allowed project roots/],
      [`${gw.dirs.project}/../../outside`, /outside the allowed project roots/],
      ['/', /outside the allowed project roots/],
      [join(gw.dirs.root, 'missing'), /does not exist/],
      [file, /must be a directory/],
      ['relative/path', /must be an absolute path/],
      ['', /must be an absolute path/],
      [42, /must be an absolute path/],
      [null, /must be an absolute path/],
    ];
    for (const [path, message] of cases) {
      const res = await rpc(ws, '_acpcode/projects/create', { name: 'x', path });
      assert.equal(res.error?.code, -32602, JSON.stringify(path));
      assert.match(res.error.message, message, JSON.stringify(path));
    }
    assert.deepEqual((await rpc(ws, '_acpcode/projects/list', {})).result, { projects: [] });
    assert.equal(existsSync(homesOf(gw)), false, 'no project home was created');
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('names and default modes are checked', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    for (const name of ['', '   ', 'a\nb', 'x'.repeat(101), 7, null]) {
      const res = await rpc(ws, '_acpcode/projects/create', { name, path: gw.dirs.project });
      assert.equal(res.error?.code, -32602, JSON.stringify(name));
      assert.match(res.error.message, /name must be/);
    }
    for (const defaultMode of ['Agent', '../x', 3, '']) {
      const res = await rpc(ws, '_acpcode/projects/create', { name: 'p', path: gw.dirs.project, defaultMode });
      assert.equal(res.error?.code, -32602, JSON.stringify(defaultMode));
      assert.match(res.error.message, /defaultMode must be/);
    }
    assert.deepEqual((await rpc(ws, '_acpcode/projects/list', {})).result.projects, []);
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('a project inside a root is registered with its realpath, a HOME and a trust entry', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    // Through a symlink that stays inside the root: stored as the target's realpath.
    const link = join(gw.dirs.root, 'link-to-project');
    await symlink(gw.dirs.project, link);
    const created = await rpc(ws, '_acpcode/projects/create', { name: '  My project  ', path: link, defaultMode: 'plan' });
    const { project } = created.result;
    assert.match(project.id, /^[0-9a-f]{12}$/);
    assert.deepEqual(project, { id: project.id, name: 'My project', path: gw.dirs.project, defaultMode: 'plan' });

    const home = join(homesOf(gw), project.id);
    assert.equal(statSync(home).mode & 0o777, 0o700);
    const trust = JSON.parse(readFileSync(join(home, '.bob', 'trustedFolders.json'), 'utf8'));
    assert.deepEqual(trust, { version: 1, folders: { [gw.dirs.project]: 'TRUST_FOLDER' } });
    assert.equal(statSync(join(home, '.bob', 'trustedFolders.json')).mode & 0o777, 0o600);

    // The same folder again, by either path, is refused and names the existing project.
    for (const path of [gw.dirs.project, link]) {
      const dup = await rpc(ws, '_acpcode/projects/create', { name: 'again', path });
      assert.equal(dup.error.code, -32602);
      assert.match(dup.error.message, /already registered/);
      assert.deepEqual(dup.error.data, { projectId: project.id });
    }

    const second = (await rpc(ws, '_acpcode/projects/create', { name: 'Root itself', path: gw.dirs.root })).result.project;
    assert.equal(second.defaultMode, null);
    const list = (await rpc(ws, '_acpcode/projects/list', {})).result.projects;
    assert.deepEqual(list.map((p) => p.id), [project.id, second.id]);

    const line = await gw.waitForAudit((l) => l.event === 'project_created' && l.project === project.id);
    assert.equal(line.identity, 'owner');
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('_acpcode/* requests are answered by the gateway and never reach the agent', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    await rpc(ws, '_acpcode/projects/list', {});
    const unknown = await rpc(ws, '_acpcode/nope', {});
    assert.deepEqual(unknown.error, { code: -32601, message: 'Method not found' });
    ws.send(JSON.stringify({ jsonrpc: '2.0', method: '_acpcode/projects/create', params: { name: 'n', path: gw.dirs.project } }));
    // A cwd outside the roots is still refused first, by the guard.
    const guarded = await rpc(ws, '_acpcode/projects/list', { cwd: gw.dirs.outside });
    assert.equal(guarded.error.code, -32602);
    assert.match(guarded.error.message, /cwd is outside/);
    // The notification created nothing.
    assert.deepEqual((await rpc(ws, '_acpcode/projects/list', {})).result.projects, []);
    // Now give the socket a project, and ask its agent what it received.
    await useProject(gw, ws);
    await rpc(ws, '_acpcode/projects/list', {});
    const received = await rpc(ws, '_test/received', {});
    assert.equal(received.result.methods.some((m) => m.startsWith('_acpcode/')), false);
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('projects persist across a gateway restart', async () => {
  const dirs = await makeDirs();
  const config = rawConfig(dirs.root);
  try {
    let gw = await spawnGateway(config, { configDir: dirs.base });
    let { ws } = await connect(gw.url, auth());
    const { project } = (await rpc(ws, '_acpcode/projects/create', { name: 'kept', path: dirs.project })).result;
    ws.close();
    await gw.stop();

    gw = await spawnGateway(config, { configDir: dirs.base });
    try {
      ({ ws } = await connect(gw.url, auth()));
      assert.deepEqual((await rpc(ws, '_acpcode/projects/list', {})).result.projects, [{ ...project }]);
      ws.close();
    } finally {
      await gw.stop();
    }
  } finally {
    await dirs.cleanup();
  }
});

test('stateDir is required and must be absolute', async () => {
  for (const stateDir of [undefined, 'relative/state', '/', 5]) {
    const raw = rawConfig('/srv/p');
    if (stateDir === undefined) delete raw.stateDir;
    else raw.stateDir = stateDir;
    const run = await dryRun(raw);
    assert.notEqual(run.status, 0, String(stateDir));
    assert.match(run.stderr, /stateDir must be an absolute path/, String(stateDir));
  }
  const ok = await dryRun(rawConfig('/srv/p', { stateDir: '/var/lib/acpcode/state/' }));
  assert.equal(ok.status, 0, ok.stderr);
  assert.equal(JSON.parse(ok.stdout.slice(0, ok.stdout.lastIndexOf('}') + 1)).stateDir, '/var/lib/acpcode/state');
});

test('the gateway refuses to start when it cannot open its database', async () => {
  const dirs = await makeDirs();
  try {
    const blocker = join(dirs.base, 'not-a-dir');
    await writeFile(blocker, 'x');
    await assert.rejects(spawnGateway(rawConfig(dirs.root, { stateDir: join(blocker, 'state') }), { configDir: dirs.base }), /exited with 1 before listening/);
  } finally {
    await dirs.cleanup();
  }
});
