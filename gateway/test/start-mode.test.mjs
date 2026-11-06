// The start mode on session/new (FR-34): the gateway forwards `_meta["bob/mode"]` to the agent
// unchanged, so the project's default is chosen by the app. This test checks the forwarding and
// that the gateway does not invent a mode when none is sent.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { connect, auth, rpc, startGateway } from './helpers.mjs';

test('session/new forwards _meta["bob/mode"] to the agent, and the agent starts in that mode', async () => {
  const gw = await startGateway();
  try {
    const ws = (await connect(gw.url, auth())).ws;
    const created = await rpc(ws, '_agmente/projects/create', { name: 'modes', path: gw.dirs.project, defaultMode: 'plan' });
    assert.equal(created.result.project.defaultMode, 'plan');

    const withMode = await rpc(ws, 'session/new', { cwd: gw.dirs.project, mcpServers: [], _meta: { 'bob/mode': 'plan' } });
    assert.equal(withMode.result.modes.currentModeId, 'plan');

    const without = await rpc(ws, 'session/new', { cwd: gw.dirs.project, mcpServers: [] });
    assert.equal(without.result.modes.currentModeId, 'agent', 'no _meta means the agent default');
    ws.close();
  } finally {
    await gw.stop();
  }
});
