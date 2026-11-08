// The Apple container runner (migration step 3, D-079), on fixtures/fake-container.mjs as the CLI:
// git goes through `container exec` into the running agent container when there is one, through a
// one-off `run --rm --network none` container when there is not, and a git call that times out is
// killed inside the container, not only as the CLI process.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, writeFileSync, chmodSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { auth, connect, FAKE_AGENT, rpc, sleep, startGateway, useProject } from './helpers.mjs';

const FAKE_CONTAINER = fileURLToPath(new URL('./fixtures/fake-container.mjs', import.meta.url));

async function appleGateway({ gitProgram } = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'acpcode-apple-'));
  const gw = await startGateway({ limits: { idleSeconds: 60 } }, {
    configFn: (dirs, config) => {
      config.runner = { kind: 'apple', image: 'fake-image:1', container: FAKE_CONTAINER };
      config.agent.command = [process.execPath, FAKE_AGENT];
    },
    env: { FAKE_CONTAINER_DIR: dir, ...(gitProgram ? { FAKE_CONTAINER_GIT: gitProgram } : {}) },
  });
  gw.containerLog = () => (existsSync(join(dir, 'log.jsonl'))
    ? readFileSync(join(dir, 'log.jsonl'), 'utf8').trim().split('\n').filter(Boolean).map((l) => JSON.parse(l)) : []);
  return gw;
}

function initRepo(dir) {
  const git = (...args) => execFileSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@t', ...args], { cwd: dir });
  git('init', '-q', '-b', 'main');
  writeFileSync(join(dir, 'a.txt'), 'hi\n');
  git('add', '-A');
  git('commit', '-q', '-m', 'init');
}

test('git uses container exec into the running agent container when a session is open', async () => {
  const gw = await appleGateway();
  try {
    initRepo(gw.dirs.project);
    const ws = (await connect(gw.url, auth())).ws;
    const { project } = await useProject(gw, ws);
    const before = gw.containerLog().length;
    const res = await rpc(ws, '_acpcode/git/status', { projectId: project.id });
    assert.equal(res.result.branch, 'main');
    const after = gw.containerLog().slice(before);
    const execs = after.filter((e) => e.event === 'exec' && e.name === `acpcode-${project.id}`);
    assert.ok(execs.some((e) => e.argv0 === 'git' && /\bstatus\b/.test(e.args)), `git was not exec'd: ${JSON.stringify(after)}`);
    assert.deepEqual(after.filter((e) => e.event === 'start' && e.name.startsWith('acpcode-git-')), [], 'no one-off git container when the agent is up');
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('git gets a one-off container with no network when no agent container is up', async () => {
  const gw = await appleGateway();
  try {
    initRepo(gw.dirs.project);
    const ws = (await connect(gw.url, auth())).ws;
    const created = await rpc(ws, '_acpcode/projects/create', { name: 'p', path: gw.dirs.project });
    const id = created.result.project.id;
    const res = await rpc(ws, '_acpcode/git/status', { projectId: id });
    assert.equal(res.result.branch, 'main');
    const starts = gw.containerLog().filter((e) => e.event === 'start' && e.name.startsWith('acpcode-git-'));
    assert.ok(starts.length >= 1, 'git ran in one-off containers');
    for (const s of starts) {
      assert.match(s.args, /--network none/);
      assert.match(s.args, /--entrypoint git fake-image:1/);
    }
    assert.equal(gw.containerLog().filter((e) => e.event === 'exec').length, 0, 'no exec without an agent');
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('a git call that times out is killed inside the container, not only as the CLI', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'acpcode-hang-'));
  const hang = join(dir, 'hang-git.sh');
  writeFileSync(hang, '#!/bin/sh\nexec sleep 30\n');
  chmodSync(hang, 0o755);
  const gw = await appleGateway({ gitProgram: hang });
  try {
    initRepo(gw.dirs.project);
    const ws = (await connect(gw.url, auth())).ws;
    const { project } = await useProject(gw, ws);
    const res = await rpc(ws, '_acpcode/git/status', { projectId: project.id });
    assert.match(res.error?.message ?? '', /git timeout/, JSON.stringify(res));
    const killed = gw.containerLog().find((e) => e.event === 'killed');
    assert.ok(killed, 'the cleanup killed the process inside the container');
    const exec = gw.containerLog().find((e) => e.event === 'exec' && e.pid === killed.pid);
    assert.ok(exec && exec.argv0 === 'git', 'the killed process is the git exec the gateway started');
    let alive = true;
    for (let i = 0; i < 40 && alive; i += 1) {
      try { process.kill(killed.pid, 0); await sleep(50); } catch { alive = false; }
    }
    assert.equal(alive, false, 'the hung process is gone');
    ws.close();
  } finally {
    await gw.stop();
  }
});
