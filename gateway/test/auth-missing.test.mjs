// T-35 (SPEC 7, FR-35): when the agent refuses session/new with -32000 "Authentication required",
// the phone gets the same code and message, and no session is created. The agent is an inline
// script written into the test's temp folder and run as a file (not `node -e`). It answers
// initialize, and refuses every session/new. It logs each session/new, so the test can show the
// request reached the agent.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { auth, connect, rpc, startGateway } from './helpers.mjs';

const AUTH_AGENT = `// Inline test agent for T-35: answers initialize, refuses session/new with -32000 "Authentication required".
// argv[2] is a log file; each session/new is appended to it as one line before the refusal is sent.
import { appendFileSync } from 'node:fs';
import { createInterface } from 'node:readline';

const logFile = process.argv[2];
const send = (obj) => process.stdout.write(\`\${JSON.stringify(obj)}\\n\`);

createInterface({ input: process.stdin }).on('line', (line) => {
  let msg;
  try {
    msg = JSON.parse(line);
  } catch {
    return;
  }
  if (msg.method === 'initialize') {
    send({ jsonrpc: '2.0', id: msg.id, result: { protocolVersion: 1, agentCapabilities: {}, authMethods: [] } });
    return;
  }
  if (msg.method === 'session/new') {
    appendFileSync(logFile, 'session/new\\n');
    send({ jsonrpc: '2.0', id: msg.id, error: { code: -32000, message: 'Authentication required' } });
    return;
  }
  if (msg.id !== undefined && msg.method) send({ jsonrpc: '2.0', id: msg.id, error: { code: -32601, message: 'Method not found' } });
});
`;

test('T-35: session/new refused with -32000 "Authentication required" reaches the phone unchanged, and no session is created', async () => {
  const gw = await startGateway({}, {
    configFn: (dirs, config) => {
      const script = join(dirs.base, 'auth-agent.mjs');
      writeFileSync(script, AUTH_AGENT);
      config.agent = { command: [process.execPath, script, join(dirs.base, 'agent.log')], envPassthrough: ['PATH'] };
    },
  });
  try {
    const ws = (await connect(gw.url, auth())).ws;
    const created = await rpc(ws, '_agmente/projects/create', { name: 'auth', path: gw.dirs.project });
    assert.ok(created.result?.project, `project not created: ${JSON.stringify(created)}`);

    const res = await rpc(ws, 'session/new', { cwd: gw.dirs.project, mcpServers: [] });
    assert.equal(res.result, undefined, `session/new must not succeed: ${JSON.stringify(res)}`);
    assert.ok(res.error, 'the phone gets a JSON-RPC error');
    assert.equal(res.error.code, -32000, 'the error code is the agent\'s, unchanged');
    assert.equal(res.error.message, 'Authentication required', 'the error message is the agent\'s, unchanged');
    assert.equal(res.result?.sessionId, undefined, 'no session id is returned');

    // The agent appends to its log before it refuses, so the line is already there.
    const logPath = join(gw.dirs.base, 'agent.log');
    const log = existsSync(logPath) ? readFileSync(logPath, 'utf8') : '';
    assert.equal(log, 'session/new\n', 'the agent received exactly one session/new');

    // No session was recorded either.
    const index = await rpc(ws, '_agmente/sessions/index', {});
    assert.deepEqual(index.result?.sessions, [], 'the refused session is not in the session index');
    ws.close();
  } finally {
    await gw.stop();
  }
});
