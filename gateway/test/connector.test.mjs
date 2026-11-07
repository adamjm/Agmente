// Connector wire tests (D-095): routes, OAuth with PKCE, phone pairing, grants, tokens and config.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createConnection } from 'node:net';
import { stat, readFile, mkdir } from 'node:fs/promises';
import { join } from 'node:path';
import { dryRun, makeDirs, rawConfig, rpc, spawnGateway, startGateway, useProject } from './helpers.mjs';
import {
  PUBLIC_ORIGIN, RESOURCE, CLIENT_ID, REDIRECT_URI, freePort, startConnectorGateway, pkce, authorizeQuery,
  openAuthorize, redirectOf, exchangeCode, phone, pairOnPhone, grantToken, mcp, call, callTool,
} from './connector-helpers.mjs';

const json = async (url, opts) => {
  const res = await fetch(url, { redirect: 'manual', ...opts });
  return { status: res.status, headers: res.headers, json: await res.json().catch(() => null), text: null };
};

// Routes and the public face of the connector

test('connector serves the protected resource and authorization server metadata', async () => {
  const gw = await startConnectorGateway();
  try {
    const prm = await json(`${gw.connectorUrl}/.well-known/oauth-protected-resource`);
    assert.equal(prm.status, 200);
    assert.equal(prm.json.resource, RESOURCE);
    assert.deepEqual(prm.json.authorization_servers, [PUBLIC_ORIGIN]);
    assert.deepEqual(prm.json.bearer_methods_supported, ['header']);

    const as = await json(`${gw.connectorUrl}/.well-known/oauth-authorization-server`);
    assert.equal(as.status, 200);
    assert.equal(as.json.issuer, PUBLIC_ORIGIN);
    assert.equal(as.json.authorization_endpoint, `${PUBLIC_ORIGIN}/authorize`);
    assert.equal(as.json.token_endpoint, `${PUBLIC_ORIGIN}/token`);
    assert.deepEqual(as.json.code_challenge_methods_supported, ['S256']);
    assert.equal(as.json.registration_endpoint, undefined, 'no dynamic registration (D-095)');
    assert.equal(as.json.client_id_metadata_document_supported, undefined, 'no client ID metadata documents (D-095)');
  } finally {
    await gw.stop();
  }
});

test('connector answers 404 on every path it does not serve, and 405 on the wrong method', async () => {
  const gw = await startConnectorGateway();
  try {
    for (const [method, path] of [
      ['GET', '/'],
      ['GET', '/healthz'],
      ['GET', '/register'],
      ['POST', '/register'],
      ['GET', '/.well-known/openid-configuration'],
      ['GET', '/mcp/'],
      ['GET', '/authorize/extra'],
      ['GET', '/files/anything'],
    ]) {
      const res = await fetch(`${gw.connectorUrl}${path}`, { method, redirect: 'manual' });
      assert.equal(res.status, 404, `${method} ${path}`);
    }
    const getMcp = await fetch(`${gw.connectorUrl}/mcp`, { method: 'GET', redirect: 'manual' });
    assert.equal(getMcp.status, 405, 'GET /mcp: no SSE stream is offered');
    assert.equal(getMcp.headers.get('allow'), 'POST');
    const getToken = await fetch(`${gw.connectorUrl}/token`, { method: 'GET', redirect: 'manual' });
    assert.equal(getToken.status, 405);
  } finally {
    await gw.stop();
  }
});

test('connector refuses an Origin that is not allowed, and accepts one that is', async () => {
  const gw = await startConnectorGateway();
  try {
    const bad = await fetch(`${gw.connectorUrl}/.well-known/oauth-protected-resource`, { headers: { Origin: 'https://evil.example' } });
    assert.equal(bad.status, 403);
    const good = await fetch(`${gw.connectorUrl}/.well-known/oauth-protected-resource`, { headers: { Origin: 'https://claude.ai' } });
    assert.equal(good.status, 200);
    const none = await fetch(`${gw.connectorUrl}/.well-known/oauth-protected-resource`);
    assert.equal(none.status, 200, 'a request with no Origin is allowed');
  } finally {
    await gw.stop();
  }
});

