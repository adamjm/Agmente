// Git at project creation over the wire (D-105, v1): `_acpcode/projects/create` with `createFolder`
// and `gitInit` / `gitRemote`. Host runner for most cases; the podman runner with fixtures/fake-podman
// for the container path, so no real container runs. Nothing is fetched or pushed.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { auth, connect, rpc, startGateway } from './helpers.mjs';

const FAKE_PODMAN = fileURLToPath(new URL('./fixtures/fake-podman.mjs', import.meta.url));

const create = (ws, params) => rpc(ws, '_acpcode/projects/create', params);
const folderParams = (gw, name, extra = {}) => ({ createFolder: true, name, path: gw.dirs.root, ...extra });
const git = (dir, ...args) => execFileSync('git', ['-C', dir, ...args], { encoding: 'utf8', env: { ...process.env, GIT_CONFIG_GLOBAL: '/dev/null' } }).trim();

test('create without git options is unchanged: no git field, no .git', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    const res = await create(ws, folderParams(gw, 'plain'));
    assert.equal(res.error, undefined, JSON.stringify(res.error));
    assert.equal('git' in res.result, false);
    assert.equal(existsSync(join(gw.dirs.root, 'plain', '.git')), false);
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('gitInit creates a repository with branch main unborn, and a gitRemote becomes origin', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    const res = await create(ws, folderParams(gw, 'repo', { gitInit: true, gitRemote: 'https://github.com/owner/repo.git' }));
    assert.equal(res.error, undefined, JSON.stringify(res.error));
    assert.deepEqual(res.result.git, { initialized: true, remote: 'https://github.com/owner/repo.git', branch: '', unborn: true });
    const folder = join(gw.dirs.root, 'repo');
    assert.equal(git(folder, 'symbolic-ref', 'HEAD'), 'refs/heads/main');
    assert.equal(git(folder, 'config', '--local', 'remote.origin.url'), 'https://github.com/owner/repo.git');
    assert.throws(() => git(folder, 'rev-parse', '--verify', '-q', 'HEAD'), 'the repository must have no commit');
    const line = await gw.waitForAudit((l) => l.event === 'project_git_init');
    assert.equal(line.reason, 'remote');
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('gitInit without a remote: the repository has no origin and the result says so', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    const res = await create(ws, folderParams(gw, 'bare', { gitInit: true }));
    assert.equal(res.error, undefined, JSON.stringify(res.error));
    assert.deepEqual(res.result.git, { initialized: true, remote: null, branch: '', unborn: true });
    assert.throws(() => git(join(gw.dirs.root, 'bare'), 'config', '--local', 'remote.origin.url'));
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('a bad remote is refused before the folder exists; the message never repeats a password', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    const cases = [
      ['http://github.com/owner/repo.git', /https/],
      ['https://github.com/owner/repo.git'.replace('https://', 'https://pw-secret@'), /user name or password/],
      ['https://evil.example/owner/repo.git', /allow-list/],
      ['ext::sh -c id', /spaces|https/],
    ];
    for (const [i, [remote, want]] of cases.entries()) {
      const name = `refused-${i}`;
      const res = await create(ws, folderParams(gw, name, { gitInit: true, gitRemote: remote }));
      assert.equal(res.error?.code, -32602, `${remote}: ${JSON.stringify(res)}`);
      assert.match(res.error.message, want);
      assert.doesNotMatch(JSON.stringify(res), /pw-secret/);
      assert.equal(existsSync(join(gw.dirs.root, name)), false, `${remote} left a folder`);
    }
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('gitRemote without gitInit, and git options on an existing folder, are refused', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    let res = await create(ws, folderParams(gw, 'no-init', { gitRemote: 'https://github.com/o/r.git' }));
    assert.equal(res.error?.code, -32602);
    assert.match(res.error.message, /gitRemote needs gitInit/);
    res = await create(ws, { path: gw.dirs.project, name: 'existing', gitInit: true });
    assert.equal(res.error?.code, -32602);
    assert.match(res.error.message, /need createFolder/);
    assert.equal(existsSync(join(gw.dirs.project, '.git')), false);
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('gitInit on the podman runner runs in a one-off container with no network', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'acpcode-git-init-podman-'));
  const gw = await startGateway({}, {
    configFn: (dirs, config) => {
      config.runner = { kind: 'podman', image: 'fake-image:1', podman: FAKE_PODMAN };
    },
    env: { FAKE_PODMAN_DIR: dir },
  });
  try {
    const { ws } = await connect(gw.url, auth());
    const res = await create(ws, folderParams(gw, 'boxed', { gitInit: true, gitRemote: 'https://github.com/owner/repo.git' }));
    assert.equal(res.error, undefined, JSON.stringify(res.error));
    assert.equal(git(join(gw.dirs.root, 'boxed'), 'config', '--local', 'remote.origin.url'), 'https://github.com/owner/repo.git');
    const log = readFileSync(join(dir, 'log.jsonl'), 'utf8').trim().split('\n').map((l) => JSON.parse(l));
    const starts = log.filter((l) => l.event === 'start');
    assert.ok(starts.length >= 2, 'init and remote add each start a container');
    for (const s of starts) {
      assert.equal(s.network, 'none', 'git init and remote add run with --network none');
      assert.ok(s.command.includes('git'));
    }
    ws.close();
  } finally {
    await gw.stop();
  }
});
