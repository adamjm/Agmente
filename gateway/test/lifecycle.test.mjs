// Project lifecycle with a fake container runner (T-46, FR-24, FR-45, PLAN 3.12, D-015, D-016, D-032).
// The gateway uses its podman runner with fixtures/fake-podman.mjs as the podman binary. The fake
// refuses a second container with a name in use, as Podman does, and logs each start and exit, so
// the tests can check that a project never has two containers at once. limits.idleSeconds is 1.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { auth, connect, FAKE_AGENT, rpc, sleep, startGateway, useProject } from './helpers.mjs';

const FAKE_PODMAN = fileURLToPath(new URL('./fixtures/fake-podman.mjs', import.meta.url));

/** A gateway on the fake podman, with its own log folder (FAKE_PODMAN_DIR reaches podman through the gateway environment). */
async function lifecycle({ startMs = 0, exitDelayMs = 0 } = {}) {
  const { mkdtemp } = await import('node:fs/promises');
  const { tmpdir } = await import('node:os');
  const dir = await mkdtemp(join(tmpdir(), 'agmente-podman-'));
  const gw = await startGateway({ limits: { idleSeconds: 1 } }, {
    configFn: (dirs, config) => {
      config.runner = { kind: 'podman', image: 'fake-image:1', podman: FAKE_PODMAN };
      config.agent.command = [process.execPath, FAKE_AGENT, ...(exitDelayMs ? ['--exit-delay', String(exitDelayMs)] : [])];
    },
    env: { FAKE_PODMAN_DIR: dir, FAKE_PODMAN_START_MS: String(startMs) },
  });
  gw.podmanLog = () => (existsSync(join(dir, 'log.jsonl'))
    ? readFileSync(join(dir, 'log.jsonl'), 'utf8').trim().split('\n').filter(Boolean).map((l) => JSON.parse(l)) : []);
  return gw;
}

/** At most one container per name at any time, and Podman never had to refuse one. */
function assertOneAtATime(log) {
  log = agentOnly(log);
  assert.deepEqual(log.filter((e) => e.event === 'refused'), [], 'no second container was attempted');
  const running = new Map();
  for (const e of log) {
    if (e.event === 'start') {
      assert.equal(running.get(e.name) ?? 0, 0, `two containers named ${e.name}`);
      running.set(e.name, 1);
    } else if (e.event === 'exit') running.set(e.name, 0);
  }
}
// The lock is the agent container's name. Git runs (turn snapshots, D-034) use their own short-lived
// containers, named agmente-git-..., which the lifecycle does not manage.
const agentOnly = (log) => log.filter((e) => !e.name?.startsWith('agmente-git-'));
const starts = (log) => agentOnly(log).filter((e) => e.event === 'start');
const exits = (log) => agentOnly(log).filter((e) => e.event === 'exit');
async function until(pred, what, ms = 10000) {
  for (const t0 = Date.now(); Date.now() - t0 < ms; await sleep(20)) if (await pred()) return;
  throw new Error(`timed out waiting for ${what}`);
}
function eventKinds(gw, sessionId) {
  const db = new DatabaseSync(join(gw.config.stateDir, 'gateway.db'), { readOnly: true });
  try {
    return db.prepare('SELECT kind, message FROM events WHERE session_id = ? ORDER BY seq').all(sessionId)
      .map((r) => ({ kind: r.kind, update: JSON.parse(r.message).params?.update?.sessionUpdate }));
  } finally {
    db.close();
  }
}
const prompt = (ws, sessionId, text) => rpc(ws, 'session/prompt', { sessionId, prompt: [{ type: 'text', text }] });

test('T-46: the first requests start one container, even when several arrive while it starts', async () => {
  const gw = await lifecycle({ startMs: 400 });
  try {
    const a = (await connect(gw.url, auth())).ws;
    const b = (await connect(gw.url, auth())).ws;
    await rpc(a, '_agmente/projects/create', { name: 'p', path: gw.dirs.project });
    assert.deepEqual(starts(gw.podmanLog()), [], 'registering starts nothing');
    const [ra, rb] = await Promise.all([a, b].map((ws) => rpc(ws, 'session/new', { cwd: gw.dirs.project, mcpServers: [] })));
    assert.ok(ra.result.sessionId && rb.result.sessionId);
    assert.equal(starts(gw.podmanLog()).length, 1);
    assert.equal(gw.spawned(), 1);
    assertOneAtATime(gw.podmanLog());
    for (const ws of [a, b]) ws.close();
  } finally {
    await gw.stop();
  }
});

