// Per-project additions to the secret deny-list (FR-30, D-050): validated at create, stored, and
// applied exactly like the built-in list in git/diff and git/turnDiff. A project can add, never remove.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { auth, connect, rpc, startGateway } from './helpers.mjs';

const git = (dir, ...args) => execFileSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@t', ...args], { cwd: dir, encoding: 'utf8' });
const put = (dir, name, text) => { mkdirSync(join(dir, name, '..'), { recursive: true }); writeFileSync(join(dir, name), text); };
const prompt = (ws, sessionId, text) => rpc(ws, 'session/prompt', { sessionId, prompt: [{ type: 'text', text }] });
const SECRET = 'PROJECT-SECRET-VALUE-98765';

async function setup(denyPaths) {
  const gw = await startGateway();
  const ws = (await connect(gw.url, auth())).ws;
  const dir = gw.dirs.project;
  git(dir, 'init', '-q', '-b', 'main');
  const params = { name: 'deny', path: dir };
  if (denyPaths !== undefined) params.denyPaths = denyPaths;
  const created = await rpc(ws, '_agmente/projects/create', params);
  const project = created.result?.project;
  assert.ok(project, JSON.stringify(created.error));
  const session = await rpc(ws, 'session/new', { cwd: dir, mcpServers: [] });
  return { gw, ws, dir, project, sessionId: session.result.sessionId, created };
}

const files = ['data.db', 'config/prod.yml', 'vault/a/key-material.txt', 'notes.txt', 'config/dev.yml', '.env'];

async function changedRepo(dir) {
  for (const n of files) put(dir, n, 'old\n');
  git(dir, 'add', '-f', '.');
  git(dir, 'commit', '-q', '-m', 'first');
  for (const n of files) put(dir, n, `old\n${SECRET}\n`);
}

