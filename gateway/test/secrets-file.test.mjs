// Agent secrets file over the wire: PLAN 4.2, FR-32, F-14, D-079 (names only, never argv).
// The values here are synthetic test strings. The repository's real BOB_API_KEY is never read.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { chmod, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { auth, connect, dryRun, FAKE_AGENT, makeDirs, rawConfig, rpc, spawnGateway, useProject } from './helpers.mjs';

const fresh = (label) => `${label}-${randomBytes(12).toString('hex')}`;

async function secretsConfig(dirs, mode) {
  const value = fresh('wire-secret');
  const decoy = fresh('gateway-decoy');
  const file = join(dirs.base, 'agent.env');
  await writeFile(file, `# Bob key for the test\nBOB_API_KEY=${value}\n\nNOT_LISTED=${fresh('unlisted')}\n`);
  await chmod(file, mode);
  const config = rawConfig(dirs.root, {
    agent: {
      command: [process.execPath, FAKE_AGENT, '--accept-license', '--log-level', 'warn'],
      envPassthrough: ['PATH', 'BOB_API_KEY'],
      secretsFile: file,
    },
  });
  return { config, value, decoy, file };
}

test('the agent sees BOB_API_KEY from the file; the value is not in argv, ps or the audit log', async () => {
  const dirs = await makeDirs();
  const { config, value, decoy } = await secretsConfig(dirs, 0o600);
  const gw = await spawnGateway(config, {
    replaceEnv: true,
    env: { PATH: process.env.PATH, HOME: dirs.base, BOB_API_KEY: decoy, NOT_LISTED: decoy },
    configDir: dirs.base,
  });
  try {
    const { ws } = await connect(gw.url, auth());
    await useProject(gw, ws, dirs.project);

    const env = await rpc(ws, '_test/getenv', { name: 'BOB_API_KEY' });
    assert.deepEqual(env.result, { present: true, value }, 'the file value reaches the agent, over the gateway env');

    const names = (await rpc(ws, '_test/env', {})).result.names;
    assert.equal(names.includes('NOT_LISTED'), false, 'a name outside envPassthrough is not passed');

    const argv = (await rpc(ws, '_test/argv', {})).result.args;
    assert.deepEqual(argv, ['--accept-license', '--log-level', 'warn']);
    assert.equal(argv.some((a) => a.includes(value)), false, 'the value is not in argv');
    assert.equal(argv.includes('--trust'), false, 'no --trust');

    const start = await gw.waitForAudit((l) => l.event === 'agent_start');
    const psArgs = execFileSync('ps', ['-o', 'command=', '-p', String(start.pid)], { encoding: 'utf8' });
    assert.equal(psArgs.includes(value), false, 'the value is not on the process command line');

    // The gateway logged the ignored name, and no value anywhere.
    const ignored = await gw.waitForAudit((l) => l.event === 'secret_ignored');
    assert.equal(ignored.reason, 'NOT_LISTED');
    const log = JSON.stringify(gw.audit);
    assert.equal(log.includes(value), false, 'the audit log holds no secret value');
    assert.equal(log.includes(decoy), false, 'the audit log holds no gateway-env value either');
    ws.close();
  } finally {
    await gw.stop();
    await dirs.cleanup();
  }
});

test('a secrets file that became unreadable stops the agent start with a generic error', async () => {
  const dirs = await makeDirs();
  const { config, value, file } = await secretsConfig(dirs, 0o600);
  const gw = await spawnGateway(config, { configDir: dirs.base });
  try {
    const { ws } = await connect(gw.url, auth());
    await chmod(file, 0o644);
    const res = await rpc(ws, '_agmente/projects/create', { name: 'p', path: dirs.project });
    assert.ok(res.result?.project, 'the project is registered');
    const started = await rpc(ws, 'session/new', { cwd: dirs.project, mcpServers: [] });
    assert.equal(started.error?.code, -32000);
    assert.equal(started.error.message, 'agent failed to start');
    const failed = await gw.waitForAudit((l) => l.event === 'agent_error');
    assert.equal(failed.reason, 'secrets');
    assert.equal(JSON.stringify(gw.audit).includes(value), false);
    ws.close();
  } finally {
    await gw.stop();
    await dirs.cleanup();
  }
});

test('config refuses a secrets file with group or other access, a relative path and an empty file', async () => {
  const dirs = await makeDirs();
  try {
    const open = await secretsConfig(dirs, 0o644);
    const refused = await dryRun(open.config);
    assert.notEqual(refused.status, 0);
    assert.match(refused.stderr, /group or others/);
    assert.equal(refused.stderr.includes(open.value), false, 'the error does not show the value');

    const relative = rawConfig(dirs.root, { agent: { command: ['bob', 'acp'], envPassthrough: ['PATH'], secretsFile: 'agent.env' } });
    const rel = await dryRun(relative);
    assert.notEqual(rel.status, 0);
    assert.match(rel.stderr, /absolute/);

    const empty = await secretsConfig(dirs, 0o600);
    await writeFile(empty.file, '# nothing here\n');
    const none = await dryRun(empty.config);
    assert.notEqual(none.status, 0);
    assert.match(none.stderr, /no NAME=value entries/);
  } finally {
    await dirs.cleanup();
  }
});
