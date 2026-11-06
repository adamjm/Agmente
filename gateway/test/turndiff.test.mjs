// Turn snapshots and git/turnDiff (PLAN 3.15, FR-27, T-27, T-31, D-036).
// The fake agent writes and removes files on the directives [write:NAME] and [remove:NAME].
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { auth, connect, rpc, startGateway, useProject } from './helpers.mjs';

const git = (dir, ...args) => execFileSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@t', ...args], { cwd: dir, encoding: 'utf8' });
const put = (dir, name, text) => { mkdirSync(join(dir, name, '..'), { recursive: true }); writeFileSync(join(dir, name), text); };
const prompt = (ws, sessionId, text) => rpc(ws, 'session/prompt', { sessionId, prompt: [{ type: 'text', text }] });
const turnDiff = (ws, sessionId, turn) => rpc(ws, '_agmente/git/turnDiff', { sessionId, turn });

async function setup({ init = true } = {}) {
  const gw = await startGateway();
  const ws = (await connect(gw.url, auth())).ws;
  const dir = gw.dirs.project;
  if (init) {
    git(dir, 'init', '-q', '-b', 'main');
    put(dir, 'a.txt', 'one\n');
    git(dir, 'add', '.');
    git(dir, 'commit', '-q', '-m', 'first');
  }
  const { project, sessionId } = await useProject(gw, ws);
  return { gw, ws, dir, project, sessionId };
}

