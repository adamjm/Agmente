// Connector limits on the wire (C6, D-095): promptsPerHour, maxPromptBytes, and the audit never
// holding prompt text. The tools themselves are not implemented in this task (D2), so an allowed
// prompt answers "not implemented" after the gates have run.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { useProject } from './helpers.mjs';
import { startConnectorGateway, phone, grantToken, callTool } from './connector-helpers.mjs';

test('send_prompt is limited to promptsPerHour per grant, and refused after the limit', async () => {
  const gw = await startConnectorGateway({ connector: { limits: { promptsPerHour: 2 } } });
  const ws = await phone(gw);
  try {
    const { project, sessionId } = await useProject(gw, ws);
    const { token } = await grantToken(gw, ws, { projects: [project.id], sessions: [sessionId] });

    const first = await callTool(gw, token, 'send_prompt', { sessionId, text: 'one' });
    assert.equal(first.isError, true);
    assert.match(first.content[0].text, /not implemented/);
    const second = await callTool(gw, token, 'send_prompt', { sessionId, text: 'two' });
    assert.match(second.content[0].text, /not implemented/);
    const third = await callTool(gw, token, 'send_prompt', { sessionId, text: 'three' });
    assert.equal(third.isError, true);
    assert.match(third.content[0].text, /prompt limit reached: 2 prompts per hour/);
  } finally {
    ws.close();
    await gw.stop();
  }
});

test('send_prompt refuses a prompt over maxPromptBytes before it counts against the hour', async () => {
  const gw = await startConnectorGateway({ connector: { limits: { maxPromptBytes: 10, promptsPerHour: 1 } } });
  const ws = await phone(gw);
  try {
    const { project, sessionId } = await useProject(gw, ws);
    const { token } = await grantToken(gw, ws, { projects: [project.id], sessions: [sessionId] });

    const big = await callTool(gw, token, 'send_prompt', { sessionId, text: 'x'.repeat(11) });
    assert.equal(big.isError, true);
    assert.match(big.content[0].text, /larger than 10 bytes/);

    // The refused prompt did not use up the one allowed prompt.
    const small = await callTool(gw, token, 'send_prompt', { sessionId, text: 'x'.repeat(10) });
    assert.match(small.content[0].text, /not implemented/);
  } finally {
    ws.close();
    await gw.stop();
  }
});

test('a prompt outside the grant scope is refused before the limits run', async () => {
  const gw = await startConnectorGateway({ connector: { limits: { promptsPerHour: 1 } } });
  const ws = await phone(gw);
  try {
    const { project, sessionId } = await useProject(gw, ws);
    // A grant on the project with no session list reaches every session in it.
    const grant = await grantToken(gw, ws, { projects: [project.id] });
    const res = await callTool(gw, grant.token, 'send_prompt', { sessionId: 'not-a-session', text: 'hello' });
    assert.match(res.content[0].text, /not in this grant's scope/);
    // The refused prompt did not use the hour's one prompt.
    const ok = await callTool(gw, grant.token, 'send_prompt', { sessionId, text: 'hello' });
    assert.match(ok.content[0].text, /not implemented/);
  } finally {
    ws.close();
    await gw.stop();
  }
});

test('the audit records the tool call and never the prompt text', async () => {
  const gw = await startConnectorGateway();
  const ws = await phone(gw);
  try {
    const { project, sessionId } = await useProject(gw, ws);
    const { token, grantId } = await grantToken(gw, ws, { projects: [project.id], sessions: [sessionId] });
    await callTool(gw, token, 'send_prompt', { sessionId, text: 'SECRET-PROMPT-TEXT-0042' });
    const logged = JSON.stringify(gw.audit);
    assert.equal(logged.includes('SECRET-PROMPT-TEXT-0042'), false, 'prompt text must not be audited');
    assert.equal(logged.includes(token), false, 'the token must not be audited');
    const line = gw.audit.find((a) => a.event === 'connector_mcp' && a.reason?.startsWith('send_prompt'));
    assert.ok(line, 'the tool call is audited');
    assert.ok(line.reason.includes(grantId), 'the audit names the grant');
  } finally {
    ws.close();
    await gw.stop();
  }
});