test('POST /mcp without a bearer is refused with a resource_metadata challenge', async () => {
  const gw = await startConnectorGateway();
  try {
    const res = await mcp(gw, { jsonrpc: '2.0', id: 1, method: 'initialize', params: {} });
    assert.equal(res.status, 401);
    const challenge = res.headers.get('www-authenticate');
    assert.match(challenge, /^Bearer resource_metadata="https:\/\/connector\.test\.example\/\.well-known\/oauth-protected-resource"$/);

    const wrong = await mcp(gw, { jsonrpc: '2.0', id: 2, method: 'initialize', params: {} }, { token: 'not-a-grant-token-at-all' });
    assert.equal(wrong.status, 401);
    assert.match(wrong.headers.get('www-authenticate'), /error="invalid_token"/);
  } finally {
    await gw.stop();
  }
});

test('the default config (connector off) starts no listener', async () => {
  const port = await freePort();
  // No connector block at all, and a block that says enabled: false with a port set.
  for (const overrides of [{}, { connector: { enabled: false, port } }]) {
    const gw = await startGateway(overrides);
    try {
      await assert.rejects(tryConnect(port), /ECONNREFUSED/);
    } finally {
      await gw.stop();
    }
  }
});

// Pairing and tokens

test('a pairing approved on the phone issues a usable token, and the audit never holds it', async () => {
  const gw = await startConnectorGateway();
  const ws = await phone(gw);
  try {
    const { verifier, page, answer, row } = await pairOnPhone(gw, { ws, scope: { projects: 'all' } });
    assert.match(page.code, /^\d{6}$/);
    assert.equal(row.clientName, CLIENT_ID.slice(0, 120));
    assert.equal(answer.result.grantId.length > 0, true);

    const redirect = redirectOf(await page.finished);
    assert.equal(redirect.origin + redirect.pathname, REDIRECT_URI);
    assert.equal(redirect.searchParams.get('state'), 'st-123');
    const code = redirect.searchParams.get('code');
    assert.ok(code && code.length >= 32);

    const token = await exchangeCode(gw.connectorPort, { code, verifier });
    assert.equal(token.status, 200);
    assert.equal(token.json.token_type, 'Bearer');
    assert.equal(token.headers.get('cache-control'), 'no-store');
    const bearer = token.json.access_token;

    // With a grant in place, a token that is not that grant's is still refused.
    const forged = await mcp(gw, { jsonrpc: '2.0', id: 3, method: 'ping', params: {} }, { token: 'forged-token-that-matches-no-grant' });
    assert.equal(forged.status, 401, 'a wrong token is refused while a grant exists');
    assert.match(forged.headers.get('www-authenticate'), /error="invalid_token"/);

    const init = await call(gw, bearer, 'initialize', { protocolVersion: '2025-11-25', capabilities: {}, clientInfo: { name: 't', version: '1' } });
    assert.equal(init.status, 200);
    assert.equal(init.json.result.protocolVersion, '2025-11-25');
    assert.equal(init.json.result.serverInfo.name, 'agmente-connector');

    const tools = await call(gw, bearer, 'tools/list', {});
    assert.deepEqual(tools.json.result.tools.map((t) => t.name).sort(), ['get_context', 'get_turn', 'list_projects', 'list_sessions', 'send_prompt']);

    // A code is single use.
    const again = await exchangeCode(gw.connectorPort, { code, verifier });
    assert.equal(again.status, 400);
    assert.equal(again.json.error, 'invalid_grant');

    // Nothing the connector logged holds the code or the token.
    const logged = JSON.stringify(gw.audit);
    assert.equal(logged.includes(bearer), false, 'token must not be logged');
    assert.equal(logged.includes(code), false, 'code must not be logged');
    assert.ok(gw.audit.some((a) => a.event === 'connector_token'));
  } finally {
    ws.close();
    await gw.stop();
  }
});

