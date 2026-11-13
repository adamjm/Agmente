// The default working directory, working_dir (gateway internal/server/working_dir.go). The gateway makes
// <stateDir>/working_dir at start, mode 0700, and lists it as the project "working_dir". No request
// removes it or makes a folder over it.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { statSync } from 'node:fs';
import { realpath } from 'node:fs/promises';
import { join } from 'node:path';
import { auth, connect, makeDirs, rawConfig, rpc, spawnGateway, startGateway, WORKING_DIR_NAME } from './helpers.mjs';

const workingDirOf = (gw) => join(gw.config.stateDir, WORKING_DIR_NAME);
const listed = async (ws) => (await rpc(ws, '_acpcode/projects/list', {})).result.projects.filter((p) => p.name === WORKING_DIR_NAME);

test('the gateway makes working_dir in its state folder at mode 0700 and lists it as a project', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    const dir = workingDirOf(gw);
    assert.equal(statSync(dir).mode & 0o777, 0o700);
    const found = await listed(ws);
    assert.equal(found.length, 1);
    assert.equal(found[0].path, await realpath(dir));
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('working_dir cannot be registered over, made under, or deleted by a request', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    const dir = await realpath(workingDirOf(gw));
    const stateDir = await realpath(gw.config.stateDir);
    const [{ id }] = await listed(ws);

    const again = await rpc(ws, '_acpcode/projects/create', { name: 'again', path: dir });
    assert.equal(again.error?.code, -32602, 'the same folder cannot be registered twice');

    const under = await rpc(ws, '_acpcode/projects/create', { name: 'sub', path: dir, createFolder: true });
    assert.equal(under.error?.code, -32602, 'no folder is made inside working_dir');

    const inState = await rpc(ws, '_acpcode/projects/create', { name: 'sub', path: stateDir, createFolder: true });
    assert.equal(inState.error?.code, -32602, 'no folder is made in the state folder');

    const deleted = await rpc(ws, '_acpcode/projects/delete', { projectId: id });
    assert.equal(deleted.error?.code, -32601, 'there is no delete method');

    assert.equal((await listed(ws)).length, 1, 'the refused requests changed nothing');
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('a session may start in working_dir', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    const res = await rpc(ws, 'session/new', { cwd: await realpath(workingDirOf(gw)), mcpServers: [] });
    assert.ok(res.result?.sessionId, `session/new in working_dir failed: ${JSON.stringify(res.error)}`);
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('a restart keeps one working_dir project', async () => {
  const dirs = await makeDirs();
  const config = rawConfig(dirs.root);
  try {
    let gw = await spawnGateway(config, { configDir: dirs.base });
    await gw.stop();
    gw = await spawnGateway(config, { configDir: dirs.base });
    try {
      const { ws } = await connect(gw.url, auth());
      assert.equal((await listed(ws)).length, 1);
      ws.close();
    } finally {
      await gw.stop();
    }
  } finally {
    await dirs.cleanup();
  }
});
