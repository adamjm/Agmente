// ACP model selection (unstable `models` field and session/set_model; verify: not in upstream ACP
// schema as of 2026-11-10). The gateway is a pass-through for these values: it forwards set_model to
// the agent, returns the agent's answer, and keeps the current model the agent accepted so a later
// load of a live session is answered with it (the same as modes, reopen.test.mjs).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { auth, connect, rpc, startGateway } from './helpers.mjs';

// What the fake agent returns for a session/new that asks for models (fixtures/fake-agent.mjs).
const MODELS = {
  availableModels: [
    { modelId: 'fast', name: 'Fast', description: 'Quick answers' },
    { modelId: 'deep', name: 'Deep', description: 'Thinks longer' },
  ],
  currentModelId: 'fast',
};
const WANT_MODELS = { _meta: { 'bob/models': true } };

/** Methods the current agent process received from the gateway. */
const received = async (ws) => (await rpc(ws, '_test/received', {})).result.methods;

async function newSession(gw, ws) {
  await rpc(ws, '_acpcode/projects/create', { name: 'test', path: gw.dirs.project });
  return rpc(ws, 'session/new', { cwd: gw.dirs.project, mcpServers: [], ...WANT_MODELS });
}

test('session/new: the models object from the agent reaches the phone unchanged', async () => {
  const gw = await startGateway();
  try {
    const a = (await connect(gw.url, auth())).ws;
    const res = await newSession(gw, a);
    assert.deepEqual(res.result.models, MODELS);
    assert.ok(res.result.sessionId, 'the session id comes back with the models');
    a.close();
  } finally {
    await gw.stop();
  }
});

test('session/set_model from the phone is forwarded to the agent, and the agent answer returns', async () => {
  const gw = await startGateway();
  try {
    const a = (await connect(gw.url, auth())).ws;
    const { sessionId } = (await newSession(gw, a)).result;

    assert.deepEqual((await rpc(a, 'session/set_model', { sessionId, modelId: 'deep' })).result, {});
    // The agent refuses an unknown model: the error is the agent's, so the gateway passed the request on.
    const refused = await rpc(a, 'session/set_model', { sessionId, modelId: 'no-such-model' });
    assert.equal(refused.error?.code, -32602);
    assert.match(refused.error?.message ?? '', /Unknown model/);
    assert.ok((await received(a)).includes('session/set_model'), 'the agent received session/set_model');
    a.close();
  } finally {
    await gw.stop();
  }
});

test('a later session/load of a live session is answered with the model the agent accepted, without reaching the agent', async () => {
  const gw = await startGateway();
  try {
    const a = (await connect(gw.url, auth())).ws;
    const { sessionId } = (await newSession(gw, a)).result;
    assert.deepEqual((await rpc(a, 'session/set_model', { sessionId, modelId: 'deep' })).result, {});

    for (const method of ['session/load', 'session/resume']) {
      const ws = (await connect(gw.url, auth())).ws;
      const res = await rpc(ws, method, { sessionId, cwd: gw.dirs.project, mcpServers: [] });
      assert.equal(res.result.models.currentModelId, 'deep', `${method}: the cached model follows set_model`);
      assert.deepEqual(res.result.models.availableModels, MODELS.availableModels, `${method}: the list is unchanged`);
      ws.close();
    }
    const methods = await received(a);
    assert.equal(methods.filter((m) => m === 'session/load' || m === 'session/resume').length, 0,
      'the agent never saw a load or resume for the live session');
    a.close();
  } finally {
    await gw.stop();
  }
});
