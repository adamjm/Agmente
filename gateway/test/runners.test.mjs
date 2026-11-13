// Several agents on one gateway (multi-runner): the gateway lists them, a project names its runner at
// creation, and the project's agent is the runner it names. The fake agent reports its argv
// (`_test/argv`), so each runner's own flag shows which agent ran.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { auth, connect, FAKE_AGENT, rpc, startGateway, useProject } from './helpers.mjs';

const runners = {
  alpha: { command: [process.execPath, FAKE_AGENT, '--runner', 'alpha'], envPassthrough: ['PATH'] },
  beta: { name: 'Beta agent', command: [process.execPath, FAKE_AGENT, '--runner', 'beta'], envPassthrough: ['PATH'] },
};

test('initialize lists the runners and the default, and a project names its runner', async () => {
  const gw = await startGateway({ agent: undefined, runners, defaultRunner: 'alpha' });
  try {
    const { ws } = await connect(gw.url, auth());
    const init = await rpc(ws, 'initialize', { protocolVersion: 1, clientCapabilities: {} });
    const info = init.result._meta['acpcode/gateway'];
    assert.deepEqual(info.runners, [{ id: 'alpha', name: 'alpha' }, { id: 'beta', name: 'Beta agent' }]);
    assert.equal(info.defaultRunner, 'alpha');

    const alphaPath = gw.dirs.project;
    const betaPath = join(gw.dirs.root, 'beta-project');
    mkdirSync(betaPath);
    const noRunner = await rpc(ws, '_acpcode/projects/create', { name: 'alpha-proj', path: alphaPath });
    assert.equal(noRunner.result.project.runner, 'alpha', 'no runner named: the default');
    const beta = await rpc(ws, '_acpcode/projects/create', { name: 'beta-proj', path: betaPath, runner: 'beta' });
    assert.equal(beta.result.project.runner, 'beta');

    const refused = await rpc(ws, '_acpcode/projects/create', { name: 'gamma', path: join(gw.dirs.root, 'gamma'), runner: 'gamma' });
    assert.equal(refused.error?.code, -32602, 'an unknown runner is refused, never replaced by the default');

    const list = await rpc(ws, '_acpcode/projects/list', {});
    const byName = Object.fromEntries(list.result.projects.map((p) => [p.name, p.runner]));
    assert.deepEqual(byName, { 'alpha-proj': 'alpha', 'beta-proj': 'beta' });
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('each project runs the agent of its own runner, side by side', async () => {
  const gw = await startGateway({ agent: undefined, runners, defaultRunner: 'alpha' });
  try {
    const { ws } = await connect(gw.url, auth());
    const betaPath = join(gw.dirs.root, 'beta-project');
    mkdirSync(betaPath);
    await rpc(ws, '_acpcode/projects/create', { name: 'beta-proj', path: betaPath, runner: 'beta' });
    await useProject(gw, ws); // the default runner, alpha
    const beta = await rpc(ws, 'session/new', { cwd: betaPath, mcpServers: [] });
    assert.ok(beta.result?.sessionId, `session/new in the beta project: ${JSON.stringify(beta.error)}`);

    const alphaArgv = (await rpc(ws, '_test/argv', { cwd: gw.dirs.project })).result.args;
    const betaArgv = (await rpc(ws, '_test/argv', { cwd: betaPath })).result.args;
    assert.deepEqual(alphaArgv.slice(-2), ['--runner', 'alpha'], `alpha project's agent argv: ${alphaArgv}`);
    assert.deepEqual(betaArgv.slice(-2), ['--runner', 'beta'], `beta project's agent argv: ${betaArgv}`);
    ws.close();
  } finally {
    await gw.stop();
  }
});
