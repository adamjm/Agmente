// Stopping a turn or a project's agent, the stall flag, the idle rule for a hung agent, and the
// removal of leftover containers (D-106). The gateway runs its podman runner with fixtures/fake-podman.mjs,
// which keeps a name file per container, stops a container with `rm -f`, and logs every start,
// exit and removal. The fake agent has a hang mode (ACPCODE_TEST_HANG: a prompt is never answered)
// and an ignore-SIGTERM mode (ACPCODE_TEST_IGNORE_TERM).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { mkdtemp } from 'node:fs/promises';
import { DatabaseSync } from 'node:sqlite';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { auth, connect, FAKE_AGENT, rpc, sleep, startGateway, useProject } from './helpers.mjs';

const FAKE_PODMAN = fileURLToPath(new URL('./fixtures/fake-podman.mjs', import.meta.url));

/** A gateway on the fake podman. agentEnv names the variables the agent may read (its env passthrough). */
async function gateway({ limits = {}, env = {}, agentEnv = [] } = {}) {
  const dir = await mkdtemp(join(tmpdir(), 'acpcode-stop-'));
  const gw = await startGateway({ limits: { idleSeconds: 600, ...limits } }, {
    configFn: (dirs, config) => {
      config.runner = { kind: 'podman', image: 'fake-image:1', podman: FAKE_PODMAN };
      config.agent.command = [process.execPath, FAKE_AGENT];
      config.agent.envPassthrough = ['PATH', ...agentEnv];
    },
    env: { FAKE_PODMAN_DIR: dir, ...env },
  });
  gw.podmanDir = dir;
  gw.podmanLog = () => (existsSync(join(dir, 'log.jsonl'))
    ? readFileSync(join(dir, 'log.jsonl'), 'utf8').trim().split('\n').filter(Boolean).map((l) => JSON.parse(l)) : []);
  return gw;
}

const events = (log, event) => log.filter((e) => e.event === event && !e.name?.startsWith('acpcode-git-'));
const prompt = (ws, sessionId, text) => rpc(ws, 'session/prompt', { sessionId, prompt: [{ type: 'text', text }] });
const stop = (ws, params) => rpc(ws, '_acpcode/sessions/stop', params);
const stopOf = async (ws, params) => {
  const r = await stop(ws, params);
  assert.equal(r.error, undefined, `stop failed: ${JSON.stringify(r.error)}`);
  return r.result;
};

async function indexRow(ws, sessionId) {
  const r = await rpc(ws, '_acpcode/sessions/index', {});
  return r.result.sessions.find((s) => s.sessionId === sessionId);
}
async function until(pred, what, ms = 10000) {
  for (const t0 = Date.now(); Date.now() - t0 < ms; await sleep(20)) if (await pred()) return;
  throw new Error(`timed out waiting for ${what}`);
}
async function newSession(ws, gw) {
  const r = await rpc(ws, 'session/new', { cwd: gw.dirs.project, mcpServers: [] });
  assert.ok(r.result?.sessionId, JSON.stringify(r));
  return r.result.sessionId;
}
function turnEnds(gw, sessionId) {
  const db = new DatabaseSync(join(gw.config.stateDir, 'gateway.db'), { readOnly: true });
  try {
    return db.prepare("SELECT message FROM events WHERE session_id = ? AND kind = 'turn_ended' ORDER BY seq").all(sessionId)
      .map((r) => JSON.parse(r.message).params);
  } finally {
    db.close();
  }
}

