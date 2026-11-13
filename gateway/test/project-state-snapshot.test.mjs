// The project state snapshot (G2, D-104). A socket that lists projects (_acpcode/projects/list) or
// sessions (_acpcode/sessions/index) gets, for each listed project, one `_acpcode/project/state` with the
// project's current agent state: "stopped" when no agent runs. It is sent before the listing's response,
// so it is in the socket's feed once the response is back. It is not logged, not audited, and it does not
// change the change-only transitions (usage-project-state.test.mjs).
import { mkdir } from 'node:fs/promises';
import { join } from 'node:path';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { OTHER_TOKEN, WORKING_DIR_NAME, auth, connect, rpc, sleep, startGateway, userProjects } from './helpers.mjs';

// Collects every project state notification the socket gets, in arrival order.
function stateFeed(ws) {
  const seen = [];
  ws.setMaxListeners(100); // rpc() adds one close listener per call
  ws.on('message', (data) => {
    const msg = JSON.parse(data.toString());
    if (msg.method === '_acpcode/project/state') seen.push(msg.params);
  });
  return seen;
}
async function until(pred, what, ms = 10000) {
  for (const t0 = Date.now(); Date.now() - t0 < ms; await sleep(10)) if (pred()) return;
  throw new Error(`timed out waiting for ${what}`);
}
const newSession = (ws, gw) => rpc(ws, 'session/new', { cwd: gw.dirs.project, mcpServers: [] });
const pairs = (feed) => feed.map((n) => [n.projectId, n.agent]);
const stateAudits = (gw) => gw.audit.filter((a) => a.event === 'project_state').length;

test('a new socket that lists a project with a running agent is told "running" for it', async () => {
  const gw = await startGateway({ limits: { idleSeconds: 60 } });
  try {
    const owner = (await connect(gw.url, auth())).ws;
    const { project } = (await rpc(owner, '_acpcode/projects/create', { name: 'test', path: gw.dirs.project })).result;
    await rpc(owner, '_acpcode/sessions/index', { projectId: project.id }); // the owner lists the project
    const ownerFeed = stateFeed(owner);
    await newSession(owner, gw);
    await until(() => ownerFeed.some((n) => n.agent === 'running'), 'running');

    const phone = (await connect(gw.url, auth(OTHER_TOKEN))).ws; // a socket that connects after the agent started
    const feed = stateFeed(phone);
    const listed = (await rpc(phone, '_acpcode/projects/list', {})).result.projects;
    assert.deepEqual(userProjects(listed).map((p) => p.id), [project.id]);
    const workingDirId = listed.find((p) => p.name === WORKING_DIR_NAME).id;
    assert.deepEqual(
      pairs(feed).sort(),
      [[project.id, 'running'], [workingDirId, 'stopped']].sort(),
      'the snapshot arrives with the listing, one entry per listed project',
    );
    assert.match(feed.find((n) => n.projectId === project.id).since, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/);
    phone.close();
    owner.close();
  } finally {
    await gw.stop();
  }
});

test('a listed project with no agent is told "stopped", and no agent starts for it', async () => {
  const gw = await startGateway({ limits: { idleSeconds: 60 } });
  try {
    const ws = (await connect(gw.url, auth())).ws;
    const { project } = (await rpc(ws, '_acpcode/projects/create', { name: 'test', path: gw.dirs.project })).result;
    const feed = stateFeed(ws);
    await rpc(ws, '_acpcode/sessions/index', { projectId: project.id });
    assert.deepEqual(pairs(feed), [[project.id, 'stopped']]);
    assert.equal(gw.spawned(), 0, 'the snapshot starts no agent');
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('a socket that did not list a project gets nothing for it, snapshot or transition', async () => {
  const gw = await startGateway({ limits: { idleSeconds: 60 } });
  try {
    const owner = (await connect(gw.url, auth())).ws;
    const quiet = (await connect(gw.url, auth(OTHER_TOKEN))).ws;
    const { project: busy } = (await rpc(owner, '_acpcode/projects/create', { name: 'busy', path: gw.dirs.project })).result;
    await rpc(owner, '_acpcode/sessions/index', { projectId: busy.id });
    const ownerFeed = stateFeed(owner);
    await newSession(owner, gw);
    await until(() => ownerFeed.some((n) => n.agent === 'running'), 'running');

    const idleDir = join(gw.dirs.root, 'idle');
    await mkdir(idleDir, { recursive: true });
    const { project: idle } = (await rpc(quiet, '_acpcode/projects/create', { name: 'idle', path: idleDir })).result;
    const quietFeed = stateFeed(quiet);
    await rpc(quiet, '_acpcode/sessions/index', { projectId: idle.id }); // quiet lists only the idle project
    await sleep(100);
    assert.deepEqual(pairs(quietFeed), [[idle.id, 'stopped']]);

    assert.equal((await rpc(owner, '_test/exit', {})).error.code, -32000, 'the busy project agent exits');
    await until(() => ownerFeed.some((n) => n.agent === 'stopped'), 'the busy project stops');
    await sleep(600);
    assert.deepEqual(pairs(quietFeed).filter(([pid]) => pid === busy.id), [], 'nothing for the busy project');
    owner.close();
    quiet.close();
  } finally {
    await gw.stop();
  }
});

test('one listing sends each listed project one snapshot, with no duplicates and no audit lines', async () => {
  const gw = await startGateway({ limits: { idleSeconds: 60 } });
  try {
    const owner = (await connect(gw.url, auth())).ws;
    const { project: first } = (await rpc(owner, '_acpcode/projects/create', { name: 'first', path: gw.dirs.project })).result;
    await rpc(owner, '_acpcode/sessions/index', { projectId: first.id });
    await newSession(owner, gw);
    await until(() => gw.spawned() === 1, 'the agent starts');
    await sleep(600); // the transitions are sent and audited before the listing

    const secondDir = join(gw.dirs.root, 'second');
    await mkdir(secondDir, { recursive: true });
    const { project: second } = (await rpc(owner, '_acpcode/projects/create', { name: 'second', path: secondDir })).result;
    const phone = (await connect(gw.url, auth(OTHER_TOKEN))).ws;
    const feed = stateFeed(phone);
    const audits = stateAudits(gw);
    const listed = (await rpc(phone, '_acpcode/projects/list', {})).result.projects;
    const workingDirId = listed.find((p) => p.name === WORKING_DIR_NAME).id;
    await sleep(700); // long enough for a duplicate, if one were sent
    assert.deepEqual(
      pairs(feed).sort(),
      [[first.id, 'running'], [second.id, 'stopped'], [workingDirId, 'stopped']].sort(),
      'one snapshot per listed project',
    );
    assert.equal(stateAudits(gw), audits, 'a snapshot is not audited');
    phone.close();
    owner.close();
  } finally {
    await gw.stop();
  }
});
