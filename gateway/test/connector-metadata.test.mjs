// Connector metadata wire tests (D-101): both protected-resource URLs, the challenge on /mcp, a
// publicOrigin with a port in the resource identifier, the six served routes, and the 404 cases.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { rpc, makeDirs, rawConfig, dryRun } from './helpers.mjs';
import {
  startConnectorGateway, openAuthorize, authorizeQuery, pkce, phone, mcp,
} from './connector-helpers.mjs';

const ORIGIN = 'https://name.example:8443';
const RESOURCE = `${ORIGIN}/mcp`;
const SUFFIXED = `${ORIGIN}/.well-known/oauth-protected-resource/mcp`;
const ROOT = `${ORIGIN}/.well-known/oauth-protected-resource`;

const getJSON = async (url) => {
  const res = await fetch(url, { redirect: 'manual' });
  return { status: res.status, headers: res.headers, text: await res.text() };
};

test('both protected-resource URLs return the same metadata, for the resource with the port', async () => {
  const gw = await startConnectorGateway({ connector: { publicOrigin: ORIGIN } });
  try {
    const root = await getJSON(`${gw.connectorUrl}/.well-known/oauth-protected-resource`);
    const suffixed = await getJSON(`${gw.connectorUrl}/.well-known/oauth-protected-resource/mcp`);
    assert.equal(root.status, 200);
    assert.equal(suffixed.status, 200);
    assert.equal(suffixed.text, root.text, 'the path-suffixed body is the root body');
    assert.deepEqual(JSON.parse(root.text), {
      resource: RESOURCE,
      authorization_servers: [ORIGIN],
      bearer_methods_supported: ['header'],
    });
    assert.match(root.headers.get('content-type'), /application\/json/);
  } finally {
    await gw.stop();
  }
});

test('POST /mcp without a bearer names the path-suffixed metadata in the challenge', async () => {
  const gw = await startConnectorGateway({ connector: { publicOrigin: ORIGIN } });
  try {
    const res = await mcp(gw, { jsonrpc: '2.0', id: 1, method: 'initialize', params: {} });
    assert.equal(res.status, 401);
    assert.equal(res.headers.get('www-authenticate'), `Bearer resource_metadata="${SUFFIXED}"`);

    const wrong = await mcp(gw, { jsonrpc: '2.0', id: 2, method: 'initialize', params: {} }, { token: 'not-a-grant-token-at-all' });
    assert.equal(wrong.status, 401);
    assert.equal(wrong.headers.get('www-authenticate'), `Bearer resource_metadata="${SUFFIXED}", error="invalid_token"`);
  } finally {
    await gw.stop();
  }
});

test('the resource identifier keeps the port: a resource without it is refused, one with it is accepted', async () => {
  const gw = await startConnectorGateway({ connector: { publicOrigin: ORIGIN } });
  try {
    const { challenge } = pkce();
    const noPort = await openAuthorize(gw.connectorPort, authorizeQuery({ challenge, resource: 'https://name.example/mcp' }));
    assert.equal(noPort.status, 400, 'the origin without the port is another resource');
    const withPort = await openAuthorize(gw.connectorPort, authorizeQuery({ challenge, resource: RESOURCE }));
    assert.ok(withPort.code, 'the matching resource opens the pairing page');
    assert.equal(withPort.status, 200);
    withPort.close();
  } finally {
    await gw.stop();
  }
});

test('each of the six served routes answers, and every other path is 404', async () => {
  const gw = await startConnectorGateway({ connector: { publicOrigin: ORIGIN } });
  try {
    const base = gw.connectorUrl;
    // The six routes (C4, plus the path-suffixed metadata). None of them may be 404.
    const served = [
      ['GET', '/.well-known/oauth-protected-resource', 200],
      ['GET', '/.well-known/oauth-protected-resource/mcp', 200],
      ['GET', '/.well-known/oauth-authorization-server', 200],
      ['POST', '/mcp', 401],
    ];
    for (const [method, path, want] of served) {
      const res = await fetch(`${base}${path}`, { method, redirect: 'manual' });
      assert.equal(res.status, want, `${method} ${path}`);
    }
    const authorize = await fetch(`${base}/authorize`, { redirect: 'manual' });
    assert.notEqual(authorize.status, 404, 'GET /authorize is served');
    const token = await fetch(`${base}/token`, { method: 'POST', redirect: 'manual' });
    assert.notEqual(token.status, 404, 'POST /token is served');

    for (const [method, path] of [
      ['GET', '/.well-known/oauth-protected-resource/'],
      ['GET', '/.well-known/oauth-protected-resource/other'],
      ['GET', '/.well-known/oauth-protected-resource/mcp/extra'],
      ['GET', '/mcp/.well-known/oauth-protected-resource'],
      ['GET', '/.well-known/oauth-protected-resource.json'],
      ['GET', '/.well-known/openid-configuration'],
      ['GET', '/healthz'],
      ['POST', '/register'],
    ]) {
      const res = await fetch(`${base}${path}`, { method, redirect: 'manual' });
      assert.equal(res.status, 404, `${method} ${path}`);
    }
    const wrongMethod = await fetch(`${base}/.well-known/oauth-protected-resource/mcp`, { method: 'POST', redirect: 'manual' });
    assert.equal(wrongMethod.status, 405, 'a wrong method on a known path is 405, not 404');
  } finally {
    await gw.stop();
  }
});

test('the phone listener does not serve the connector metadata, and the phone still works', async () => {
  const gw = await startConnectorGateway({ connector: { publicOrigin: ORIGIN } });
  try {
    for (const path of ['/.well-known/oauth-protected-resource', '/.well-known/oauth-protected-resource/mcp', '/mcp', '/authorize']) {
      const res = await fetch(`${gw.httpUrl.replace(/\/$/, '')}${path}`, { redirect: 'manual' });
      assert.equal(res.status, 404, `the phone listener must not serve ${path}`);
    }
    const ws = await phone(gw);
    const pending = await rpc(ws, '_acpcode/connector/pending', {});
    assert.deepEqual(pending.result, { pairings: [] }, 'the phone WebSocket still answers');
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('--dry-run accepts a publicOrigin with a port and names the bad ones', async () => {
  const dirs = await makeDirs();
  try {
    const good = rawConfig(dirs.root, { connector: { enabled: true, port: 8789, publicOrigin: ORIGIN } });
    const ok = await dryRun(good);
    assert.equal(ok.status, 0, ok.stderr);

    const trailingSlash = await dryRun({ ...good, connector: { ...good.connector, publicOrigin: 'https://name.example/' } });
    assert.equal(trailingSlash.status, 1);
    assert.match(trailingSlash.stderr, /connector\.publicOrigin must be an https origin/);

    const portZero = await dryRun({ ...good, connector: { ...good.connector, publicOrigin: 'https://name.example:0' } });
    assert.equal(portZero.status, 1);
    assert.match(portZero.stderr, /connector\.publicOrigin must be an https origin/);
  } finally {
    await dirs.cleanup();
  }
});
