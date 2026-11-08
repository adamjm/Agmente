// Git push over the wire (D-105, v2) with the podman runner and fixtures/fake-podman.mjs, so no
// real container runs and no real push reaches a network. The fake logs each container's network
// setting and its arguments, which the tests check. The origin of the one push case that gets as far
// as git push points at 127.0.0.1, which is not a git server, so that push fails at the connection.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { auth, connect, rpc, startGateway } from './helpers.mjs';

const FAKE_PODMAN = fileURLToPath(new URL('./fixtures/fake-podman.mjs', import.meta.url));
const TOKEN_VALUE = 'ghp_pushtoken0123456789abcdefghijklmnop';
const git = (dir, ...args) => execFileSync('git', ['-C', dir, '-c', 'user.name=t', '-c', 'user.email=t@example.invalid', ...args], {
  encoding: 'utf8', env: { ...process.env, GIT_CONFIG_GLOBAL: '/dev/null' },
}).trim();

/** A gateway on the fake podman, with a git repository in its project folder. */
async function pushGateway({ hosts, origin, files = {}, credHost = 'github.com' }) {
  const dir = mkdtempSync(join(tmpdir(), 'acpcode-git-push-'));
  const gw = await startGateway({ ...(hosts ? { git: { hosts } } : {}) }, {
    configFn: (dirs, config) => {
      config.runner = { kind: 'podman', image: 'fake-image:1', podman: FAKE_PODMAN };
    },
    env: { FAKE_PODMAN_DIR: dir },
  });
  // The fake writes its log on its first run, so before any container there is no file yet.
  gw.podmanLog = () => (existsSync(join(dir, 'log.jsonl'))
    ? readFileSync(join(dir, 'log.jsonl'), 'utf8').trim().split('\n').filter(Boolean).map((l) => JSON.parse(l))
    : []);
  const repo = gw.dirs.project;
  git(repo, 'init', '-q', '-b', 'main');
  git(repo, 'remote', 'add', 'origin', origin);
  for (const [name, body] of Object.entries(files)) writeFileSync(join(repo, name), body);
  git(repo, 'add', '-A');
  git(repo, 'commit', '-q', '--allow-empty', '-m', 'init');
  const ws = (await connect(gw.url, auth())).ws;
  // The profile's host is on the allow-list; the origin may name another host, which the push must refuse.
  const cred = await rpc(ws, '_acpcode/git/credentials/set', { name: 'test', host: credHost, token: TOKEN_VALUE });
  assert.equal(cred.error, undefined, JSON.stringify(cred.error));
  gw.ws = ws;
  gw.credentialId = cred.result.id;
  const reg = await rpc(ws, '_acpcode/projects/create', { name: 'pushed', path: repo });
  assert.equal(reg.error, undefined, JSON.stringify(reg.error));
  gw.projectId = reg.result.project.id;
  return gw;
}

const push = (gw, extra = {}) => rpc(gw.ws, '_acpcode/git/push', {
  projectId: gw.projectId, credentialId: gw.credentialId, confirm: true, ...extra,
});

test('push refuses without confirm: true and starts no container', async () => {
  const gw = await pushGateway({ origin: 'https://github.com/owner/repo.git' });
  try {
    const before = gw.podmanLog().length;
    for (const params of [{ confirm: false }, { confirm: 'yes' }, {}]) {
      const res = await rpc(gw.ws, '_acpcode/git/push', { projectId: gw.projectId, credentialId: gw.credentialId, ...params });
      assert.equal(res.error?.code, -32602, JSON.stringify(res));
      assert.match(res.error.message, /confirm/);
    }
    assert.equal(gw.podmanLog().length, before, 'no container may start without confirm');
    gw.ws.close();
  } finally {
    gw.ws?.close();
    await gw.stop();
  }
});