test('a denied pairing redirects with access_denied and issues no code', async () => {
  const gw = await startConnectorGateway();
  const ws = await phone(gw);
  try {
    const { page, answer } = await pairOnPhone(gw, { ws, decide: 'deny' });
    assert.deepEqual(answer.result, {});
    const redirect = redirectOf(await page.finished);
    assert.equal(redirect.searchParams.get('error'), 'access_denied');
    assert.equal(redirect.searchParams.get('code'), null);
    assert.equal(redirect.searchParams.get('state'), 'st-123');
    const pending = await rpc(ws, '_agmente/connector/pending', {});
    assert.deepEqual(pending.result.pairings, []);
    const grants = await rpc(ws, '_agmente/connector/grants', {});
    assert.deepEqual(grants.result.grants, [], 'a denied pairing makes no grant');
  } finally {
    ws.close();
    await gw.stop();
  }
});

test('a pairing the phone never answers times out as denied', async () => {
  const gw = await startConnectorGateway({ connector: { pairingTimeoutSeconds: 1 } });
  const ws = await phone(gw);
  try {
    const { challenge } = pkce();
    const held = await openAuthorize(gw.connectorPort, authorizeQuery({ challenge }));
    assert.match(held.code, /^\d{6}$/);
    const started = Date.now();
    const redirect = redirectOf(await held.finished);
    assert.equal(redirect.searchParams.get('error'), 'access_denied');
    assert.equal(redirect.searchParams.get('code'), null);
    assert.ok(Date.now() - started < 10_000, 'the page ends at the timeout');
    const pending = await rpc(ws, '_agmente/connector/pending', {});
    assert.deepEqual(pending.result.pairings, []);
    const late = await rpc(ws, '_agmente/connector/approve', { pairingId: 'expired', scope: { projects: 'all' } });
    assert.equal(late.error.code, -32602, 'an answer after the timeout is refused');
  } finally {
    ws.close();
    await gw.stop();
  }
});

test('an unknown pairing id is refused by the phone', async () => {
  const gw = await startConnectorGateway();
  const ws = await phone(gw);
  try {
    const res = await rpc(ws, '_agmente/connector/approve', { pairingId: 'nope', scope: { projects: 'all' } });
    assert.equal(res.error.code, -32602);
    const deny = await rpc(ws, '_agmente/connector/deny', { pairingId: 'nope' });
    assert.equal(deny.error.code, -32602);
  } finally {
    ws.close();
    await gw.stop();
  }
});

test('PKCE is enforced: a wrong verifier, a wrong redirect or a plain method is refused', async () => {
  const gw = await startConnectorGateway();
  const ws = await phone(gw);
  try {
    // plain is refused before any pairing opens
    const { challenge } = pkce();
    const plain = await openAuthorize(gw.connectorPort, authorizeQuery({ challenge, method: 'plain' }));
    assert.equal(plain.status, 400);
    assert.equal(plain.code, null);

    // a wrong verifier
    const { verifier, page } = await pairOnPhone(gw, { ws });
    const code = redirectOf(await page.finished).searchParams.get('code');
    const wrong = await exchangeCode(gw.connectorPort, { code, verifier: 'x'.repeat(50) });
    assert.equal(wrong.status, 400);
    assert.equal(wrong.json.error, 'invalid_grant');

    // the wrong redirect uri on a fresh code
    const second = await pairOnPhone(gw, { ws });
    const code2 = redirectOf(await second.page.finished).searchParams.get('code');
    const badRedirect = await exchangeCode(gw.connectorPort, { code: code2, verifier: second.verifier, redirectUri: 'https://other.example/cb' });
    assert.equal(badRedirect.json.error, 'invalid_grant');
  } finally {
    ws.close();
    await gw.stop();
  }
});

test('resource indicators are required to name the MCP server', async () => {
  const gw = await startConnectorGateway();
  try {
    const { challenge } = pkce();
    const wrong = await openAuthorize(gw.connectorPort, authorizeQuery({ challenge, resource: 'https://elsewhere.example/mcp' }));
    assert.equal(wrong.status, 400);
    const { verifier } = pkce();
    const tokenWrong = await exchangeCode(gw.connectorPort, { code: 'abc', verifier, resource: 'https://elsewhere.example/mcp' });
    assert.equal(tokenWrong.json.error, 'invalid_target');
  } finally {
    await gw.stop();
  }
});