test('T-31: a turn in which the agent writes new.txt has a turn diff that lists new.txt', async () => {
  const { gw, ws, dir, sessionId } = await setup();
  try {
    assert.deepEqual((await prompt(ws, sessionId, 'make a file [write:new.txt]')).result, { stopReason: 'end_turn' });
    assert.equal(readFileSync(join(dir, 'new.txt'), 'utf8'), 'x\n');
    const res = (await turnDiff(ws, sessionId, 1)).result;
    assert.match(res.diff, /^diff --git a\/new\.txt b\/new\.txt\nnew file mode 100644/);
    assert.match(res.diff, /\+x\n/);
    assert.doesNotMatch(res.diff, /a\.txt/);
    assert.deepEqual({ truncated: res.truncated, hidden: res.hidden }, { truncated: false, hidden: [] });
    assert.match(res.fromTree, /^[0-9a-f]{40}$/);
    assert.match(res.toTree, /^[0-9a-f]{40}$/);
    assert.notEqual(res.fromTree, res.toTree);
    // The two trees can be diffed again through git/diff, for one file.
    await rpc(ws, '_agmente/git/status', { projectId: (await rpc(ws, '_agmente/projects/list', {})).result.projects[0].id });
    const projectId = (await rpc(ws, '_agmente/projects/list', {})).result.projects[0].id;
    const one = (await rpc(ws, '_agmente/git/diff', { projectId, fromTree: res.fromTree, toTree: res.toTree, path: 'new.txt' })).result;
    assert.match(one.diff, /\+x/);
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('each turn has its own diff: edits outside the agent between turns belong to no turn', async () => {
  const { gw, ws, dir, sessionId } = await setup();
  try {
    await prompt(ws, sessionId, 'first [write:t1.txt]');
    const d1 = (await turnDiff(ws, sessionId, 1)).result.diff; // waits for the end snapshot
    put(dir, 'by-the-user.txt', 'typed by hand\n'); // between turns
    await prompt(ws, sessionId, 'second [write:t2.txt][remove:a.txt]');
    const d2 = (await turnDiff(ws, sessionId, 2)).result.diff;
    assert.match(d1, /b\/t1\.txt/);
    assert.doesNotMatch(d1, /t2\.txt|by-the-user|a\.txt/);
    assert.match(d2, /b\/t2\.txt/);
    assert.match(d2, /deleted file mode[\s\S]*-one/, 'a removed tracked file shows as deleted');
    assert.doesNotMatch(d2, /t1\.txt|by-the-user/);
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('T-27 (snapshot): a hostile repo\'s clean filter, fsmonitor and hooks never run', async () => {
  const { gw, ws, dir, sessionId } = await setup();
  const markers = mkdtempSync(join(tmpdir(), 'agmente-snapmarkers-'));
  try {
    const script = (name, body) => { const f = join(markers, `${name}.sh`); writeFileSync(f, `#!/bin/sh\n${body}\n`); chmodSync(f, 0o755); return f; };
    put(dir, '.gitattributes', '*.txt filter=evil\n');
    git(dir, 'config', 'filter.evil.clean', script('clean', `touch ${markers}/clean; cat`));
    git(dir, 'config', 'filter.evil.smudge', script('smudge', `touch ${markers}/smudge; cat`));
    git(dir, 'config', 'filter.evil.required', 'true');
    git(dir, 'config', 'core.fsmonitor', script('fsmonitor', `touch ${markers}/fsmonitor; printf '\\0'`));
    git(dir, 'config', 'core.hooksPath', markers);
    script('pre-commit', `touch ${markers}/hook`);
    await prompt(ws, sessionId, 'x [write:filtered.txt]');
    const res = (await turnDiff(ws, sessionId, 1)).result;
    assert.match(res.diff, /b\/filtered\.txt/, 'the snapshot still saw the file');
    assert.deepEqual(readdirSync(markers).filter((n) => !n.endsWith('.sh') && n !== 'pre-commit.sh'), [], 'no program ran');
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('snapshots leave the repository as it was: same index, same objects, same refs', async () => {
  const { gw, ws, dir, sessionId } = await setup();
  try {
    put(dir, 'dirty.txt', 'uncommitted\n');
    const snapshot = () => ({
      index: readFileSync(join(dir, '.git/index')).toString('hex'),
      objects: execFileSync('find', ['.git/objects', '-type', 'f'], { cwd: dir, encoding: 'utf8' }).split('\n').sort().join('\n'),
      refs: git(dir, 'for-each-ref'),
      status: git(dir, 'status', '--porcelain'),
    });
    const before = snapshot();
    await prompt(ws, sessionId, 'go [write:more.txt]');
    assert.ok((await turnDiff(ws, sessionId, 1)).result.diff.includes('more.txt'));
    assert.deepEqual({ ...snapshot(), status: '' }, { ...before, status: '' }, 'index, objects and refs unchanged');
    assert.equal(snapshot().status, `${before.status}?? more.txt\n`);
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('secret files in a turn show by name only; symlinks and pipes are left out', async () => {
  const { gw, ws, dir, sessionId } = await setup();
  const outside = mkdtempSync(join(tmpdir(), 'agmente-outside-'));
  try {
    writeFileSync(join(outside, 'private.txt'), 'OUTSIDE-SECRET\n');
    symlinkSync(join(outside, 'private.txt'), join(dir, 'old-link.txt'));
    execFileSync('mkfifo', [join(dir, 'pipe')]);
    await prompt(ws, sessionId, `secrets [write:.env][write:server.pem][write:plain.txt][symlink:new-link.txt>${join(outside, 'private.txt')}]`);
    const res = (await turnDiff(ws, sessionId, 1)).result;
    assert.match(res.diff, /b\/plain\.txt/);
    assert.equal(res.diff.match(/^diff --git /gm).length, 1, 'only plain.txt has a diff; the others are named, not shown');
    assert.deepEqual(res.hidden, ['.env', 'server.pem']);
    assert.match(res.diff, /secret file changed: \.env \(content hidden\)/);
    assert.doesNotMatch(res.diff, /OUTSIDE-SECRET|link\.txt|pipe/, 'a symlink is not followed or listed');
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('turnDiff errors: unknown session, bad turn, a running turn, a folder with no repository', async () => {
  const { gw, ws, sessionId } = await setup();
  try {
    await prompt(ws, sessionId, 'one');
    for (const [params, message] of [
      [{ turn: 1 }, 'sessionId is required'],
      [{ sessionId: 'sess-nope', turn: 1 }, 'unknown session'],
      [{ sessionId, turn: 0 }, 'turn must be a positive integer'],
      [{ sessionId, turn: '1' }, 'turn must be a positive integer'],
      [{ sessionId, turn: 1.5 }, 'turn must be a positive integer'],
    ]) assert.deepEqual((await rpc(ws, '_agmente/git/turnDiff', params)).error, { code: -32602, message }, JSON.stringify(params));
    assert.deepEqual((await turnDiff(ws, sessionId, 1)).result.diff, '', 'a turn that changed nothing has an empty diff');
    assert.deepEqual((await turnDiff(ws, sessionId, 9)).error, { code: -32000, message: 'no snapshot for this turn' });

    const long = prompt(ws, sessionId, 'slow [chunks:30][slow:40]');
    for (let i = 0; i < 100; i += 1) {
      const r = await turnDiff(ws, sessionId, 2);
      if (r.error?.message === 'turn is still running') break;
      assert.ok(i < 99, `expected "turn is still running", got ${JSON.stringify(r)}`);
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    await long;
    assert.ok((await turnDiff(ws, sessionId, 2)).result, 'after the turn ends it has a diff');
    ws.close();
  } finally {
    await gw.stop();
  }

  const plain = await setup({ init: false });
  try {
    assert.deepEqual((await prompt(plain.ws, plain.sessionId, 'in a folder with no repository')).result, { stopReason: 'end_turn' }, 'the turn runs without a snapshot');
    assert.deepEqual((await turnDiff(plain.ws, plain.sessionId, 1)).error, { code: -32000, message: 'no snapshot for this turn' });
    await plain.gw.waitForAudit((l) => l.event === 'snapshot_failed');
    plain.ws.close();
  } finally {
    await plain.gw.stop();
  }
});

test('git/diff with trees: both must be tree ids; a path must be in that diff', async () => {
  const { gw, ws, project, sessionId } = await setup();
  try {
    await prompt(ws, sessionId, 'x [write:new.txt]');
    const t = (await turnDiff(ws, sessionId, 1)).result;
    const d = (params) => rpc(ws, '_agmente/git/diff', { projectId: project.id, ...params });
    for (const params of [{ fromTree: t.fromTree }, { fromTree: 'HEAD', toTree: t.toTree }, { fromTree: t.fromTree, toTree: '--output=/tmp/agmente-y' }, { fromTree: t.fromTree, toTree: 7 }]) {
      assert.equal((await d(params)).error?.code, -32602, JSON.stringify(params));
    }
    assert.equal((await d({ fromTree: t.fromTree, toTree: t.toTree, path: 'a.txt' })).error.message, 'path is not in this diff');
    assert.equal((await d({ fromTree: t.fromTree, toTree: t.toTree })).result.diff, t.diff);
    assert.equal(existsSync('/tmp/agmente-y'), false);
    ws.close();
  } finally {
    await gw.stop();
  }
});