test('push refuses a remote that is not on the allow-list before the push container runs', async () => {
  const gw = await pushGateway({ origin: 'https://evil.example/owner/repo.git', credHost: 'github.com' });
  try {
    const res = await push(gw);
    assert.equal(res.error?.code, -32602, JSON.stringify(res));
    assert.match(res.error.message, /origin/);
    const starts = gw.podmanLog().filter((l) => l.event === 'start');
    assert.ok(starts.length >= 1);
    assert.ok(starts.every((s) => s.network === 'none'), 'only the no-network steps may run');
    assert.equal(gw.audit.filter((l) => l.event === 'git_push').at(-1).reason, 'refused:remote');
    gw.ws.close();
  } finally {
    gw.ws?.close();
    await gw.stop();
  }
});

test('the secret scan blocks a committed .env; allowSecretFiles reaches the push container, with the token by name only', async () => {
  const gw = await pushGateway({
    hosts: ['github.com', '127.0.0.1'],
    origin: 'https://127.0.0.1/owner/repo.git',
    credHost: '127.0.0.1',
    files: { 'app.txt': 'hello\n', '.env': 'API_KEY=1\n' },
  });
  try {
    const refused = await push(gw);
    assert.equal(refused.error?.code, -32602, JSON.stringify(refused));
    assert.match(refused.error.message, /look like secrets/);
    assert.deepEqual(refused.error.data.files, ['.env']);
    assert.doesNotMatch(JSON.stringify(refused), new RegExp(TOKEN_VALUE));
    let starts = gw.podmanLog().filter((l) => l.event === 'start');
    assert.ok(starts.every((s) => s.network === 'none'), 'no network before the secret check passes');

    const before = starts.length;
    const allowed = await push(gw, { allowSecretFiles: true });
    assert.equal(allowed.error?.code, -32000, 'the push itself fails: nothing listens as a git server');
    assert.equal(allowed.error.message, 'git push failed');
    assert.doesNotMatch(JSON.stringify(allowed), new RegExp(TOKEN_VALUE));

    starts = gw.podmanLog().filter((l) => l.event === 'start').slice(before);
    assert.equal(starts.length, 4, 'config, names, content and push: one container each');
    const pushStart = starts.at(-1);
    assert.equal(pushStart.network, 'default', 'only the push container has the default network');
    assert.ok(starts.slice(0, -1).every((s) => s.network === 'none'));
    assert.ok(pushStart.args.includes(`ACPCODE_GIT_TOKEN`), 'the token is passed by name with -e');
    assert.ok(!pushStart.args.some((a) => a.includes(TOKEN_VALUE)), 'the token is never in the container command line');
    assert.ok(!gw.podmanLog().some((l) => JSON.stringify(l).includes(TOKEN_VALUE)), 'the token is in no log line');
    assert.doesNotMatch(JSON.stringify(gw.audit), new RegExp(TOKEN_VALUE));
    assert.equal(gw.audit.filter((l) => l.event === 'git_push').at(-1).reason, 'failed:failed');
    gw.ws.close();
  } finally {
    gw.ws?.close();
    await gw.stop();
  }
});

test('a repository config that points a push elsewhere is neutralized before the push', async () => {
  const gw = await pushGateway({
    hosts: ['github.com', '127.0.0.1'],
    origin: 'https://127.0.0.1/owner/repo.git',
    credHost: '127.0.0.1',
    files: { 'app.txt': 'hello\n' },
  });
  try {
    const repo = gw.dirs.project;
    git(repo, 'config', '--local', 'credential.helper', '!echo hostile');
    git(repo, 'config', '--local', 'url.https://evil.example/.insteadOf', 'https://127.0.0.1/');
    git(repo, 'config', '--local', 'remote.origin.pushurl', 'https://evil.example/x.git');
    const res = await push(gw);
    assert.equal(res.error?.code, -32000);
    const left = git(repo, 'config', '--local', '--list');
    assert.doesNotMatch(left, /credential\.helper|insteadof|pushurl/i);
    gw.ws.close();
  } finally {
    gw.ws?.close();
    await gw.stop();
  }
});