test('D-106 turn stop: a cooperative agent ends the prompt as cancelled, the agent keeps running, and a second stop is not_running', async () => {
  const gw = await gateway();
  try {
    const a = (await connect(gw.url, auth())).ws;
    const b = (await connect(gw.url, auth())).ws;
    const { sessionId } = await useProject(gw, a);
    const running = prompt(a, sessionId, '[chunks:40][slow:100] a long reply');
    await until(async () => (await indexRow(b, sessionId))?.status === 'running', 'the turn to run');

    assert.deepEqual(await stopOf(b, { sessionId, scope: 'turn' }), { outcome: 'cancelled', stoppedSessions: [sessionId] });
    assert.deepEqual((await running).result, { stopReason: 'cancelled' });
    assert.deepEqual(await stopOf(b, { sessionId }), { outcome: 'not_running', stoppedSessions: [] }, 'a second stop is not_running');
    assert.equal(events(gw.podmanLog(), 'exit').length, 0, 'a turn stop does not stop the agent');

    const ends = turnEnds(gw, sessionId);
    assert.equal(ends.length, 1);
    assert.equal(ends[0].stopReason, 'cancelled');
    assert.equal(ends[0].stopped, undefined, 'a cooperative cancel is not a gateway stop');
    assert.equal((await indexRow(b, sessionId)).status, 'idle');
    a.close();
    b.close();
  } finally {
    await gw.stop();
  }
});

test('D-106 hung agent: the turn stop reports still_running, the agent stop ends the prompt and removes the container by name', async () => {
  const gw = await gateway({ limits: { stallSeconds: 1 }, env: { ACPCODE_TEST_HANG: '1' }, agentEnv: ['ACPCODE_TEST_HANG'] });
  try {
    const a = (await connect(gw.url, auth())).ws;
    const b = (await connect(gw.url, auth())).ws;
    const { sessionId } = await useProject(gw, a);
    const hung = prompt(a, sessionId, 'hello');
    await until(async () => (await indexRow(b, sessionId))?.status === 'running', 'the turn to run');

    assert.deepEqual(await stopOf(b, { sessionId, scope: 'turn' }), { outcome: 'still_running', stoppedSessions: [] });
    const name = events(gw.podmanLog(), 'start')[0].name;
    assert.equal(existsSync(join(gw.podmanDir, `${name}.name`)), true, 'the container is still there');

    assert.deepEqual(await stopOf(b, { sessionId, scope: 'agent' }), { outcome: 'stopped', stoppedSessions: [sessionId] });
    // The container is gone by the time the stop answers, not at the next start.
    assert.equal(existsSync(join(gw.podmanDir, `${name}.name`)), false, 'the container name is freed by the stop');
    assert.equal(events(gw.podmanLog(), 'exit').length, 1, 'the agent exited');
    assert.deepEqual((await hung).result, { stopReason: 'cancelled' }, 'the prompt was ended as cancelled');
    const ends = turnEnds(gw, sessionId);
    assert.equal(ends.at(-1).stopped, true, 'the stop is recorded on the turn');
    assert.equal(ends.at(-1).stopReason, 'cancelled');
    assert.equal((await stopOf(b, { sessionId, scope: 'agent' })).outcome, 'not_running', 'a stop of a stopped agent is not_running');
    a.close();
    b.close();
  } finally {
    await gw.stop();
  }
});

test('D-106 agent stop is refused while another session runs, and force ends both', async () => {
  const gw = await gateway();
  try {
    const a = (await connect(gw.url, auth())).ws;
    const b = (await connect(gw.url, auth())).ws;
    const s1 = (await useProject(gw, a)).sessionId;
    const s2 = await newSession(a, gw);
    const running = prompt(a, s1, '[chunks:30][slow:100] busy');
    await until(async () => (await indexRow(b, s1))?.status === 'running', 'the other turn to run');

    const refused = await stop(b, { sessionId: s2, scope: 'agent' });
    assert.equal(refused.error?.code, -32001);
    assert.equal(refused.error.data.reason, 'busy_elsewhere');
    assert.deepEqual(refused.error.data.otherSessions, [{ sessionId: s1, status: 'running' }]);
    assert.equal(events(gw.podmanLog(), 'exit').length, 0, 'the refusal changed nothing');
    assert.equal((await indexRow(b, s1)).status, 'running');
    assert.deepEqual((await running).result, { stopReason: 'end_turn' }, 'the other turn finished on its own');

    const again = prompt(a, s1, '[chunks:30][slow:100] busy again');
    await until(async () => (await indexRow(b, s1))?.status === 'running', 'the second turn to run');
    assert.deepEqual(await stopOf(b, { sessionId: s2, scope: 'agent', force: true }), { outcome: 'stopped', stoppedSessions: [s1] });
    assert.deepEqual((await again).result, { stopReason: 'cancelled' });
    a.close();
    b.close();
  } finally {
    await gw.stop();
  }
});

