// Read-only git over the wire (PLAN 3.14, FR-27 to FR-30, T-26, T-28, T-29, D-034, D-035).
// The gateway runs on the host runner here, so git is real git in the project folder; the runner's
// container behaviour is covered by the Go tests (3.13).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, writeFileSync, chmodSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { auth, connect, rpc, startGateway, useProject } from './helpers.mjs';

const git = (dir, ...args) => execFileSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@t', ...args], { cwd: dir, encoding: 'utf8' });
const put = (dir, name, text) => {
  mkdirSync(join(dir, name, '..'), { recursive: true });
  writeFileSync(join(dir, name), text);
};
const status = async (ws, projectId) => (await rpc(ws, '_acpcode/git/status', { projectId })).result;
const diff = (ws, params) => rpc(ws, '_acpcode/git/diff', params);

async function repo() {
  const gw = await startGateway();
  const ws = (await connect(gw.url, auth())).ws;
  const { project } = await useProject(gw, ws);
  const dir = gw.dirs.project;
  git(dir, 'init', '-q', '-b', 'main');
  return { gw, ws, dir, id: project.id };
}

test('status: branch, files with status, staged flag and line counts, and a hash that changes with the state', async () => {
  const { gw, ws, dir, id } = await repo();
  try {
    put(dir, 'a.txt', 'one\ntwo\n');
    put(dir, 'b.txt', 'keep\n');
    put(dir, 'old name.txt', 'move me\n');
    git(dir, 'add', '.');
    git(dir, 'commit', '-q', '-m', 'first');
    put(dir, 'a.txt', 'one\nTWO\nthree\n'); // +2 -1, not staged
    put(dir, 'c.txt', 'new\n');
    git(dir, 'add', 'c.txt'); // staged, +1
    git(dir, 'mv', 'old name.txt', 'new name.txt'); // staged rename
    put(dir, 'dir/u.txt', 'untracked\n');
    writeFileSync(join(dir, 'bin.dat'), Buffer.from([0, 1, 2, 0, 255]));
    git(dir, 'add', 'bin.dat');

    const s1 = await status(ws, id);
    assert.deepEqual(Object.keys(s1).sort(), ['ahead', 'behind', 'branch', 'files', 'hash', 'truncated', 'upstream']);
    assert.deepEqual({ branch: s1.branch, upstream: s1.upstream, ahead: s1.ahead, behind: s1.behind, truncated: s1.truncated }, { branch: 'main', upstream: null, ahead: 0, behind: 0, truncated: false });
    const byPath = Object.fromEntries(s1.files.map((f) => [f.path, f]));
    assert.deepEqual(byPath['a.txt'], { path: 'a.txt', status: 'modified', staged: false, added: 2, removed: 1 });
    assert.deepEqual(byPath['c.txt'], { path: 'c.txt', status: 'added', staged: true, added: 1, removed: 0 });
    assert.deepEqual(byPath['new name.txt'], { path: 'new name.txt', status: 'renamed', staged: true, added: 0, removed: 0 });
    assert.deepEqual(byPath['dir/u.txt'], { path: 'dir/u.txt', status: 'untracked', staged: false, added: null, removed: null }, 'untracked files are listed one by one');
    assert.deepEqual(byPath['bin.dat'], { path: 'bin.dat', status: 'added', staged: true, added: null, removed: null }, 'binary: no counts');
    assert.equal(s1.files.length, 5);
    assert.equal((await status(ws, id)).hash, s1.hash, 'the same state gives the same hash');
    put(dir, 'b.txt', 'changed\n');
    assert.notEqual((await status(ws, id)).hash, s1.hash);

    git(dir, 'add', '-A');
    git(dir, 'commit', '-q', '-m', 'second');
    const clean = await status(ws, id);
    assert.deepEqual(clean.files, []);
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('T-28: a diff path must come from the last status; others are refused, a leading dash included', async () => {
  const { gw, ws, dir, id } = await repo();
  try {
    put(dir, 'a.txt', 'one\n');
    put(dir, '-dash.txt', 'dash\n');
    put(dir, '*.glob', 'glob\n');
    put(dir, 'x.glob', 'xglob\n');
    put(dir, 'other.txt', 'other\n');
    git(dir, 'add', '.');
    git(dir, 'commit', '-q', '-m', 'first');
    put(dir, 'a.txt', 'one\nchanged\n');
    put(dir, '-dash.txt', 'dash\nmore\n');
    put(dir, '*.glob', 'glob\nmore\n');
    put(dir, 'x.glob', 'xglob\nmore\n');
    put(dir, 'other.txt', 'other\nmore\n');

    assert.equal((await diff(ws, { projectId: id, path: 'a.txt' })).error.message, 'call git/status first: a diff path must come from the current status', 'no status yet');
    const s = await status(ws, id);
    assert.equal(s.files.length, 5);

    const refused = ['nope.txt', '../etc/passwd', '/etc/passwd', '.git/config', '--output=/tmp/acpcode-x', '-p', 'a.txt/', './a.txt', 'a.tx*', ''];
    for (const path of refused) {
      const res = await diff(ws, { projectId: id, path });
      assert.equal(res.error?.code, -32602, `refused: ${JSON.stringify(path)} ${JSON.stringify(res)}`);
    }
    assert.equal(existsSync('/tmp/acpcode-x'), false);

    // A file that is in the status is diffed even if its name starts with "-" or looks like a glob:
    // the path goes after "--" and as a literal.
    const dash = (await diff(ws, { projectId: id, path: '-dash.txt' })).result;
    assert.match(dash.diff, /\+more/);
    assert.match(dash.diff, /-dash\.txt/);
    const glob = (await diff(ws, { projectId: id, path: '*.glob' })).result;
    assert.match(glob.diff, /\+more/);
    assert.doesNotMatch(glob.diff, /x\.glob/, 'the name is a literal, not a pattern');
    const a = (await diff(ws, { projectId: id, path: 'a.txt' })).result;
    assert.deepEqual({ truncated: a.truncated, hidden: a.hidden }, { truncated: false, hidden: [] });
    assert.match(a.diff, /^diff --git a\/a\.txt b\/a\.txt/);
    assert.match(a.diff, /\+changed/);
    assert.doesNotMatch(a.diff, /other\.txt/);

    for (const [params, message] of [[{ path: 'a.txt' }, 'projectId is required'], [{ projectId: 'nope' }, 'unknown project'], [{ projectId: id, path: 7 }, 'path must be a file path from the last status'], [{ projectId: id, staged: 'yes' }, 'staged must be true or false']]) {
      assert.deepEqual((await diff(ws, params)).error, { code: -32602, message }, JSON.stringify(params));
    }
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('diff: staged, untracked and the whole tree', async () => {
  const { gw, ws, dir, id } = await repo();
  try {
    put(dir, 'a.txt', 'one\n');
    git(dir, 'add', '.');
    git(dir, 'commit', '-q', '-m', 'first');
    put(dir, 'a.txt', 'one\nstaged line\n');
    git(dir, 'add', 'a.txt');
    put(dir, 'a.txt', 'one\nstaged line\nworktree line\n');
    put(dir, 'new.txt', 'brand new\n');
    await status(ws, id);
    const unstaged = (await diff(ws, { projectId: id, path: 'a.txt' })).result.diff;
    assert.match(unstaged, /\+worktree line/);
    assert.doesNotMatch(unstaged, /\+staged line/, 'the staged line is already in the index');
    const staged = (await diff(ws, { projectId: id, path: 'a.txt', staged: true })).result.diff;
    assert.match(staged, /\+staged line/);
    assert.doesNotMatch(staged, /worktree line/);
    const untracked = (await diff(ws, { projectId: id, path: 'new.txt' })).result.diff;
    assert.match(untracked, /new file mode/);
    assert.match(untracked, /\+brand new/);
    const all = (await diff(ws, { projectId: id })).result;
    assert.match(all.diff, /\+worktree line/);
    assert.deepEqual(all.hidden, []);
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('T-29: a changed secret file shows by name; its content never leaves the gateway', async () => {
  const { gw, ws, dir, id } = await repo();
  try {
    const secret = 'SUPER-SECRET-VALUE-12345';
    const names = ['.env', '.env.local', 'cert.pem', 'tls.KEY', 'store.p12', 'apple.p8', 'id_rsa', 'id_rsa.pub', 'my-secret-notes.txt', '.npmrc', '.netrc', 'config/secrets/db.yml', 'sub/.env'];
    put(dir, 'ok.txt', 'fine\n');
    for (const n of names) put(dir, n, 'old\n');
    git(dir, 'add', '-f', '.');
    git(dir, 'commit', '-q', '-m', 'first');
    put(dir, 'ok.txt', 'fine\nvisible change\n');
    for (const n of names) put(dir, n, `old\n${secret}\n`);
    put(dir, 'untracked.env', `${secret}\n`); // "*.env" is not on the list: shown
    put(dir, '.env.new', `${secret}\n`); // untracked and on the list
    const s = await status(ws, id);
    assert.ok(names.every((n) => s.files.some((f) => f.path === n)), 'names appear in status');

    for (const n of [...names, '.env.new']) {
      const one = (await diff(ws, { projectId: id, path: n })).result;
      assert.deepEqual(one.hidden, [n]);
      assert.equal(one.diff, `secret file changed: ${n} (content hidden)\n`);
      assert.ok(!JSON.stringify(one).includes(secret) && !JSON.stringify(one).includes('old'), n);
    }
    const all = (await diff(ws, { projectId: id })).result;
    assert.ok(!JSON.stringify(all).includes(secret), 'no secret content in the whole-tree diff');
    assert.match(all.diff, /\+visible change/, 'other files still show');
    assert.deepEqual(all.hidden, [...names, '.env.new'].sort());
    for (const n of [...names, '.env.new']) assert.ok(all.diff.includes(`secret file changed: ${n} (content hidden)`), n);
    const plain = (await diff(ws, { projectId: id, path: 'untracked.env' })).result;
    assert.match(plain.diff, new RegExp(secret), 'a name off the list is not hidden');
    // Staged secrets are hidden too.
    git(dir, 'add', '-f', '.env', 'untracked.env');
    await status(ws, id);
    const stagedAll = (await diff(ws, { projectId: id, staged: true })).result;
    assert.deepEqual(stagedAll.hidden, ['.env']);
    assert.match(stagedAll.diff, /untracked\.env/, 'a staged file off the list shows');
    assert.ok(!JSON.stringify((await diff(ws, { projectId: id, path: '.env', staged: true })).result).includes(secret));
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('T-26 over the wire: a hostile repository runs no program for status or diff', async () => {
  const { gw, ws, dir, id } = await repo();
  const markers = mkdtempSync(join(tmpdir(), 'acpcode-markers-'));
  try {
    put(dir, 'a.txt', 'one\n');
    put(dir, '.gitattributes', '*.txt diff=evil\n');
    git(dir, 'add', '.');
    git(dir, 'commit', '-q', '-m', 'first');
    put(dir, 'a.txt', 'two\n');
    const script = (name, body) => {
      const f = join(markers, `${name}.sh`);
      writeFileSync(f, `#!/bin/sh\n${body}\n`);
      chmodSync(f, 0o755);
      return f;
    };
    git(dir, 'config', 'core.fsmonitor', script('fsmonitor', `touch ${markers}/fsmonitor; printf '\\0'`));
    git(dir, 'config', 'diff.external', script('external', `touch ${markers}/external`));
    git(dir, 'config', 'diff.evil.textconv', script('textconv', `touch ${markers}/textconv; cat "$1"`));
    git(dir, 'config', 'core.pager', script('pager', `touch ${markers}/pager; cat`));
    const s = await status(ws, id);
    assert.equal(s.files.length, 1);
    assert.match((await diff(ws, { projectId: id, path: 'a.txt' })).result.diff, /\+two/);
    assert.match((await diff(ws, { projectId: id })).result.diff, /\+two/);
    await rpc(ws, '_acpcode/git/log', { projectId: id });
    assert.deepEqual(readdirSync(markers).filter((n) => !n.endsWith('.sh')), [], 'no program ran');
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('log: newest first, pages by cursor, empty repository, bad parameters', async () => {
  const { gw, ws, dir, id } = await repo();
  try {
    assert.deepEqual((await rpc(ws, '_acpcode/git/log', { projectId: id })).result, { commits: [] }, 'no commits yet');
    for (let i = 1; i <= 5; i += 1) {
      put(dir, 'f.txt', `${i}\n`);
      git(dir, 'add', '.');
      git(dir, 'commit', '-q', '-m', `commit ${i}\n\nbody ${i}`);
    }
    const first = (await rpc(ws, '_acpcode/git/log', { projectId: id, limit: 2 })).result;
    assert.deepEqual(first.commits.map((c) => c.subject), ['commit 5', 'commit 4']);
    assert.deepEqual(Object.keys(first.commits[0]).sort(), ['author', 'date', 'hash', 'shortHash', 'subject']);
    assert.match(first.commits[0].hash, /^[0-9a-f]{40}$/);
    assert.equal(first.commits[0].shortHash, first.commits[0].hash.slice(0, 7));
    assert.equal(first.commits[0].author, 't');
    assert.match(first.commits[0].date, /^\d{4}-\d\d-\d\dT/);
    const second = (await rpc(ws, '_acpcode/git/log', { projectId: id, limit: 2, cursor: first.nextCursor })).result;
    assert.deepEqual(second.commits.map((c) => c.subject), ['commit 3', 'commit 2']);
    const last = (await rpc(ws, '_acpcode/git/log', { projectId: id, limit: 2, cursor: second.nextCursor })).result;
    assert.deepEqual(last, { commits: [{ ...last.commits[0], subject: 'commit 1' }] }, 'no nextCursor on the last page');
    assert.equal((await rpc(ws, '_acpcode/git/log', { projectId: id })).result.commits.length, 5);
    for (const [params, message] of [[{ limit: 0 }, 'limit must be an integer from 1 to 200'], [{ limit: 201 }, 'limit must be an integer from 1 to 200'], [{ limit: 1.5 }, 'limit must be an integer from 1 to 200'], [{ cursor: 'abc' }, 'cursor must be a value from a previous git/log'], [{ cursor: '-1' }, 'cursor must be a value from a previous git/log']]) {
      assert.deepEqual((await rpc(ws, '_acpcode/git/log', { projectId: id, ...params })).error, { code: -32602, message }, JSON.stringify(params));
    }
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('a folder that is not a repository gets "not a git repository"; a big diff is cut at 2 MiB', async () => {
  const { gw, ws, dir, id } = await repo();
  try {
    execFileSync('rm', ['-rf', join(dir, '.git')]);
    for (const method of ['status', 'log']) {
      assert.deepEqual((await rpc(ws, `_acpcode/git/${method}`, { projectId: id })).error, { code: -32000, message: 'not a git repository' });
    }
    git(dir, 'init', '-q', '-b', 'main');
    put(dir, 'big.txt', 'x\n');
    git(dir, 'add', '.');
    git(dir, 'commit', '-q', '-m', 'first');
    put(dir, 'big.txt', `${'y'.repeat(99)}\n`.repeat(30000)); // about 3 MB of added lines
    await status(ws, id);
    const big = (await diff(ws, { projectId: id, path: 'big.txt' })).result;
    assert.equal(big.truncated, true);
    assert.equal(Buffer.byteLength(big.diff), 2 * 1024 * 1024);
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('a slow git call does not hold up the same socket\'s other requests', async () => {
  const { gw, ws, dir, id } = await repo();
  try {
    put(dir, 'a.txt', 'one\n');
    git(dir, 'add', '.');
    git(dir, 'commit', '-q', '-m', 'first');
    const t0 = Date.now();
    const calls = await Promise.all([1, 2, 3].map(() => rpc(ws, '_acpcode/git/status', { projectId: id })));
    assert.ok(calls.every((c) => c.result.branch === 'main'));
    assert.deepEqual((await rpc(ws, '_acpcode/projects/list', {})).result.projects.length, 1);
    assert.ok(Date.now() - t0 < 5000);
    ws.close();
  } finally {
    await gw.stop();
  }
});
