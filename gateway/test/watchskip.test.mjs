// Per-project git watcher skip list (FR-27, NFR-9, D-065): validated at create, stored, returned when
// set, and used by the stat poll to leave folders out. It only adds to the built-in folders.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { auth, connect, makeDirs, rawConfig, rpc, sleep, spawnGateway, startGateway, userProjects } from './helpers.mjs';

const git = (dir, ...args) => execFileSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@t', ...args], { cwd: dir, encoding: 'utf8' });
const put = (dir, name, text) => { mkdirSync(join(dir, name, '..'), { recursive: true }); writeFileSync(join(dir, name), text); };

/** A repository project with a watchSkip list, and a socket that has asked for its status. */
async function setup(watchSkip) {
  const gw = await startGateway();
  const dir = gw.dirs.project;
  git(dir, 'init', '-q', '-b', 'main');
  put(dir, 'a.txt', 'one\n');
  git(dir, 'add', '.');
  git(dir, 'commit', '-q', '-m', 'first');
  const ws = (await connect(gw.url, auth())).ws;
  const params = { name: 'p', path: dir };
  if (watchSkip !== undefined) params.watchSkip = watchSkip;
  const project = (await rpc(ws, '_acpcode/projects/create', params)).result.project;
  assert.ok(project, 'the project is created');
  return { gw, dir, ws, project };
}

function listen(ws) {
  const seen = [];
  ws.on('message', (d) => {
    const m = JSON.parse(d.toString());
    if (m.method === '_acpcode/git/changed') seen.push({ t: Date.now(), ...m.params });
  });
  return seen;
}

async function until(pred, what, ms = 8000) {
  for (const t0 = Date.now(); Date.now() - t0 < ms; await sleep(25)) if (pred()) return;
  throw new Error(`timed out waiting for ${what}`);
}

test('watchSkip is checked at create: refusals register nothing', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    const bad = ['*.db', '**/x', '/etc', '../x', 'a/', '!cache', '[a]', 'a\\b', 'café', 'a:b', 'x'.repeat(101)];
    for (const entry of bad) {
      const res = await rpc(ws, '_acpcode/projects/create', { name: 'p', path: gw.dirs.project, watchSkip: [entry] });
      assert.equal(res.error?.code, -32602, JSON.stringify(entry));
      assert.match(res.error.message, /watchSkip/, JSON.stringify(entry));
    }
    for (const watchSkip of ['cache', { a: 1 }, [1], [null]]) {
      const res = await rpc(ws, '_acpcode/projects/create', { name: 'p', path: gw.dirs.project, watchSkip });
      assert.equal(res.error?.code, -32602, JSON.stringify(watchSkip));
      assert.match(res.error.message, /watchSkip/, JSON.stringify(watchSkip));
    }
    const tooMany = Array.from({ length: 33 }, (_, i) => `f${i}`);
    const many = await rpc(ws, '_acpcode/projects/create', { name: 'p', path: gw.dirs.project, watchSkip: tooMany });
    assert.equal(many.error?.code, -32602);
    assert.deepEqual(userProjects((await rpc(ws, '_acpcode/projects/list', {})).result.projects), []);
    const edge = await rpc(ws, '_acpcode/projects/create', { name: 'p', path: gw.dirs.project, watchSkip: Array.from({ length: 32 }, (_, i) => `f${i}`) });
    assert.equal(edge.result.project.watchSkip.length, 32, 'the 32nd entry passes');
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('watchSkip is returned by create and list, and left out when empty', async () => {
  const { gw, ws, project } = await setup(['cache', 'out/tmp', 'cache']);
  try {
    assert.deepEqual(project.watchSkip, ['cache', 'out/tmp'], 'a duplicate is dropped');
    assert.deepEqual(userProjects((await rpc(ws, '_acpcode/projects/list', {})).result.projects), [project]);
    ws.close();
  } finally {
    await gw.stop();
  }
  const plain = await setup([]);
  try {
    assert.equal('watchSkip' in plain.project, false, 'no key when the list is empty');
    assert.equal(userProjects((await rpc(plain.ws, '_acpcode/projects/list', {})).result.projects)[0].watchSkip, undefined);
    plain.ws.close();
  } finally {
    await plain.gw.stop();
  }
});

test('a skipped folder starts no git/changed, but git/status still reports it', async () => {
  const { gw, dir, ws, project } = await setup(['cache', 'out/tmp']);
  try {
    const seen = listen(ws);
    await rpc(ws, '_acpcode/git/status', { projectId: project.id });
    put(dir, 'cache/x.bin', 'x\n');
    put(dir, 'out/tmp/y.bin', 'y\n');
    await sleep(1800);
    assert.deepEqual(seen, [], 'changes under skipped folders start no check');
    const status = (await rpc(ws, '_acpcode/git/status', { projectId: project.id })).result;
    assert.ok(status.files.some((f) => f.path === 'cache/x.bin'), 'git/status still lists the skipped file');
    assert.ok(status.files.some((f) => f.path === 'out/tmp/y.bin'));
    put(dir, 'a.txt', 'two\n');
    await until(() => seen.length === 1, 'a notification for a watched file');
    assert.equal(seen[0].hash, (await rpc(ws, '_acpcode/git/status', { projectId: project.id })).result.hash);
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('an anchored entry skips only at the project root, a bare name at any depth', async () => {
  const { gw, dir, ws, project } = await setup(['out/tmp', 'cache']);
  try {
    const seen = listen(ws);
    await rpc(ws, '_acpcode/git/status', { projectId: project.id });
    put(dir, 'other/out/tmp/w.bin', 'w\n');
    await until(() => seen.length === 1, 'a folder that is not skipped');
    const deep = seen.length;
    put(dir, 'deep/cache/z.bin', 'z\n');
    await sleep(1800);
    assert.equal(seen.length, deep, 'a bare name skips at any depth');
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('watchSkip survives a gateway restart and keeps skipping', async () => {
  const dirs = await makeDirs();
  const config = rawConfig(dirs.root);
  try {
    execFileSync('git', ['init', '-q', '-b', 'main'], { cwd: dirs.project });
    put(dirs.project, 'a.txt', 'one\n');
    git(dirs.project, 'add', '.');
    git(dirs.project, 'commit', '-q', '-m', 'first');
    let gw = await spawnGateway(config, { configDir: dirs.base });
    let { ws } = await connect(gw.url, auth());
    const { project } = (await rpc(ws, '_acpcode/projects/create', { name: 'kept', path: dirs.project, watchSkip: ['cache'] })).result;
    ws.close();
    await gw.stop();

    gw = await spawnGateway(config, { configDir: dirs.base });
    try {
      ({ ws } = await connect(gw.url, auth()));
      assert.deepEqual(userProjects((await rpc(ws, '_acpcode/projects/list', {})).result.projects), [{ ...project }]);
      const seen = listen(ws);
      await rpc(ws, '_acpcode/git/status', { projectId: project.id });
      put(dirs.project, 'cache/x.bin', 'x\n');
      await sleep(1800);
      assert.deepEqual(seen, [], 'the restored list still skips');
      put(dirs.project, 'a.txt', 'two\n');
      await until(() => seen.length === 1, 'a notification after the restart');
      ws.close();
    } finally {
      await gw.stop();
    }
  } finally {
    await dirs.cleanup();
  }
});