test('a redirect URI that is neither https nor loopback is refused before a pairing opens', async () => {
  const gw = await startConnectorGateway();
  try {
    const { challenge } = pkce();
    const page = await openAuthorize(gw.connectorPort, authorizeQuery({ challenge, redirectUri: 'http://claude.example/cb' }));
    assert.equal(page.status, 400);
    const loop = await openAuthorize(gw.connectorPort, authorizeQuery({ challenge, redirectUri: 'http://127.0.0.1:9999/cb' }));
    assert.ok(loop.code, 'loopback http is allowed');
    loop.close();
  } finally {
    await gw.stop();
  }
});

test('revoke stops a token working at once', async () => {
  const gw = await startConnectorGateway();
  const ws = await phone(gw);
  try {
    const { token, grantId } = await grantToken(gw, ws, { projects: 'all' });
    const before = await call(gw, token, 'ping', {});
    assert.equal(before.status, 200);
    const grants = await rpc(ws, '_agmente/connector/grants', {});
    const row = grants.result.grants.find((g) => g.grantId === grantId);
    assert.equal(row.label, CLIENT_ID.slice(0, 120));
    assert.deepEqual(row.scope, { projects: 'all' });
    assert.equal(JSON.stringify(grants).includes(token), false, 'the grant list never holds a token');

    const revoked = await rpc(ws, '_agmente/connector/revoke', { grantId });
    assert.deepEqual(revoked.result, {});
    const after = await call(gw, token, 'ping', {});
    assert.equal(after.status, 401);
    assert.match(after.headers.get('www-authenticate'), /invalid_token/);
    const again = await rpc(ws, '_agmente/connector/revoke', { grantId });
    assert.equal(again.error.code, -32602);
  } finally {
    ws.close();
    await gw.stop();
  }
});

test('grants and their token hashes survive a restart, and the file is mode 0600', async () => {
  const dirs = await makeDirs();
  const connectorPort = await freePort();
  const config = rawConfig(dirs.root, {
    connector: { enabled: true, port: connectorPort, publicOrigin: PUBLIC_ORIGIN, pairingTimeoutSeconds: 3 },
  });
  const first = await spawnGateway(config, { configDir: dirs.base });
  const gwFirst = { ...first, connectorPort, connectorUrl: `http://127.0.0.1:${connectorPort}` };
  const ws = await phone(gwFirst);
  const { token } = await grantToken(gwFirst, ws, { projects: 'all' });
  ws.close();
  const file = join(dirs.base, 'state', 'connector-grants.json');
  const mode = (await stat(file)).mode & 0o777;
  assert.equal(mode, 0o600);
  const onDisk = await readFile(file, 'utf8');
  assert.equal(onDisk.includes(token), false, 'the file holds the hash, never the token');
  assert.match(onDisk, /"tokenSha256": "[0-9a-f]{64}"/);
  await first.stop(); // the process only: the state directory stays

  const second = await spawnGateway(config, { configDir: dirs.base });
  const gwSecond = { ...second, connectorPort, connectorUrl: `http://127.0.0.1:${connectorPort}` };
  try {
    const res = await call(gwSecond, token, 'ping', {});
    assert.equal(res.status, 200, 'the token still works after a restart');
  } finally {
    await second.stop();
    await dirs.cleanup();
  }
});

// Scope

