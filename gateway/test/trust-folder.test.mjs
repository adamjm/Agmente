// Trust folder at registration: PLAN 4.3, F-15, D-013. The gateway writes TRUST_FOLDER for the
// project path into the project home, and never passes --trust to the agent.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { auth, connect, FAKE_AGENT, rawConfig, rpc, spawnGateway, startGateway, makeDirs, useProject } from './helpers.mjs';

test('create writes the project path as TRUST_FOLDER in the project home, with the right modes', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    const { project } = (await rpc(ws, '_acpcode/projects/create', { name: 'trusted', path: gw.dirs.project })).result;
    const home = join(gw.config.stateDir, 'homes', project.id);
    const bob = join(home, '.bob');
    const trust = join(bob, 'trustedFolders.json');
    assert.deepEqual(JSON.parse(readFileSync(trust, 'utf8')), { version: 1, folders: { [gw.dirs.project]: 'TRUST_FOLDER' } });
    assert.equal(statSync(trust).mode & 0o777, 0o600);
    assert.equal(statSync(bob).mode & 0o777, 0o700);
    assert.deepEqual(readdirSync(bob), ['trustedFolders.json'], 'no temporary file is left behind');
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('the agent starts in the project folder, with no --trust, and the trust file is unchanged', async () => {
  const dirs = await makeDirs();
  const config = rawConfig(dirs.root, {
    agent: { command: [process.execPath, FAKE_AGENT, '--accept-license', '--log-level', 'warn'], envPassthrough: ['PATH'] },
  });
  const gw = await spawnGateway(config, { configDir: dirs.base });
  try {
    const { ws } = await connect(gw.url, auth());
    const { project } = await useProject(gw, ws, dirs.project);
    const trust = join(dirs.base, 'state', 'homes', project.id, '.bob', 'trustedFolders.json');
    const before = readFileSync(trust, 'utf8');

    const argv = (await rpc(ws, '_test/argv', {})).result.args;
    assert.equal(argv.includes('--trust'), false, `--trust in argv: ${argv.join(' ')}`);
    assert.equal(argv.some((a) => a.startsWith('--trust')), false);

    const state = (await rpc(ws, '_test/state', {})).result;
    assert.equal(state.cwd, dirs.project, 'the agent works in the project folder');

    assert.equal(readFileSync(trust, 'utf8'), before, 'starting the agent does not rewrite the trust file');
    ws.close();
  } finally {
    await gw.stop();
    await dirs.cleanup();
  }
});
