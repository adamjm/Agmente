// The project agent state notification (C2, D-092): `_agmente/project/state`. Change-only, at most
// two per second per project, never in the event log, and only to sockets that listed the project.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { auth, connect, OTHER_TOKEN, rpc, sleep, startGateway } from './helpers.mjs';

// Collects every project state notification the socket gets, with the time it arrived.
function stateFeed(ws) {
  const seen = [];
  ws.setMaxListeners(100); // rpc() adds one close listener per call
  ws.on('message', (data) => {
    const msg = JSON.parse(data.toString());
    if (msg.method === '_agmente/project/state') seen.push({ ...msg.params, at: Date.now() });
  });
  return seen;
}
async function until(pred, what, ms = 10000) {
  for (const t0 = Date.now(); Date.now() - t0 < ms; await sleep(10)) if (pred()) return;
  throw new Error(`timed out waiting for ${what}`);
}
const agents = (feed) => feed.map((n) => n.agent);
const newSession = (ws, gw) => rpc(ws, 'session/new', { cwd: gw.dirs.project, mcpServers: [] });

test('a listing socket sees starting, running, stopping and stopped once each, and nothing for a turn', async () => {
  const gw = await startGateway({ limits: { idleSeconds: 1 } });
  try {
    const ws = (await connect(gw.url, auth())).ws;
    const feed = stateFeed(ws);
    const { project } = (await rpc(ws, '_agmente/projects/create', { name: 'test', path: gw.dirs.project })).result;
    await rpc(ws, '_agmente/sessions/index', { projectId: project.id }); // this socket now lists the project
    const { sessionId } = (await newSession(ws, gw)).result;

    await until(() => agents(feed).includes('running'), 'running');
    assert.deepEqual(agents(feed), ['starting', 'running']);
    assert.deepEqual(feed.map((n) => n.projectId), [project.id, project.id]);
    assert.match(feed[0].since, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/);

    await rpc(ws, 'session/prompt', { sessionId, prompt: [{ type: 'text', text: 'hello' }] });
    await sleep(150);
    assert.deepEqual(agents(feed), ['starting', 'running'], 'a turn does not change the agent state');

    await until(() => agents(feed).includes('stopped'), 'the idle stop', 10000);
    assert.deepEqual(agents(feed), ['starting', 'running', 'stopping', 'stopped']);

    const [session] = (await rpc(ws, '_agmente/sessions/index', { projectId: project.id })).result.sessions;
    assert.equal(session.headSeq, 4, 'the event log holds only the turn: started, chunk, title, ended');
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('only sockets that listed the project get its state; a socket that never listed it gets none', async () => {
  const gw = await startGateway({ limits: { idleSeconds: 60 } });
  try {
    const listing = (await connect(gw.url, auth())).ws;
    const quiet = (await connect(gw.url, auth(OTHER_TOKEN))).ws;
    const listed = stateFeed(listing);
    const unlisted = stateFeed(quiet);
    const { project } = (await rpc(quiet, '_agmente/projects/create', { name: 'test', path: gw.dirs.project })).result;
    await rpc(listing, '_agmente/sessions/index', { projectId: project.id });
    await newSession(quiet, gw); // the agent starts for the quiet socket's request
    await until(() => agents(listed).at(-1) === 'running', 'running');
    await sleep(600); // past the gap, so the next change is sent at once

    assert.equal((await rpc(quiet, '_test/exit', {})).error.code, -32000, 'the agent exits');
    await sleep(600);
    await newSession(quiet, gw); // the next request starts it again
    await until(() => agents(listed).length === 5 && agents(listed).at(-1) === 'running', 'the restart');
    assert.deepEqual(agents(listed), ['starting', 'running', 'stopped', 'starting', 'running']);
    assert.deepEqual(agents(unlisted), [], 'the socket that never listed the project got no state');
    listing.close();
    quiet.close();
  } finally {
    await gw.stop();
  }
});

test('a burst of agent restarts is rate limited to two notifications a second and ends on the true state', async () => {
  const gw = await startGateway({ limits: { idleSeconds: 60 } });
  try {
    const ws = (await connect(gw.url, auth())).ws;
    const feed = stateFeed(ws);
    const { project } = (await rpc(ws, '_agmente/projects/create', { name: 'test', path: gw.dirs.project })).result;
    await rpc(ws, '_agmente/sessions/index', { projectId: project.id });
    const cycles = 6;
    for (let i = 0; i < cycles; i += 1) {
      await rpc(ws, '_test/exit', {}); // stopped
      await newSession(ws, gw); // starting, then running
    }
    await until(() => feed.at(-1)?.agent === 'running' && Date.now() - feed.at(-1).at > 600, 'the last state settles', 10000);

    // Change-only: no two equal notifications in a row.
    for (let i = 1; i < feed.length; i += 1) assert.notEqual(feed[i].agent, feed[i - 1].agent, `change ${i}`);
    // Rate: never two within 450 ms (the gap is 500 ms; the margin is for timer jitter).
    for (let i = 1; i < feed.length; i += 1) assert.ok(feed[i].at - feed[i - 1].at >= 450, `gap ${i}: ${feed[i].at - feed[i - 1].at} ms`);
    const elapsed = feed.at(-1).at - feed[0].at;
    assert.ok(feed.length <= Math.floor(elapsed / 500) + 1, `${feed.length} notifications in ${elapsed} ms`);
    // Coalesced: the burst has 6 exits and 12 starts, but far fewer notifications reach the phone.
    assert.ok(feed.length < cycles, `${feed.length} notifications for ${cycles} restarts`);
    assert.equal(feed.at(-1).agent, 'running', 'the newest state is sent last');
    ws.close();
  } finally {
    await gw.stop();
  }
});