test('D-106 two concurrent agent stops: one stops, the other is not_running, and one container is removed', async () => {
  const gw = await gateway();
  try {
    const a = (await connect(gw.url, auth())).ws;
    const b = (await connect(gw.url, auth())).ws;
    const c = (await connect(gw.url, auth())).ws;
    const { sessionId } = await useProject(gw, a);
    const running = prompt(a, sessionId, '[chunks:40][slow:100] concurrent');
    await until(async () => (await indexRow(b, sessionId))?.status === 'running', 'the turn to run');

    const [r1, r2] = await Promise.all([
      stopOf(b, { sessionId, scope: 'agent' }),
      stopOf(c, { sessionId, scope: 'agent' }),
    ]);
    assert.deepEqual([r1.outcome, r2.outcome].sort(), ['not_running', 'stopped']);
    assert.equal(events(gw.podmanLog(), 'exit').length, 1, 'one container was stopped');
    assert.equal(events(gw.podmanLog(), 'start').length, 1, 'no second start');
    assert.deepEqual((await running).result, { stopReason: 'cancelled' });
    for (const ws of [a, b, c]) ws.close();
  } finally {
    await gw.stop();
  }
});

test('D-106 the stall flag is set after limits.stallSeconds with no event, and an open approval is not a stall', async () => {
  const gw = await gateway({ limits: { stallSeconds: 1 }, env: { ACPCODE_TEST_HANG: '1' }, agentEnv: ['ACPCODE_TEST_HANG'] });
  try {
    const a = (await connect(gw.url, auth())).ws;
    const { sessionId } = await useProject(gw, a);
    prompt(a, sessionId, 'hung').catch(() => {}); // the socket closes at the end of the test
    await until(async () => (await indexRow(a, sessionId))?.stalled === true, 'the stall flag');
    const row = await indexRow(a, sessionId);
    assert.equal(row.status, 'running', 'the status is still running: the flag only adds stalled');
    assert.match(row.lastEventAt, /^\d{4}-\d{2}-\d{2}T/);
    assert.equal(events(gw.podmanLog(), 'exit').length, 0, 'nothing was stopped');
    a.close();
  } finally {
    await gw.stop();
  }
});

test('D-106 an approval held open is not flagged stalled', async () => {
  const gw = await gateway({ limits: { stallSeconds: 1 } });
  try {
    const a = (await connect(gw.url, auth())).ws;
    const { sessionId } = await useProject(gw, a);
    prompt(a, sessionId, '[permission] wait for me').catch(() => {});
    await until(async () => (await indexRow(a, sessionId))?.status === 'awaiting_approval', 'the approval');
    await sleep(1500);
    const row = await indexRow(a, sessionId);
    assert.equal(row.status, 'awaiting_approval');
    assert.equal(row.stalled, false);
    a.close();
  } finally {
    await gw.stop();
  }
});

test('D-106 idle rule: a hung agent is idle-stopped, because its stalled turn does not keep the project awake', async () => {
  const gw = await gateway({ limits: { idleSeconds: 2, stallSeconds: 1 }, env: { ACPCODE_TEST_HANG: '1' }, agentEnv: ['ACPCODE_TEST_HANG'] });
  try {
    const a = (await connect(gw.url, auth())).ws;
    const { sessionId } = await useProject(gw, a);
    prompt(a, sessionId, 'hung for ever').catch(() => {});
    await gw.waitForAudit((l) => l.event === 'agent_idle_stop', 8000);
    await until(() => events(gw.podmanLog(), 'exit').length === 1, 'the container exit');
    a.close();
  } finally {
    await gw.stop();
  }
});

