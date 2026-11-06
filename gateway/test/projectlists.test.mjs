// Additive updates to a project's lists (FR-30, NFR-9, D-066): _agmente/projects/addDenyPaths and
// addWatchSkip. They use the create rules, merge case-insensitively, keep the 32-entry cap for the
// total, and can never remove an entry. The built-in lists always apply.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { auth, connect, makeDirs, rawConfig, rpc, sleep, spawnGateway, startGateway } from './helpers.mjs';

const git = (dir, ...args) => execFileSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@t', ...args], { cwd: dir, encoding: 'utf8' });
const put = (dir, name, text) => { mkdirSync(join(dir, name, '..'), { recursive: true }); writeFileSync(join(dir, name), text); };
const SECRET = 'UPDATE-SECRET-VALUE-55555';

async function setup(denyPaths) {
  const gw = await startGateway();
  const ws = (await connect(gw.url, auth())).ws;
  const params = { name: 'lists', path: gw.dirs.project };
  if (denyPaths !== undefined) params.denyPaths = denyPaths;
  const project = (await rpc(ws, '_agmente/projects/create', params)).result.project;
  return { gw, ws, dir: gw.dirs.project, project };
}

const addDeny = (ws, params) => rpc(ws, '_agmente/projects/addDenyPaths', params);
const addSkip = (ws, params) => rpc(ws, '_agmente/projects/addWatchSkip', params);
const storedDeny = async (ws, id) => (await rpc(ws, '_agmente/projects/list', {})).result.projects.find((p) => p.id === id)?.denyPaths;

