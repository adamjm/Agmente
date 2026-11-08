// Connector tools on the wire (C7, D-096): list_projects, list_sessions, get_context, send_prompt and
// get_turn through /mcp with a real grant, the fake agent behind the gateway, and the audit lines.
// Not run in task D2 (written only): the coordinator runs it in the final check.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdir } from 'node:fs/promises';
import { join } from 'node:path';
import { FAKE_AGENT, rpc, startGateway, useProject } from './helpers.mjs';
import { PUBLIC_ORIGIN, freePort, phone, grantToken, callTool } from './connector-helpers.mjs';

const SECRET = 'SECRET-D2-PROMPT-7731';
const usageAgent = { command: [process.execPath, FAKE_AGENT], envPassthrough: ['PATH', 'ACPCODE_TEST_USAGE'] };
const usageEnv = { ACPCODE_TEST_USAGE: JSON.stringify([{ used: 1200, size: 200000, cost: { amount: 0.42, currency: 'USD' } }]) };

/** A gateway with the connector on. `agent` and `env` let a test report usage from the fake agent. */
async function start({ connector = {}, limits = {}, agent, env = {} } = {}) {
  const port = await freePort();
  const block = {
    enabled: true, port, publicOrigin: PUBLIC_ORIGIN, allowedOrigins: ['https://claude.ai'], pairingTimeoutSeconds: 3,
    ...connector,
    limits: { sendPromptWaitSeconds: 1, ...limits }, // one second, so a running turn answers quickly
  };
  const overrides = { connector: block };
  if (agent) overrides.agent = agent;
  const gw = await startGateway(overrides, { env });
  return { ...gw, connectorPort: port, connectorUrl: `http://127.0.0.1:${port}` };
}

/** The tool's JSON text, parsed. A tool error fails the test with its text. */
function ok(result) {
  assert.equal(result.isError, false, `tool error: ${result.content[0].text}`);
  return JSON.parse(result.content[0].text);
}

/** Poll get_turn until the turn is done (each call waits up to the send wait). */
async function untilDone(gw, token, turnId) {
  for (let i = 0; i < 30; i++) {
    const res = ok(await callTool(gw, token, 'get_turn', { turnId }));
    if (res.status === 'done') return res;
  }
  throw new Error('the turn never finished');
}

