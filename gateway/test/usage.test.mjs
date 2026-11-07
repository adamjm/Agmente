// Usage on the sessions index (C1, D-092). The fake agent sends the usage_update payloads in
// AGMENTE_TEST_USAGE after each turn's reply; the gateway keeps the last one per session.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { auth, connect, FAKE_AGENT, makeDirs, rawConfig, rpc, spawnGateway, startGateway, useProject } from './helpers.mjs';

const ISO = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/;
const usageEnv = (updates) => ({ AGMENTE_TEST_USAGE: JSON.stringify(updates) });
// The agent gets AGMENTE_TEST_USAGE from the gateway's environment (envPassthrough).
const usageAgent = { command: [process.execPath, FAKE_AGENT], envPassthrough: ['PATH', 'AGMENTE_TEST_USAGE'] };
const index = async (ws, params = {}) => {
  const res = await rpc(ws, '_agmente/sessions/index', params);
  if (!res.result) throw new Error(JSON.stringify(res.error));
  return res.result.sessions;
};
const byId = (sessions, id) => sessions.find((s) => s.sessionId === id);

test('the index shows the last usage_update of a session, cost included when the agent sends it', async () => {
  const first = { used: 1200, size: 200000, cost: { amount: 0.42, currency: 'USD' } };
  const last = { used: 3000, size: 200000, cost: { amount: 0.9, currency: 'USD' } };
  const gw = await startGateway({ agent: usageAgent }, { env: usageEnv([first, last]) });
  try {
    const ws = (await connect(gw.url, auth())).ws;
    const { sessionId } = await useProject(gw, ws);
    assert.equal(byId(await index(ws), sessionId).usage, undefined, 'no usage before a turn');

    await rpc(ws, 'session/prompt', { sessionId, prompt: [{ type: 'text', text: 'hello' }] });
    const usage = byId(await index(ws), sessionId).usage;
    assert.deepEqual(Object.keys(usage), ['used', 'size', 'costAmount', 'costCurrency', 'updatedAt']);
    assert.deepEqual({ ...usage, updatedAt: 'x' }, { used: 3000, size: 200000, costAmount: 0.9, costCurrency: 'USD', updatedAt: 'x' }, 'the last update of the turn wins');
    assert.match(usage.updatedAt, ISO, 'RFC 3339 time the gateway stored the value');
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('the stored usage survives a gateway restart, and the restart starts no agent', async () => {
  const dirs = await makeDirs();
  const config = rawConfig(dirs.root, { agent: usageAgent });
  const env = usageEnv([{ used: 4096, size: 100000 }]);
  let gw = await spawnGateway(config, { env, configDir: dirs.base });
  try {
    let ws = (await connect(gw.url, auth())).ws;
    const { sessionId } = await useProject(gw, ws, dirs.project);
    await rpc(ws, 'session/prompt', { sessionId, prompt: [{ type: 'text', text: 'hello' }] });
    const before = byId(await index(ws), sessionId);
    assert.deepEqual(before.usage && { used: before.usage.used, size: before.usage.size }, { used: 4096, size: 100000 });
    ws.close();
    await gw.stop();

    gw = await spawnGateway(config, { env, configDir: dirs.base });
    ws = (await connect(gw.url, auth())).ws;
    const after = byId(await index(ws), sessionId);
    assert.deepEqual(after.usage, before.usage, 'the same usage, including the stored time, from the database');
    await gw.settle();
    assert.equal(gw.spawned(), 0, 'the index started no agent');
    ws.close();
  } finally {
    await gw.stop();
    await dirs.cleanup();
  }
});

test('no usage field when the agent has sent none, even after turns', async () => {
  const gw = await startGateway({ agent: usageAgent });
  try {
    const ws = (await connect(gw.url, auth())).ws;
    const { sessionId } = await useProject(gw, ws);
    await rpc(ws, 'session/prompt', { sessionId, prompt: [{ type: 'text', text: 'hello' }] });
    const session = byId(await index(ws), sessionId);
    assert.equal('usage' in session, false, 'the field is left out, not null');
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('a usage_update missing size is not stored, so nothing is estimated', async () => {
  const gw = await startGateway({ agent: usageAgent }, { env: usageEnv([{ used: 77 }]) });
  try {
    const ws = (await connect(gw.url, auth())).ws;
    const { sessionId } = await useProject(gw, ws);
    await rpc(ws, 'session/prompt', { sessionId, prompt: [{ type: 'text', text: 'hello' }] });
    assert.equal('usage' in byId(await index(ws), sessionId), false);
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('cost is omitted when the agent sends none, and a later update without cost drops an earlier cost', async () => {
  const gw = await startGateway({ agent: usageAgent }, {
    env: usageEnv([{ used: 10, size: 100, cost: { amount: 1.5, currency: 'USD' } }, { used: 20, size: 100 }]),
  });
  try {
    const ws = (await connect(gw.url, auth())).ws;
    const { sessionId } = await useProject(gw, ws);
    await rpc(ws, 'session/prompt', { sessionId, prompt: [{ type: 'text', text: 'hello' }] });
    const usage = byId(await index(ws), sessionId).usage;
    assert.deepEqual(Object.keys(usage), ['used', 'size', 'updatedAt'], 'no costAmount or costCurrency keys');
    assert.deepEqual([usage.used, usage.size], [20, 100], 'the last update is the figure: no cost in it means no cost');
    ws.close();
  } finally {
    await gw.stop();
  }
});
