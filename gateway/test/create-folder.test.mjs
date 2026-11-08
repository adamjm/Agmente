// Folder creation from the phone over the wire (D-091): `_acpcode/projects/create` with
// `createFolder: true` makes <path>/<name> and registers it. The path-based call is unchanged.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdirSync, readdirSync, readFileSync, rmdirSync, statSync } from 'node:fs';
import { mkdir, symlink, writeFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { auth, connect, rpc, startGateway } from './helpers.mjs';

const create = (ws, params) => rpc(ws, '_acpcode/projects/create', params);
const folderParams = (gw, name, extra = {}) => ({ createFolder: true, name, path: gw.dirs.root, ...extra });

test('createFolder makes <path>/<name> with mode 0755, registers it and audits the creation', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    const res = await create(ws, folderParams(gw, 'Fresh project', { defaultMode: 'plan' }));
    assert.equal(res.error, undefined, JSON.stringify(res.error));
    const { project } = res.result;
    const folder = join(gw.dirs.root, 'Fresh project');
    assert.deepEqual(project, { id: project.id, name: 'Fresh project', path: folder, defaultMode: 'plan' });
    assert.match(project.id, /^[0-9a-f]{12}$/);
    assert.equal(statSync(folder).isDirectory(), true);
    assert.equal(statSync(folder).mode & 0o777, 0o755);

    // Registered like any other project: a HOME with a trust entry for the new folder.
    const home = join(gw.config.stateDir, 'homes', project.id);
    assert.equal(statSync(home).mode & 0o777, 0o700);
    const trust = JSON.parse(readFileSync(join(home, '.bob', 'trustedFolders.json'), 'utf8'));
    assert.deepEqual(trust, { version: 1, folders: { [folder]: 'TRUST_FOLDER' } });

    // The new project takes a session at once.
    const session = await rpc(ws, 'session/new', { cwd: folder, mcpServers: [] });
    assert.equal(typeof session.result?.sessionId, 'string', JSON.stringify(session.error));

    const list = (await rpc(ws, '_acpcode/projects/list', {})).result.projects;
    assert.deepEqual(list.map((p) => p.id), [project.id]);

    const line = await gw.waitForAudit((l) => l.event === 'project_created' && l.project === project.id);
    assert.equal(line.folderCreated, true);
    assert.equal(line.identity, 'owner');
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('the name rules: single component, no leading dot, no empty, at most 64, the allowed characters only', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    const bad = [
      ['', /must not be empty/],
      ['.', /must not start with a dot/],
      ['..', /must not start with a dot/],
      ['.hidden', /must not start with a dot/],
      ['a/b', /may contain only/],
      ['x/../escape', /may contain only/],
      ['../escape', /must not start with a dot/],
      ['a\\b', /may contain only/],
      ['a\nb', /may contain only/],
      ['a\u0000b', /may contain only/],
      ['a*b', /may contain only/],
      ['a:b', /may contain only/],
      ['café', /may contain only/],
      [' lead', /must not start or end with a space/],
      ['trail ', /must not start or end with a space/],
      ['x'.repeat(65), /at most 64 characters/],
      [7, /folder name must be a string/],
      [null, /folder name must be a string/],
    ];
    for (const [name, message] of bad) {
      const res = await create(ws, folderParams(gw, name));
      assert.equal(res.error?.code, -32602, JSON.stringify(name));
      assert.match(res.error.message, message, JSON.stringify(name));
    }
    // Nothing was created in the root, and nothing was registered.
    assert.deepEqual(readdirSync(gw.dirs.root).sort(), ['project']);
    assert.deepEqual((await rpc(ws, '_acpcode/projects/list', {})).result.projects, []);

    // The edges that are allowed: 64 characters, every allowed character class.
    for (const name of ['x'.repeat(64), 'My-app_v1.2 beta']) {
      const res = await create(ws, folderParams(gw, name));
      assert.equal(res.error, undefined, JSON.stringify(name));
      assert.equal(res.result.project.name, name);
      assert.equal(statSync(join(gw.dirs.root, name)).isDirectory(), true);
    }
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('a parent outside the roots is refused, and so is a path that is not clean', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    const sibling = `${gw.dirs.root}-evil`;
    await mkdir(sibling);
    const cases = [
      [gw.dirs.outside, /outside the allowed project roots/],
      [gw.dirs.base, /outside the allowed project roots/],
      [sibling, /outside the allowed project roots/],
      ['/', /outside the allowed project roots/],
      [`${gw.dirs.root}/../outside`, /must be clean/],
      [`${gw.dirs.root}/`, /must be clean/],
      [join(gw.dirs.root, 'missing'), /does not exist/],
      [join(gw.dirs.project, 'a-file'), /must be a directory/],
      ['relative/root', /must be an absolute path/],
      [null, /must be an absolute path/],
    ];
    await writeFile(join(gw.dirs.project, 'a-file'), 'x');
    for (const [path, message] of cases) {
      const res = await create(ws, { createFolder: true, name: 'new-one', path });
      assert.equal(res.error?.code, -32602, JSON.stringify(path));
      assert.match(res.error.message, message, JSON.stringify(path));
    }
    assert.equal(existsSync(join(gw.dirs.outside, 'new-one')), false);
    assert.equal(existsSync(join(sibling, 'new-one')), false);
    assert.equal(existsSync(join(gw.dirs.root, 'new-one')), false);
    assert.deepEqual((await rpc(ws, '_acpcode/projects/list', {})).result.projects, []);
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('a symbolic link anywhere in the parent path is refused, and no folder is made through it', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    // A link inside the root to a folder inside the root: its realpath is inside, but the path
    // sent names the link, so it is refused.
    const inside = join(gw.dirs.root, 'link-to-project');
    await symlink(gw.dirs.project, inside);
    // A link inside the root to a folder outside it.
    const escape = join(gw.dirs.root, 'escape');
    await symlink(gw.dirs.outside, escape);
    // A link as a middle component: root/link-to-project/sub is not clean as sent.
    await mkdir(join(gw.dirs.project, 'sub'));
    const cases = [
      [inside, /must not contain a symbolic link/],
      [escape, /must not contain a symbolic link/],
      [join(inside, 'sub'), /must not contain a symbolic link/],
    ];
    for (const [path] of cases) {
      const res = await create(ws, { createFolder: true, name: 'via-link', path });
      assert.equal(res.error?.code, -32602, path);
      assert.match(res.error.message, /must not contain a symbolic link/, path);
    }
    assert.equal(existsSync(join(gw.dirs.project, 'via-link')), false, 'nothing was created through the link');
    assert.equal(existsSync(join(gw.dirs.outside, 'via-link')), false);
    assert.equal(existsSync(join(gw.dirs.project, 'sub', 'via-link')), false);
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('a name that already exists is refused in create mode, whatever it is, and the folder is not touched', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    // The existing project folder, by name.
    const existing = await create(ws, folderParams(gw, 'project'));
    assert.equal(existing.error?.code, -32602);
    assert.match(existing.error.message, /already exists/);
    assert.deepEqual((await rpc(ws, '_acpcode/projects/list', {})).result.projects, []);

    // A file of that name, and a symbolic link of that name (even a dangling one): both exist.
    await writeFile(join(gw.dirs.root, 'notes'), 'keep me');
    await symlink(join(gw.dirs.root, 'nowhere'), join(gw.dirs.root, 'dangling'));
    for (const name of ['notes', 'dangling']) {
      const res = await create(ws, folderParams(gw, name));
      assert.equal(res.error?.code, -32602, name);
      assert.match(res.error.message, /already exists/, name);
    }
    assert.equal(readFileSync(join(gw.dirs.root, 'notes'), 'utf8'), 'keep me');

    // Creating the same name twice: the second is refused.
    assert.equal((await create(ws, folderParams(gw, 'once'))).error, undefined);
    const again = await create(ws, folderParams(gw, 'once'));
    assert.equal(again.error?.code, -32602);
    assert.match(again.error.message, /already exists/);
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('a folder that is registered but no longer on disk is refused as a duplicate, not created again', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    const { project } = (await create(ws, folderParams(gw, 'gone'))).result;
    await rm(join(gw.dirs.root, 'gone'), { recursive: true });
    const res = await create(ws, folderParams(gw, 'gone'));
    assert.equal(res.error?.code, -32602);
    assert.match(res.error.message, /already registered/);
    assert.deepEqual(res.error.data, { projectId: project.id });
    assert.equal(existsSync(join(gw.dirs.root, 'gone')), false, 'the refused request made no folder');
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('createFolder must be a JSON boolean', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    for (const createFolder of ['true', 1, {}]) {
      const res = await create(ws, { createFolder, name: 'x', path: gw.dirs.root });
      assert.equal(res.error?.code, -32602, JSON.stringify(createFolder));
      assert.match(res.error.message, /createFolder must be true or false/);
    }
    assert.equal(existsSync(join(gw.dirs.root, 'x')), false);
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('the path-based call is unchanged: an existing folder, the project name rules, no folder made', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    // createFolder false and absent behave the same: the path is the project folder.
    const plain = await create(ws, { name: '  Plain  ', path: gw.dirs.project, createFolder: false });
    assert.equal(plain.error, undefined, JSON.stringify(plain.error));
    assert.deepEqual(plain.result.project, { id: plain.result.project.id, name: 'Plain', path: gw.dirs.project, defaultMode: null });
    assert.deepEqual(Object.keys(plain.result.project).sort(), ['defaultMode', 'id', 'name', 'path']);
    const line = await gw.waitForAudit((l) => l.event === 'project_created' && l.project === plain.result.project.id);
    assert.equal(line.folderCreated, undefined, 'no folderCreated field on a path-based create');

    // The folder rules do not apply to the project name in path mode (name up to 100, any text).
    const longName = 'Long name / with slash '.repeat(4).trim();
    assert.ok(longName.length > 64 && longName.length <= 100);
    const second = await create(ws, { name: longName, path: gw.dirs.root });
    assert.equal(second.error, undefined, JSON.stringify(second.error));
    assert.equal(second.result.project.name, longName);

    // Path-based refusals keep their messages.
    const missing = await create(ws, { name: 'x', path: join(gw.dirs.root, 'missing') });
    assert.match(missing.error.message, /does not exist/);
    const dup = await create(ws, { name: 'again', path: gw.dirs.project });
    assert.match(dup.error.message, /already registered/);
    assert.deepEqual(readdirSync(gw.dirs.root).sort(), ['project'], 'no folder was created by the path-based calls');
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('projects/roots lists the configured roots that exist, as realpaths, and only to an authenticated client', async () => {
  let second = '';
  const gw = await startGateway({}, {
    configFn: (dirs, config) => {
      second = join(dirs.base, 'second-root');
      mkdirSync(second);
      config.projects.roots = [dirs.root, join(dirs.base, 'missing-root'), second, dirs.root];
    },
  });
  try {
    const { ws } = await connect(gw.url, auth());
    const res = await rpc(ws, '_acpcode/projects/roots', {});
    // The missing root and the repeated root are left out.
    assert.deepEqual(res.result, { roots: [gw.dirs.root, second] });
    // A root removed after start is no longer offered.
    rmdirSync(second);
    const after = await rpc(ws, '_acpcode/projects/roots', {});
    assert.deepEqual(after.result, { roots: [gw.dirs.root] });
    // Listing roots changes nothing.
    assert.deepEqual((await rpc(ws, '_acpcode/projects/list', {})).result.projects, []);
    ws.close();
  } finally {
    await gw.stop();
  }
  const unauthenticated = await startGateway();
  try {
    const res = await connect(unauthenticated.url, {});
    assert.equal(res.status, 401);
  } finally {
    await unauthenticated.stop();
  }
});