test('addDenyPaths refusals change nothing', async () => {
  const { gw, ws, project } = await setup(['*.db']);
  try {
    const unknown = await addDeny(ws, { projectId: 'aaaaaaaaaaaa', denyPaths: ['*.pem'] });
    assert.equal(unknown.error?.code, -32602);
    assert.match(unknown.error.message, /unknown project/);
    assert.equal((await addDeny(ws, { denyPaths: ['*.pem'] })).error?.code, -32602, 'projectId is required');
    assert.equal((await addDeny(ws, { projectId: project.id })).error?.code, -32602, 'denyPaths is required');
    for (const denyPaths of [null, '*.pem', { a: 1 }, [1], [null]]) {
      const res = await addDeny(ws, { projectId: project.id, denyPaths });
      assert.equal(res.error?.code, -32602, JSON.stringify(denyPaths));
      assert.match(res.error.message, /denyPaths/, JSON.stringify(denyPaths));
    }
    for (const entry of ['/etc/passwd', '../x', '!.env', '**/x', '[a]', 'café', 'a/']) {
      const res = await addDeny(ws, { projectId: project.id, denyPaths: ['*.pem', entry] });
      assert.equal(res.error?.code, -32602, JSON.stringify(entry));
      assert.match(res.error.message, /denyPaths/, JSON.stringify(entry));
    }
    assert.deepEqual(await storedDeny(ws, project.id), ['*.db'], 'nothing was added');
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('addDenyPaths keeps the 32-entry cap for the stored total', async () => {
  const { gw, ws, project } = await setup(Array.from({ length: 30 }, (_, i) => `f${i}`));
  try {
    const over = await addDeny(ws, { projectId: project.id, denyPaths: ['g1', 'g2', 'g3'] });
    assert.equal(over.error?.code, -32602);
    assert.match(over.error.message, /at most 32/);
    assert.equal((await storedDeny(ws, project.id)).length, 30, 'a refused request adds none of its entries');
    const exact = await addDeny(ws, { projectId: project.id, denyPaths: ['g1', 'g2'] });
    assert.equal(exact.result.project.denyPaths.length, 32, 'the total may reach 32');
    assert.equal((await addDeny(ws, { projectId: project.id, denyPaths: ['g3'] })).error?.code, -32602);
    assert.equal((await addDeny(ws, { projectId: project.id, denyPaths: ['f0'] })).result.project.denyPaths.length, 32, 'a duplicate needs no room');
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('addDenyPaths merges case-insensitively, keeps the stored spelling, and never removes an entry', async () => {
  const { gw, ws, project } = await setup(['*.db', 'config/prod.yml']);
  try {
    const added = await addDeny(ws, { projectId: project.id, denyPaths: ['*.DB', 'vault/*'] });
    assert.deepEqual(added.result.project.denyPaths, ['*.db', 'config/prod.yml', 'vault/*']);
    assert.deepEqual(await storedDeny(ws, project.id), ['*.db', 'config/prod.yml', 'vault/*']);
    const empty = await addDeny(ws, { projectId: project.id, denyPaths: [] });
    assert.deepEqual(empty.result.project, added.result.project, 'an empty list changes nothing');
    assert.deepEqual(await storedDeny(ws, project.id), ['*.db', 'config/prod.yml', 'vault/*'], 'no entry was removed');
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('an addDenyPaths takes effect at once in git/diff, and the built-ins stay active', async () => {
  const { gw, ws, dir, project } = await setup();
  try {
    git(dir, 'init', '-q', '-b', 'main');
    for (const n of ['data.db', 'notes.txt', '.env']) put(dir, n, 'old\n');
    git(dir, 'add', '-f', '.');
    git(dir, 'commit', '-q', '-m', 'first');
    for (const n of ['data.db', 'notes.txt', '.env']) put(dir, n, `old\n${SECRET}\n`);
    await rpc(ws, '_agmente/git/status', { projectId: project.id });
    const before = (await rpc(ws, '_agmente/git/diff', { projectId: project.id, path: 'data.db' })).result;
    assert.match(before.diff, new RegExp(SECRET), 'before the addition the file is shown');

    assert.equal((await addDeny(ws, { projectId: project.id, denyPaths: ['*.db'] })).error, undefined);
    const after = (await rpc(ws, '_agmente/git/diff', { projectId: project.id, path: 'data.db' })).result;
    assert.deepEqual(after.hidden, ['data.db']);
    assert.doesNotMatch(after.diff, new RegExp(SECRET), 'the addition hides it on the next diff');
    const notes = (await rpc(ws, '_agmente/git/diff', { projectId: project.id, path: 'notes.txt' })).result;
    assert.match(notes.diff, new RegExp(SECRET), 'a name off both lists is still shown');
    const env = (await rpc(ws, '_agmente/git/diff', { projectId: project.id, path: '.env' })).result;
    assert.deepEqual(env.hidden, ['.env'], 'a built-in is still hidden after an addition');
    assert.equal(env.diff, 'secret file changed: .env (content hidden)\n');
    const whole = (await rpc(ws, '_agmente/git/diff', { projectId: project.id })).result;
    assert.deepEqual(whole.hidden, ['.env', 'data.db']);
    assert.equal(whole.diff.split(SECRET).length - 1, 1, 'only notes.txt shows its content in the whole-tree diff');
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('addDenyPaths and addWatchSkip persist across a gateway restart', async () => {
  const dirs = await makeDirs();
  const config = rawConfig(dirs.root);
  try {
    let gw = await spawnGateway(config, { configDir: dirs.base });
    let { ws } = await connect(gw.url, auth());
    const { project } = (await rpc(ws, '_agmente/projects/create', { name: 'kept', path: dirs.project, denyPaths: ['*.db'] })).result;
    await addDeny(ws, { projectId: project.id, denyPaths: ['config/prod.yml'] });
    await addSkip(ws, { projectId: project.id, watchSkip: ['cache'] });
    ws.close();
    await gw.stop();

    gw = await spawnGateway(config, { configDir: dirs.base });
    try {
      ({ ws } = await connect(gw.url, auth()));
      const [kept] = (await rpc(ws, '_agmente/projects/list', {})).result.projects;
      assert.deepEqual(kept.denyPaths, ['*.db', 'config/prod.yml']);
      assert.deepEqual(kept.watchSkip, ['cache']);
      ws.close();
    } finally {
      await gw.stop();
    }
  } finally {
    await dirs.cleanup();
  }
});

test('addWatchSkip uses the same rules, returns the project, and a running watch honours it at once', async () => {
  const { gw, ws, dir, project } = await setup();
  try {
    for (const watchSkip of [['*.db'], ['**'], ['../x'], 'cache', null]) {
      const res = await rpc(ws, '_agmente/projects/addWatchSkip', { projectId: project.id, watchSkip });
      assert.equal(res.error?.code, -32602, JSON.stringify(watchSkip));
      assert.match(res.error.message, /watchSkip/, JSON.stringify(watchSkip));
    }
    assert.equal((await rpc(ws, '_agmente/projects/addWatchSkip', { projectId: 'aaaaaaaaaaaa', watchSkip: ['cache'] })).error?.code, -32602);
    const seen = [];
    ws.on('message', (d) => {
      const m = JSON.parse(d.toString());
      if (m.method === '_agmente/git/changed') seen.push(m.params);
    });
    git(dir, 'init', '-q', '-b', 'main');
    put(dir, 'a.txt', 'one\n');
    git(dir, 'add', '.');
    git(dir, 'commit', '-q', '-m', 'first');
    await rpc(ws, '_agmente/git/status', { projectId: project.id });
    const added = await rpc(ws, '_agmente/projects/addWatchSkip', { projectId: project.id, watchSkip: ['cache'] });
    assert.deepEqual(added.result.project.watchSkip, ['cache']);
    put(dir, 'cache/x.bin', 'x\n');
    await sleep(1800);
    assert.deepEqual(seen, [], 'a folder added to the list starts no check');
    put(dir, 'a.txt', 'two\n');
    for (let i = 0; i < 80 && seen.length === 0; i += 1) await sleep(100);
    assert.equal(seen.length, 1, 'a watched file still notifies');
    ws.close();
  } finally {
    await gw.stop();
  }
});