test('T-46: idle past the idle time stops the container; the next prompt starts a new one and opens the session again', async () => {
  const gw = await lifecycle();
  try {
    const a = (await connect(gw.url, auth())).ws;
    const { sessionId } = await useProject(gw, a);
    assert.deepEqual((await prompt(a, sessionId, 'hi')).result, { stopReason: 'end_turn' });
    const idleFrom = Date.now();
    await until(() => exits(gw.podmanLog()).length === 1, 'the idle stop', 6000);
    const stoppedAfter = exits(gw.podmanLog())[0].t - idleFrom;
    assert.ok(stoppedAfter >= 900 && stoppedAfter < 2500, `stopped ${stoppedAfter} ms after the last activity`);
    await gw.waitForAudit((l) => l.event === 'agent_idle_stop');

    // The phone keeps its socket and prompts again, with no load of its own.
    assert.deepEqual((await prompt(a, sessionId, 'again')).result, { stopReason: 'end_turn' });
    assert.equal(starts(gw.podmanLog()).length, 2);
    const received = (await rpc(a, '_test/received', {})).result.methods;
    assert.deepEqual(received.slice(0, 4), ['initialize', 'session/load', 'session/list', 'session/prompt'], 'one load by the gateway, its fence, then the prompt');
    assert.equal(eventKinds(gw, sessionId).some((e) => ['user_message_chunk', 'available_commands_update'].includes(e.update)), false, 'the load replay was not logged');
    assertOneAtATime(gw.podmanLog());
    a.close();
  } finally {
    await gw.stop();
  }
});

test('T-46: a pending approval keeps the container running past the idle time; it stops after the answer', async () => {
  const gw = await lifecycle();
  try {
    const a = (await connect(gw.url, auth())).ws;
    const { sessionId } = await useProject(gw, a);
    const seen = [];
    a.on('message', (d) => seen.push(JSON.parse(d.toString())));
    const turn = prompt(a, sessionId, 'go [permission]');
    await until(() => seen.some((m) => m.method === 'session/request_permission'), 'the request');
    await sleep(2500);
    assert.deepEqual(exits(gw.podmanLog()), [], 'still running with the approval open');
    const req = seen.find((m) => m.method === 'session/request_permission');
    assert.deepEqual((await rpc(a, '_agmente/approvals/answer', { approvalId: req.id, optionId: 'cancel' })).result, {});
    await turn;
    await until(() => exits(gw.podmanLog()).length === 1, 'the idle stop after the answer', 6000);
    assertOneAtATime(gw.podmanLog());
    a.close();
  } finally {
    await gw.stop();
  }
});

test('T-46: a subscriber keeps the container running; it stops once the subscriber leaves', async () => {
  const gw = await lifecycle();
  try {
    const a = (await connect(gw.url, auth())).ws;
    const { sessionId } = await useProject(gw, a);
    await prompt(a, sessionId, 'hi');
    a.close();
    const s = (await connect(gw.url, auth())).ws;
    await rpc(s, '_agmente/sessions/subscribe', { sessionId, afterSeq: 0 });
    await sleep(2500);
    assert.deepEqual(exits(gw.podmanLog()), [], 'still running with a subscriber');
    const left = Date.now();
    s.close();
    await until(() => exits(gw.podmanLog()).length === 1, 'the idle stop after the subscriber left', 6000);
    assert.ok(exits(gw.podmanLog())[0].t - left >= 900, 'the idle time counts from when the subscriber left');
    assertOneAtATime(gw.podmanLog());
  } finally {
    await gw.stop();
  }
});

test('T-46: a request during the stop waits for the exit, then starts a new container', async () => {
  const gw = await lifecycle({ exitDelayMs: 700 }); // the agent takes 700 ms to exit after SIGTERM
  try {
    const a = (await connect(gw.url, auth())).ws;
    const { sessionId } = await useProject(gw, a);
    await prompt(a, sessionId, 'hi');
    await gw.waitForAudit((l) => l.event === 'agent_idle_stop', 6000);
    const sent = Date.now();
    assert.deepEqual((await prompt(a, sessionId, 'during the stop')).result, { stopReason: 'end_turn' });
    const log = gw.podmanLog();
    assert.equal(starts(log).length, 2);
    assert.ok(exits(log)[0].t <= starts(log)[1].t, 'the new container started after the old one exited');
    assert.ok(exits(log)[0].t - sent >= 300, 'the request really arrived during the stop');
    assertOneAtATime(log);
    a.close();
  } finally {
    await gw.stop();
  }
});

test('FR-24: an idle session is closed while another session keeps the project busy; it opens again on use', async () => {
  const gw = await lifecycle();
  try {
    const a = (await connect(gw.url, auth())).ws;
    const { sessionId: busy } = await useProject(gw, a);
    const idle = (await rpc(a, 'session/new', { cwd: gw.dirs.project, mcpServers: [] })).result.sessionId;
    await prompt(a, idle, 'hi');
    const long = prompt(a, busy, 'long [chunks:300][slow:10]');
    const live = async () => (await rpc(a, '_test/state', {})).result.live.map((l) => l.sessionId);
    await until(async () => !(await live()).includes(idle), 'the idle session closed', 6000);
    assert.ok((await live()).includes(busy), 'the busy session stays open');
    await gw.waitForAudit((l) => l.event === 'session_idle_close' && l.reason === idle);
    assert.equal(gw.audit.some((l) => l.event === 'session_idle_close' && l.reason === busy), false);
    assert.deepEqual(exits(gw.podmanLog()), [], 'the project kept running');

    assert.deepEqual((await prompt(a, idle, 'back')).result, { stopReason: 'end_turn' }, 'the closed session opens again on use');
    assert.deepEqual((await long).result, { stopReason: 'end_turn' });
    assert.equal(eventKinds(gw, idle).some((e) => e.update === 'user_message_chunk'), false, 'no replay in the log');
    assertOneAtATime(gw.podmanLog());
    a.close();
  } finally {
    await gw.stop();
  }
});