test('D-106 unknown session and a bad scope are refused with -32602', async () => {
  const gw = await gateway();
  try {
    const a = (await connect(gw.url, auth())).ws;
    const { sessionId } = await useProject(gw, a);
    const unknown = await stop(a, { sessionId: '00000000-0000-4000-8000-000000000000', scope: 'turn' });
    assert.equal(unknown.error?.code, -32602);
    assert.equal(unknown.error.data?.reason, 'unknown_session');
    const badScope = await stop(a, { sessionId, scope: 'everything' });
    assert.equal(badScope.error?.code, -32602);
    a.close();
  } finally {
    await gw.stop();
  }
});

test('D-106 idempotent: stops with no running turn or agent answer not_running, with no error', async () => {
  const gw = await gateway();
  try {
    const a = (await connect(gw.url, auth())).ws;
    const { sessionId } = await useProject(gw, a);
    assert.deepEqual(await stopOf(a, { sessionId }), { outcome: 'not_running', stoppedSessions: [] }, 'no turn');
    assert.deepEqual(await stopOf(a, { sessionId, scope: 'agent' }), { outcome: 'stopped', stoppedSessions: [] }, 'an idle agent is stopped');
    assert.deepEqual(await stopOf(a, { sessionId, scope: 'agent' }), { outcome: 'not_running', stoppedSessions: [] }, 'the second stop');
    assert.deepEqual(await stopOf(a, { sessionId, scope: 'agent' }), { outcome: 'not_running', stoppedSessions: [] }, 'and the third');
    a.close();
  } finally {
    await gw.stop();
  }
});

test('D-106 the next prompt after a stop starts a new agent and works', async () => {
  const gw = await gateway();
  try {
    const a = (await connect(gw.url, auth())).ws;
    const { sessionId } = await useProject(gw, a);
    await stopOf(a, { sessionId, scope: 'agent' });
    assert.deepEqual((await prompt(a, sessionId, 'again')).result, { stopReason: 'end_turn' });
    assert.equal(events(gw.podmanLog(), 'start').length, 2);
    a.close();
  } finally {
    await gw.stop();
  }
});

test('D-106 a container that survived its CLI is removed at the next start, so the start works', async () => {
  const gw = await gateway();
  try {
    const a = (await connect(gw.url, auth())).ws;
    const created = await rpc(a, '_acpcode/projects/create', { name: 'leftover', path: gw.dirs.project });
    const name = `acpcode-${created.result.project.id}`;
    writeFileSync(join(gw.podmanDir, `${name}.name`), JSON.stringify({ pid: 999999 })); // left behind by a dead CLI
    const r = await rpc(a, 'session/new', { cwd: gw.dirs.project, mcpServers: [] });
    assert.ok(r.result?.sessionId, `the start failed: ${JSON.stringify(r.error)}`);
    const log = gw.podmanLog();
    const removed = log.findIndex((e) => e.event === 'removed' && e.name === name);
    const started = log.findIndex((e) => e.event === 'start' && e.name === name);
    assert.ok(removed >= 0 && removed < started, 'the leftover was removed before the new container started');
    assert.equal(events(log, 'refused').length, 0, 'no name clash');
    a.close();
  } finally {
    await gw.stop();
  }
});

test('D-106 a stop kills an agent that ignores SIGTERM, after the kill grace, and removes the container', async () => {
  const gw = await gateway({
    env: { FAKE_PODMAN_IGNORE_TERM: '1', ACPCODE_TEST_IGNORE_TERM: '1' },
    agentEnv: ['ACPCODE_TEST_IGNORE_TERM'],
  });
  try {
    const a = (await connect(gw.url, auth())).ws;
    const { sessionId } = await useProject(gw, a);
    const name = events(gw.podmanLog(), 'start')[0].name;
    const t0 = Date.now();
    assert.deepEqual(await stopOf(a, { sessionId, scope: 'agent' }), { outcome: 'stopped', stoppedSessions: [] });
    assert.ok(Date.now() - t0 >= 1500, 'the CLI ignored SIGTERM, so the stop waited for the kill grace');
    assert.equal(existsSync(join(gw.podmanDir, `${name}.name`)), false);
    assert.equal(events(gw.podmanLog(), 'removed').filter((e) => e.name === name).length, 1);
    a.close();
  } finally {
    await gw.stop();
  }
});