test('denyPaths is validated: bad entries are refused, nothing is registered', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    const bad = [
      '/etc/passwd', '../x', 'a/../b', './a', '', 'a/', 'a//b', '**/x', '!.env', '[a]', 'a?', 'a\\b', ':(top)x',
      'café', 'x'.repeat(101),
    ];
    for (const entry of bad) {
      const res = await rpc(ws, '_agmente/projects/create', { name: 'p', path: gw.dirs.project, denyPaths: [entry] });
      assert.equal(res.error?.code, -32602, JSON.stringify(entry));
      assert.match(res.error.message, /denyPaths/, JSON.stringify(entry));
    }
    for (const denyPaths of ['*.db', { a: 1 }, [1], [null], 33 + 0]) {
      const res = await rpc(ws, '_agmente/projects/create', { name: 'p', path: gw.dirs.project, denyPaths });
      assert.equal(res.error?.code, -32602, JSON.stringify(denyPaths));
    }
    const tooMany = Array.from({ length: 33 }, (_, i) => `f${i}`);
    assert.equal((await rpc(ws, '_agmente/projects/create', { name: 'p', path: gw.dirs.project, denyPaths: tooMany })).error?.code, -32602);
    assert.deepEqual((await rpc(ws, '_agmente/projects/list', {})).result.projects, []);
    // The boundaries pass.
    const ok = await rpc(ws, '_agmente/projects/create', { name: 'p', path: gw.dirs.project, denyPaths: Array.from({ length: 32 }, (_, i) => `f${i}`) });
    assert.equal(ok.result.project.denyPaths.length, 32);
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('denyPaths is returned by create and list, left out when empty, and kept in the database', async () => {
  const { gw, ws, project } = await setup(['*.db', 'config/prod.yml', '*.DB']);
  try {
    assert.deepEqual(project.denyPaths, ['*.db', 'config/prod.yml'], 'a duplicate is dropped');
    const list = (await rpc(ws, '_agmente/projects/list', {})).result.projects;
    assert.deepEqual(list, [project]);
    ws.close();
  } finally {
    await gw.stop();
  }
  const plain = await setup([]);
  try {
    assert.equal('denyPaths' in plain.project, false, 'no key when there are no additions');
    plain.ws.close();
  } finally {
    await plain.gw.stop();
  }
});

test('a project entry hides its files in git/diff (path, whole tree, staged) like the built-in list', async () => {
  const { gw, ws, dir, project } = await setup(['*.db', 'config/prod.yml', 'vault/*']);
  try {
    await changedRepo(dir);
    const id = project.id;
    const status = (await rpc(ws, '_agmente/git/status', { projectId: id })).result;
    assert.equal(status.files.length, files.length);
    for (const n of ['data.db', 'config/prod.yml', 'vault/a/key-material.txt', '.env']) {
      const one = (await rpc(ws, '_agmente/git/diff', { projectId: id, path: n })).result;
      assert.deepEqual(one.hidden, [n], n);
      assert.equal(one.diff, `secret file changed: ${n} (content hidden)\n`);
    }
    for (const n of ['notes.txt', 'config/dev.yml']) { // a name off both lists is shown
      const one = (await rpc(ws, '_agmente/git/diff', { projectId: id, path: n })).result;
      assert.match(one.diff, new RegExp(SECRET), n);
      assert.deepEqual(one.hidden, []);
    }
    const all = (await rpc(ws, '_agmente/git/diff', { projectId: id })).result;
    assert.deepEqual(all.hidden, ['.env', 'config/prod.yml', 'data.db', 'vault/a/key-material.txt']);
    assert.match(all.diff, /a\/notes\.txt/);
    assert.match(all.diff, /a\/config\/dev\.yml/);
    assert.equal(all.diff.split(SECRET).length - 1, 2, 'only notes.txt and dev.yml content is in the whole-tree diff');
    git(dir, 'add', '-f', '-A');
    await rpc(ws, '_agmente/git/status', { projectId: id });
    const staged = (await rpc(ws, '_agmente/git/diff', { projectId: id, staged: true })).result;
    assert.deepEqual(staged.hidden, ['.env', 'config/prod.yml', 'data.db', 'vault/a/key-material.txt']);
    assert.equal(staged.diff.split(SECRET).length - 1, 2);
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('a project entry hides its files in git/turnDiff and in tree diffs', async () => {
  const { gw, ws, dir, project, sessionId } = await setup(['*.db']);
  try {
    put(dir, 'a.txt', 'one\n');
    git(dir, 'add', '.');
    git(dir, 'commit', '-q', '-m', 'first');
    assert.deepEqual((await prompt(ws, sessionId, 'go [write:data.db] [write:plain.txt]')).result, { stopReason: 'end_turn' });
    const res = (await rpc(ws, '_agmente/git/turnDiff', { sessionId, turn: 1 })).result;
    assert.deepEqual(res.hidden, ['data.db']);
    assert.match(res.diff, /secret file changed: data\.db \(content hidden\)/);
    assert.match(res.diff, /a\/plain\.txt/);
    assert.doesNotMatch(res.diff, /b\/data\.db/, 'no diff body for the project secret');
    const tree = (await rpc(ws, '_agmente/git/diff', { projectId: project.id, fromTree: res.fromTree, toTree: res.toTree, path: 'data.db' })).result;
    assert.equal(tree.diff, 'secret file changed: data.db (content hidden)\n');
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('additions never remove built-ins, and one project\'s list does not reach another', async () => {
  const { gw, ws, dir, project } = await setup(['*.db']);
  try {
    // Built-ins still hide with additions present, and a hostile entry cannot remove one.
    for (const entry of ['!.env', '!*.pem']) {
      const res = await rpc(ws, '_agmente/projects/create', { name: 'x', path: dir, denyPaths: [entry] });
      assert.equal(res.error?.code, -32602, entry);
      assert.match(res.error.message, /denyPaths/, entry);
    }
    put(dir, 'k.pem', 'old\n');
    put(dir, '.env', 'old\n');
    git(dir, 'add', '-f', '.');
    git(dir, 'commit', '-q', '-m', 'first');
    put(dir, 'k.pem', `old\n${SECRET}\n`);
    put(dir, '.env', `old\n${SECRET}\n`);
    await rpc(ws, '_agmente/git/status', { projectId: project.id });
    const all = (await rpc(ws, '_agmente/git/diff', { projectId: project.id })).result;
    assert.deepEqual(all.hidden, ['.env', 'k.pem']);
    assert.ok(!JSON.stringify(all).includes(SECRET));

    // A second project without additions shows a *.db change.
    const other = mkdtempSync(join(gw.dirs.root, 'other-'));
    git(other, 'init', '-q', '-b', 'main');
    put(other, 'data.db', 'old\n');
    git(other, 'add', '.');
    git(other, 'commit', '-q', '-m', 'first');
    put(other, 'data.db', `old\n${SECRET}\n`);
    const second = (await rpc(ws, '_agmente/projects/create', { name: 'other', path: other })).result.project;
    await rpc(ws, '_agmente/git/status', { projectId: second.id });
    const diff = (await rpc(ws, '_agmente/git/diff', { projectId: second.id, path: 'data.db' })).result;
    assert.match(diff.diff, new RegExp(SECRET));
    assert.deepEqual(diff.hidden, []);
    ws.close();
  } finally {
    await gw.stop();
  }
});
