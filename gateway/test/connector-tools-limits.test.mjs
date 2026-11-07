// Connector tool limits on the wire (C6, D-096): maxConcurrentTurns across sessions, one running turn
// per session, and maxResultChars on a reply. Not run in task D2 (written only): the coordinator runs
// it in the final check.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { rpc, startGateway, useProject } from './helpers.mjs';
import { PUBLIC_ORIGIN, freePort, phone, grantToken, callTool } from './connector-helpers.mjs';

/** A gateway with the connector on and the given connector block. */
async function start(limits = {}) {
  const port = await freePort();
  const gw = await startGateway({
    connector: {
      enabled: true, port, publicOrigin: PUBLIC_ORIGIN, allowedOrigins: ['https://claude.ai'], pairingTimeoutSeconds: 3,
      limits: { sendPromptWaitSeconds: 1, ...limits }, // one second, so a running turn answers quickly
    },
  });
  return { ...gw, connectorPort: port, connectorUrl: `http://127.0.0.1:${port}` };
}

async function untilDone(gw, token, turnId) {
  for (let i = 0; i < 30; i++) {
    const res = JSON.parse((await callTool(gw, token, 'get_turn', { turnId })).content[0].text);
    if (res.status === 'done') return res;
  }
  throw new Error('the turn never finished');
}

test('maxConcurrentTurns is 1 across sessions, and one turn runs per session', async () => {
  const gw = await start({ maxConcurrentTurns: 1 });
  const ws = await phone(gw);
  try {
    const a = await useProject(gw, ws);
    const second = await rpc(ws, 'session/new', { cwd: gw.dirs.project, mcpServers: [] });
    const b = second.result.sessionId;
    const { token } = await grantToken(gw, ws, { projects: [a.project.id] });

    const first = await callTool(gw, token, 'send_prompt', { sessionId: a.sessionId, text: '[chunks:3][slow:1500] first' });
    assert.equal(first.isError, false);
    const turnId = JSON.parse(first.content[0].text).turnId;
    assert.equal(JSON.parse(first.content[0].text).status, 'running');

    const otherSession = await callTool(gw, token, 'send_prompt', { sessionId: b, text: 'second' });
    assert.equal(otherSession.isError, true);
    assert.match(otherSession.content[0].text, /maxConcurrentTurns is 1/);

    const sameSession = await callTool(gw, token, 'send_prompt', { sessionId: a.sessionId, text: 'third' });
    assert.equal(sameSession.isError, true);
    assert.match(sameSession.content[0].text, /already has a turn running/);

    await untilDone(gw, token, turnId);
    const later = await callTool(gw, token, 'send_prompt', { sessionId: b, text: 'fourth' });
    assert.equal(later.isError, false, 'the slot is free once the turn is done');
    assert.equal(JSON.parse(later.content[0].text).status, 'done');
  } finally {
    ws.close();
    await gw.stop();
  }
});

test('a reply over maxResultChars is cut and marked truncated', async () => {
  const gw = await start({ maxResultChars: 1000 });
  const ws = await phone(gw);
  try {
    const { project, sessionId } = await useProject(gw, ws);
    const { token } = await grantToken(gw, ws, { projects: [project.id], sessions: [sessionId] });
    const res = await callTool(gw, token, 'send_prompt', { sessionId, text: 'x'.repeat(1500) });
    assert.equal(res.isError, false);
    const body = JSON.parse(res.content[0].text);
    assert.equal(body.status, 'done');
    assert.equal(body.reply.length, 1000, 'the reply is cut to maxResultChars');
    assert.equal(body.truncated, true);
  } finally {
    ws.close();
    await gw.stop();
  }
});