test('a grant outside its scope is refused by the tools, and a grant with no scope for a project is refused too', async () => {
  const gw = await startConnectorGateway();
  const ws = await phone(gw);
  try {
    const inside = await useProject(gw, ws, gw.dirs.project);
    const otherDir = join(gw.dirs.root, 'other');
    await mkdir(otherDir, { recursive: true });
    const outside = await useProject(gw, ws, otherDir);

    const { token } = await grantToken(gw, ws, { projects: [inside.project.id] });

    const outsideList = await callTool(gw, token, 'list_sessions', { projectId: outside.project.id });
    assert.equal(outsideList.isError, true);
    assert.match(outsideList.content[0].text, /not in this grant's scope/);

    const insideList = await callTool(gw, token, 'list_sessions', { projectId: inside.project.id });
    assert.equal(insideList.isError, true);
    assert.match(insideList.content[0].text, /not implemented/, 'an in-scope call passes the gate');

    const foreignSession = await callTool(gw, token, 'get_context', { sessionId: outside.sessionId });
    assert.equal(foreignSession.isError, true);
    assert.match(foreignSession.content[0].text, /not in this grant's scope/);

    const unknown = await callTool(gw, token, 'get_context', { sessionId: 'no-such-session' });
    assert.match(unknown.content[0].text, /not in this grant's scope/, 'an unknown session looks like an out-of-scope one');
  } finally {
    ws.close();
    await gw.stop();
  }
});

test('the phone refuses a scope that names an unknown project or a session outside its projects', async () => {
  const gw = await startConnectorGateway();
  const ws = await phone(gw);
  try {
    const a = await useProject(gw, ws, gw.dirs.project);
    const otherDir = join(gw.dirs.root, 'second');
    await mkdir(otherDir, { recursive: true });
    const b = await useProject(gw, ws, otherDir);

    const held = await pairOnPhone(gw, { ws, scope: { projects: ['no-such-project'] } });
    assert.equal(held.answer.error.code, -32602, 'an unknown project is refused');
    const pending = await rpc(ws, '_agmente/connector/pending', {});
    assert.equal(pending.result.pairings.length, 1, 'a refused approve leaves the pairing open');
    const pairingId = pending.result.pairings[0].pairingId;

    const crossed = await rpc(ws, '_agmente/connector/approve', { pairingId, scope: { projects: [a.project.id], sessions: [b.sessionId] } });
    assert.equal(crossed.error.code, -32602, 'a session outside the listed projects is refused');
    const empty = await rpc(ws, '_agmente/connector/approve', { pairingId, scope: { projects: [] } });
    assert.equal(empty.error.code, -32602);
    const ok = await rpc(ws, '_agmente/connector/approve', { pairingId, scope: { projects: [a.project.id], sessions: [a.sessionId] } });
    assert.equal(typeof ok.result.grantId, 'string');
    const page = await held.page.finished;
    assert.match(page.body, /location\.replace/, 'the held page finishes when the approve succeeds');
  } finally {
    ws.close();
    await gw.stop();
  }
});

// Config

test('a bad connector limit fails --dry-run with the key named', async () => {
  const dirs = await makeDirs();
  const good = rawConfig(dirs.root, { connector: { enabled: true, port: 8789, publicOrigin: PUBLIC_ORIGIN } });
  const ok = await dryRun(good);
  assert.equal(ok.status, 0, ok.stderr);

  const bad = await dryRun({ ...good, connector: { ...good.connector, limits: { promptsPerHour: 0 } } });
  assert.equal(bad.status, 1);
  assert.match(bad.stderr, /connector\.limits\.promptsPerHour must be an integer from 1 to 1000/);

  const tooBig = await dryRun({ ...good, connector: { ...good.connector, limits: { maxPromptBytes: 10_000_000 } } });
  assert.equal(tooBig.status, 1);
  assert.match(tooBig.stderr, /connector\.limits\.maxPromptBytes/);

  const unknown = await dryRun({ ...good, connector: { ...good.connector, limits: { promptsPerDay: 5 } } });
  assert.match(unknown.stderr, /connector\.limits\.promptsPerDay is not a known limit/);

  const noOrigin = await dryRun({ ...good, connector: { enabled: true, port: 8789 } });
  assert.equal(noOrigin.status, 1);
  assert.match(noOrigin.stderr, /connector\.publicOrigin must be set when connector\.enabled is true/);

  const badOrigin = await dryRun({ ...good, connector: { ...good.connector, publicOrigin: 'https://x.example/path' } });
  assert.match(badOrigin.stderr, /connector\.publicOrigin must be an https origin/);

  const badPort = await dryRun({ ...good, connector: { ...good.connector, port: 70000 } });
  assert.match(badPort.stderr, /connector\.port must be an integer from 1 to 65535/);

  await dirs.cleanup();
});

// helpers local to this file

function tryConnect(port) {
  return new Promise((resolve, reject) => {
    const sock = createConnection({ host: '127.0.0.1', port }, () => { sock.end(); resolve(); });
    sock.once('error', reject);
  });
}