test('list_projects and list_sessions show what the grant reaches, with the usage Bob reported', async () => {
  const gw = await start({ agent: usageAgent, env: usageEnv });
  const ws = await phone(gw);
  try {
    const inside = await useProject(gw, ws, gw.dirs.project);
    const otherDir = join(gw.dirs.root, 'other');
    await mkdir(otherDir, { recursive: true });
    const outside = await useProject(gw, ws, otherDir);
    const { token } = await grantToken(gw, ws, { projects: [inside.project.id] });

    const projects = ok(await callTool(gw, token, 'list_projects', {}));
    assert.equal(projects.projects.length, 1, 'only the granted project');
    assert.equal(projects.projects[0].projectId, inside.project.id);
    assert.equal(projects.projects[0].folder, 'project', 'the folder basename, not the path');
    assert.equal(JSON.stringify(projects).includes(gw.dirs.base), false, 'no full path in the answer');

    // One turn so Bob reports usage for the session (the fake agent sends it after each reply).
    const sent = ok(await callTool(gw, token, 'send_prompt', { sessionId: inside.sessionId, text: 'hello usage' }));
    assert.equal(sent.status, 'done');

    const listed = ok(await callTool(gw, token, 'list_sessions', { projectId: inside.project.id }));
    const row = listed.sessions.find((s) => s.sessionId === inside.sessionId);
    assert.ok(row, 'the granted session is listed');
    assert.equal(row.usage.used, 1200);
    assert.equal(row.usage.size, 200000);
    assert.equal(row.usage.costAmount, 0.42);
    assert.equal(row.usage.costCurrency, 'USD');
    assert.match(row.usage.updatedAt, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/);

    const denied = await callTool(gw, token, 'list_sessions', { projectId: outside.project.id });
    assert.equal(denied.isError, true);
    assert.match(denied.content[0].text, /not in this grant's scope/);
  } finally {
    ws.close();
    await gw.stop();
  }
});

test('get_context gives the lean summary: names, status, usage, stop reason, alwaysAllow, and no prompt text', async () => {
  const gw = await start({ agent: usageAgent, env: usageEnv });
  const ws = await phone(gw);
  try {
    const { project, sessionId } = await useProject(gw, ws);
    const { token } = await grantToken(gw, ws, { projects: [project.id], sessions: [sessionId] });
    // The fake agent titles a session with the first 50 characters of its first prompt, and a title is
    // allowed in the summary. The secret sits after those 50, so the summary must not carry it.
    ok(await callTool(gw, token, 'send_prompt', { sessionId, text: `${'-'.repeat(60)}${SECRET} summary` }));

    const text = (await callTool(gw, token, 'get_context', { sessionId })).content[0].text;
    assert.ok(text.length <= 1000, `summary is ${text.length} characters`);
    assert.equal(text.includes(SECRET), false, 'no prompt text beyond the title in the summary');
    const s = JSON.parse(text);
    assert.equal(s.project.folder, 'project');
    assert.equal(s.project.name, 'test');
    assert.equal(s.status, 'idle');
    assert.equal(s.stopReason, 'end_turn');
    assert.deepEqual(s.runningTools, []);
    assert.equal(s.pendingApprovals, 0);
    assert.equal(s.usage.used, 1200);
    assert.equal(s.usage.size, 200000);
    assert.equal(s.usage.percent, 1);
    assert.equal(s.usage.left, 198800);
    assert.equal(s.alwaysAllow, false, 'useProject sent an empty mcpServers list, so no alwaysAllow entry');
  } finally {
    ws.close();
    await gw.stop();
  }
});

test('get_context names the usage as not reported when Bob sent none', async () => {
  const gw = await start();
  const ws = await phone(gw);
  try {
    const { project, sessionId } = await useProject(gw, ws);
    const { token } = await grantToken(gw, ws, { projects: [project.id], sessions: [sessionId] });
    const s = JSON.parse((await callTool(gw, token, 'get_context', { sessionId })).content[0].text);
    assert.equal(s.usage, 'not reported by Bob');
  } finally {
    ws.close();
    await gw.stop();
  }
});

test('send_prompt answers done with the reply, the stop reason and the context; the audit names the source, never the text', async () => {
  const gw = await start();
  const ws = await phone(gw);
  try {
    const { project, sessionId } = await useProject(gw, ws);
    const { token, grantId } = await grantToken(gw, ws, { projects: [project.id], sessions: [sessionId] });

    const res = ok(await callTool(gw, token, 'send_prompt', { sessionId, text: `${SECRET} hello` }));
    assert.equal(res.status, 'done');
    assert.equal(res.stopReason, 'end_turn');
    assert.equal(res.reply, `echo: ${SECRET} hello`, 'the fake agent echoes the prompt as its reply');
    assert.equal(res.truncated, undefined);
    assert.equal(res.context.sessionId, sessionId);

    const line = await gw.waitForAudit((a) => a.event === 'connector_prompt');
    assert.equal(line.source, 'claude');
    assert.equal(line.grant, grantId);
    const rpcLine = await gw.waitForAudit((a) => a.event === 'rpc' && a.method === 'session/prompt' && a.source === 'claude');
    assert.equal(rpcLine.grant, grantId, 'the turn\'s own lines carry the source and the grant');
    assert.equal(JSON.stringify(gw.audit).includes(SECRET), false, 'the prompt text is never audited');
    assert.equal(JSON.stringify(gw.audit).includes(token), false, 'the token is never audited');

    // The phone's own prompt is not tagged: its audit line has no source.
    await rpc(ws, 'session/prompt', { sessionId, prompt: [{ type: 'text', text: 'phone prompt' }] });
    const phoneLine = await gw.waitForAudit((a) => a.event === 'rpc' && a.method === 'session/prompt' && a.source === undefined);
    assert.equal(phoneLine.grant, undefined);
  } finally {
    ws.close();
    await gw.stop();
  }
});

test('a turn that outlives the wait answers running, and get_turn returns its done shape later', async () => {
  const gw = await start();
  const ws = await phone(gw);
  try {
    const { project, sessionId } = await useProject(gw, ws);
    const { token } = await grantToken(gw, ws, { projects: [project.id], sessions: [sessionId] });

    const first = ok(await callTool(gw, token, 'send_prompt', { sessionId, text: '[chunks:3][slow:1500] slow reply' }));
    assert.equal(first.status, 'running');
    assert.equal(typeof first.turnId, 'string');
    const done = await untilDone(gw, token, first.turnId);
    assert.equal(done.reply, 'echo: [chunks:3][slow:1500] slow reply');
    assert.equal(done.stopReason, 'end_turn');
  } finally {
    ws.close();
    await gw.stop();
  }
});

test('get_context shows a waiting approval and the running tool it belongs to', async () => {
  const gw = await start();
  const ws = await phone(gw);
  try {
    const { project, sessionId } = await useProject(gw, ws);
    const { token } = await grantToken(gw, ws, { projects: [project.id], sessions: [sessionId] });

    // The fake agent sends the tool call, then asks for permission. Nobody answers it here.
    const running = ok(await callTool(gw, token, 'send_prompt', { sessionId, text: '[permission] needs a yes' }));
    assert.equal(running.status, 'running');
    const s = JSON.parse((await callTool(gw, token, 'get_context', { sessionId })).content[0].text);
    assert.equal(s.status, 'awaiting_approval');
    assert.equal(s.pendingApprovals, 1);
    assert.deepEqual(s.runningTools, ['Run echo']);
  } finally {
    ws.close();
    await gw.stop();
  }
});

test('the connector refuses what the grant may not reach, and a turn another grant started', async () => {
  const gw = await start();
  const ws = await phone(gw);
  try {
    const { project, sessionId } = await useProject(gw, ws);
    const other = await rpc(ws, 'session/new', { cwd: gw.dirs.project, mcpServers: [] });
    const elsewhere = other.result.sessionId;
    const a = await grantToken(gw, ws, { projects: [project.id], sessions: [sessionId] });
    const b = await grantToken(gw, ws, { projects: [project.id], sessions: [sessionId] });

    const refused = await callTool(gw, a.token, 'send_prompt', { sessionId: elsewhere, text: 'not for you' });
    assert.equal(refused.isError, true);
    assert.match(refused.content[0].text, /not in this grant's scope/);
    const refusedGet = await callTool(gw, a.token, 'get_context', { sessionId: elsewhere });
    assert.match(refusedGet.content[0].text, /not in this grant's scope/);

    const started = ok(await callTool(gw, a.token, 'send_prompt', { sessionId, text: '[chunks:3][slow:1500] mine' }));
    assert.equal(started.status, 'running');
    const foreign = await callTool(gw, b.token, 'get_turn', { turnId: started.turnId });
    assert.equal(foreign.isError, true, 'another grant cannot read the turn');
    assert.match(foreign.content[0].text, /not a turn of this grant/);
    await untilDone(gw, a.token, started.turnId);

    // Refused prompts reach no agent and write no connector_prompt line.
    await gw.waitForAudit((l) => l.event === 'connector_prompt' && l.grant === a.grantId);
    const prompts = gw.audit.filter((l) => l.event === 'connector_prompt');
    assert.equal(prompts.length, 1, 'only the accepted prompt is audited');
  } finally {
    ws.close();
    await gw.stop();
  }
});
