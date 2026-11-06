// git/changed notifications (PLAN 3.16, FR-27, NFR-9, D-037): debounced 500 ms, at most 2 a second.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { auth, connect, rpc, sleep, startGateway } from './helpers.mjs';

const git = (dir, ...args) => execFileSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@t', ...args], { cwd: dir, encoding: 'utf8' });
const put = (dir, name, text) => { mkdirSync(join(dir, name, '..'), { recursive: true }); writeFileSync(join(dir, name), text); };

/** A gateway with a repository project; `listen(ws)` records the git/changed notifications on a socket. */
async function setup() {
  const gw = await startGateway();
  const dir = gw.dirs.project;
  git(dir, 'init', '-q', '-b', 'main');
  put(dir, 'a.txt', 'one\n');
  put(dir, '.gitignore', 'ignored.log\n');
  git(dir, 'add', '.');
  git(dir, 'commit', '-q', '-m', 'first');
  const ws = (await connect(gw.url, auth())).ws;
  const project = (await rpc(ws, '_agmente/projects/create', { name: 'p', path: dir })).result.project;
  return { gw, dir, ws, project };
}
function listen(ws) {
  const seen = [];
  ws.on('message', (d) => {
    const m = JSON.parse(d.toString());
    if (m.method === '_agmente/git/changed') seen.push({ t: Date.now(), ...m.params });
  });
  return seen;
}
async function until(pred, what, ms = 8000) {
  for (const t0 = Date.now(); Date.now() - t0 < ms; await sleep(25)) if (pred()) return;
  throw new Error(`timed out waiting for ${what}`);
}
const statusOf = (ws, projectId) => rpc(ws, '_agmente/git/status', { projectId }).then((r) => r.result);

test('a change to a file sends one notification with the new status hash', async () => {
  const { gw, dir, ws, project } = await setup();
  try {
    const seen = listen(ws);
    const s0 = await statusOf(ws, project.id);
    await sleep(1300);
    assert.deepEqual(seen, [], 'nothing changed, nothing sent');
    put(dir, 'a.txt', 'one\nchanged\n');
    await until(() => seen.length >= 1, 'a notification');
    await sleep(1300);
    assert.equal(seen.length, 1, 'one change, one notification');
    assert.equal(seen[0].projectId, project.id);
    assert.notEqual(seen[0].hash, s0.hash);
    assert.equal(seen[0].hash, (await statusOf(ws, project.id)).hash, 'the hash is the status hash');
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('NFR-9: a burst of writes is debounced to at most 2 a second, and the last one has the final hash', async () => {
  const { gw, dir, ws, project } = await setup();
  try {
    const seen = listen(ws);
    await statusOf(ws, project.id);
    const t0 = Date.now();
    for (let i = 0; i < 40; i += 1) { // 40 changes over about 2 s
      put(dir, `burst-${i % 8}.txt`, `${i}\n`);
      await sleep(50);
    }
    const spanMs = Date.now() - t0;
    assert.deepEqual(seen, [], 'nothing is sent while the writes go on: the debounce waits for 500 ms of quiet');
    await until(() => seen.length >= 1, 'a notification');
    await sleep(1500);
    const final = (await statusOf(ws, project.id)).hash;
    assert.equal(seen.at(-1).hash, final, 'the last notification carries the final state');
    assert.ok(seen[0].t >= t0 + spanMs, 'the first one came after the burst');
    assert.ok(seen.length >= 1 && seen.length <= Math.ceil((spanMs / 1000) * 2) + 1, `${seen.length} notifications in ${spanMs} ms`);
    for (let i = 1; i < seen.length; i += 1) assert.ok(seen[i].t - seen[i - 1].t >= 450, `gap ${seen[i].t - seen[i - 1].t} ms`);
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('a change to an ignored file sends nothing; a commit from outside sends one', async () => {
  const { gw, dir, ws, project } = await setup();
  try {
    const seen = listen(ws);
    await statusOf(ws, project.id);
    put(dir, 'ignored.log', 'noise\n');
    await sleep(1800);
    assert.deepEqual(seen, [], 'the status did not change');
    put(dir, 'node_modules/pkg/index.js', 'x\n'); // a skipped folder starts no check at all
    await sleep(1800);
    assert.deepEqual(seen, [], 'changes under node_modules are not watched');
    put(dir, 'a.txt', 'two\n');
    await until(() => seen.length === 1, 'the edit');
    git(dir, 'commit', '-q', '-am', 'second');
    await until(() => seen.length === 2, 'the commit');
    assert.equal(seen[1].hash, (await statusOf(ws, project.id)).hash);
    assert.notEqual(seen[1].hash, seen[0].hash);
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('only sockets that asked for the status are told; the watch stops with the last of them', async () => {
  const { gw, dir, ws, project } = await setup();
  try {
    const other = (await connect(gw.url, auth())).ws;
    const quiet = listen(other);
    const seen = listen(ws);
    assert.equal(gw.audit.filter((l) => l.event === 'git_watch_start').length, 0, 'registering a project watches nothing');
    await statusOf(ws, project.id);
    await gw.waitForAudit((l) => l.event === 'git_watch_start');
    put(dir, 'a.txt', 'three\n');
    await until(() => seen.length === 1, 'a notification');
    assert.deepEqual(quiet, [], 'a socket that never asked is not told');
    await statusOf(other, project.id); // now it is watching too
    put(dir, 'a.txt', 'four\n');
    await until(() => seen.length === 2 && quiet.length === 1, 'both told');
    ws.close();
    put(dir, 'a.txt', 'five\n');
    await until(() => quiet.length === 2, 'the remaining socket is still told');
    other.close();
    await gw.waitForAudit((l) => l.event === 'git_watch_stop');
    assert.equal(gw.audit.filter((l) => l.event === 'git_watch_start').length, 1, 'one watch served both sockets');
  } finally {
    await gw.stop();
  }
});

test('a project that is not a repository is watched without a notification or a crash', async () => {
  const gw = await startGateway();
  try {
    const ws = (await connect(gw.url, auth())).ws;
    const project = (await rpc(ws, '_agmente/projects/create', { name: 'p', path: gw.dirs.project })).result.project;
    const res = await rpc(ws, '_agmente/git/status', { projectId: project.id });
    assert.equal(res.error.message, 'not a git repository');
    await sleep(1200);
    assert.equal(gw.audit.filter((l) => l.event === 'git_watch_start').length, 0, 'a failed status starts no watch');
    ws.close();
  } finally {
    await gw.stop();
  }
});
