// Shared helpers for the connector wire tests (D-095). Not a test file: the connector tests import it.
import { createHash, randomBytes } from 'node:crypto';
import { createServer, request as httpRequest } from 'node:http';
import { startGateway, rpc, connect, auth, TOKEN } from './helpers.mjs';

export const PUBLIC_ORIGIN = 'https://connector.test.example';
export const RESOURCE = `${PUBLIC_ORIGIN}/mcp`;
export const CLIENT_ID = 'https://claude.example/oauth/client.json';
export const REDIRECT_URI = 'https://claude.example/api/mcp/auth_callback';

/** A loopback port that is free right now. */
export function freePort() {
  return new Promise((resolve, reject) => {
    const srv = createServer();
    srv.once('error', reject);
    srv.listen(0, '127.0.0.1', () => {
      const { port } = srv.address();
      srv.close(() => resolve(port));
    });
  });
}

/** Start a gateway with the connector on `port`. `connector` overrides the block; `overrides` the config. */
export async function startConnectorGateway({ port, connector = {}, overrides = {} } = {}) {
  const connectorPort = port ?? await freePort();
  const block = {
    enabled: true,
    port: connectorPort,
    publicOrigin: PUBLIC_ORIGIN,
    allowedOrigins: ['https://claude.ai'],
    pairingTimeoutSeconds: 3,
    ...connector,
  };
  const gw = await startGateway({ connector: block, ...overrides });
  return { ...gw, connectorPort, connectorUrl: `http://127.0.0.1:${connectorPort}` };
}

/** A PKCE pair: S256 challenge of a random verifier (RFC 7636). */
export function pkce() {
  const verifier = randomBytes(48).toString('base64url');
  const challenge = createHash('sha256').update(verifier).digest('base64url');
  return { verifier, challenge };
}

/** Build the /authorize query for a PKCE request. */
export function authorizeQuery({ challenge, state = 'st-123', clientId = CLIENT_ID, redirectUri = REDIRECT_URI, resource = RESOURCE, method = 'S256' } = {}) {
  const q = new URLSearchParams({
    response_type: 'code',
    client_id: clientId,
    redirect_uri: redirectUri,
    code_challenge: challenge,
    code_challenge_method: method,
    state,
  });
  if (resource !== undefined) q.set('resource', resource);
  return q;
}

/**
 * Open /authorize. Resolves once the page shows the pairing code (or the response ends, for a
 * refused request). `finished` resolves with the whole body when the held page ends.
 */
export function openAuthorize(port, query) {
  return new Promise((resolve, reject) => {
    let body = '';
    let codeSeen = false;
    let status = 0;
    let headers = {};
    let finishedResolve;
    const finished = new Promise((r) => { finishedResolve = r; });
    const req = httpRequest({ host: '127.0.0.1', port, path: `/authorize?${query}`, method: 'GET' }, (res) => {
      status = res.statusCode;
      headers = res.headers;
      res.setEncoding('utf8');
      res.on('data', (chunk) => {
        body += chunk;
        const m = body.match(/(\d{3}) (\d{3})<\/p>/);
        if (m && !codeSeen) {
          codeSeen = true;
          resolve({ status, headers, code: m[1] + m[2], finished, close: () => req.destroy() });
        }
      });
      res.on('end', () => {
        finishedResolve({ status, headers, body });
        if (!codeSeen) resolve({ status, headers, body, code: null, finished });
      });
      res.on('error', () => {});
    });
    req.on('error', (err) => { if (!codeSeen) reject(err); });
    req.end();
  });
}

/** The URL the held page sent the browser to (the script in its last chunk). */
export function redirectOf(page) {
  const m = page.body.match(/location\.replace\(("(?:[^"\\]|\\.)*")\)/);
  if (!m) throw new Error(`no redirect in the page: ${page.body.slice(-200)}`);
  return new URL(JSON.parse(m[1]));
}

/** POST /token with an authorization code. Resolves { status, json }. */
export async function exchangeCode(port, { code, verifier, clientId = CLIENT_ID, redirectUri = REDIRECT_URI, resource = RESOURCE }) {
  const body = new URLSearchParams({ grant_type: 'authorization_code', code, code_verifier: verifier, client_id: clientId, redirect_uri: redirectUri });
  if (resource !== undefined) body.set('resource', resource);
  const res = await fetch(`http://127.0.0.1:${port}/token`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body,
    redirect: 'manual',
  });
  return { status: res.status, json: await res.json().catch(() => null), headers: res.headers };
}

/** A phone socket on the gateway (owner token). */
export async function phone(gw) {
  const res = await connect(gw.url, auth(TOKEN));
  if (res.status !== 101) throw new Error(`phone connect failed with ${res.status}`);
  return res.ws;
}

/**
 * Run a whole pairing: open /authorize, approve (or deny) on the phone, return the page and the
 * phone's approve answer. `scope` is what the phone sends on approve.
 */
export async function pairOnPhone(gw, { ws, scope = { projects: 'all' }, decide = 'approve', query = {} } = {}) {
  const { verifier, challenge } = pkce();
  const page = await openAuthorize(gw.connectorPort, authorizeQuery({ challenge, ...query }));
  if (!page.code) return { verifier, page, answer: null };
  const pending = await rpc(ws, '_acpcode/connector/pending', {});
  const row = pending.result.pairings.find((p) => p.code === page.code);
  if (!row) throw new Error(`pairing ${page.code} not in pending: ${JSON.stringify(pending)}`);
  const answer = decide === 'approve'
    ? await rpc(ws, '_acpcode/connector/approve', { pairingId: row.pairingId, scope })
    : await rpc(ws, '_acpcode/connector/deny', { pairingId: row.pairingId });
  return { verifier, page, answer, row };
}

/** Pair, approve and exchange: returns { token, grantId, verifier }. */
export async function grantToken(gw, ws, scope) {
  const { verifier, page, answer } = await pairOnPhone(gw, { ws, scope });
  if (!answer?.result) throw new Error(`approve failed: ${JSON.stringify(answer)}`);
  const redirect = redirectOf(await page.finished);
  const code = redirect.searchParams.get('code');
  if (!code) throw new Error(`no code in ${redirect}`);
  const res = await exchangeCode(gw.connectorPort, { code, verifier });
  if (res.status !== 200) throw new Error(`token failed: ${res.status} ${JSON.stringify(res.json)}`);
  return { token: res.json.access_token, grantId: answer.result.grantId, verifier };
}

/** POST one JSON-RPC message to /mcp. Resolves { status, headers, json }. */
export async function mcp(gw, message, { token, headers = {} } = {}) {
  const h = { 'Content-Type': 'application/json', Accept: 'application/json, text/event-stream', ...headers };
  if (token !== undefined) h.Authorization = `Bearer ${token}`;
  const res = await fetch(`${gw.connectorUrl}/mcp`, { method: 'POST', headers: h, body: JSON.stringify(message), redirect: 'manual' });
  const text = await res.text();
  const isJSON = (res.headers.get('content-type') ?? '').includes('application/json');
  return { status: res.status, headers: res.headers, json: isJSON && text ? JSON.parse(text) : null, text };
}

let nextRpcId = 1000;
/** A JSON-RPC request to /mcp with a fresh id. */
export const call = (gw, token, method, params) => mcp(gw, { jsonrpc: '2.0', id: nextRpcId++, method, params }, { token });

/** Call a tool and return the MCP tool result. */
export async function callTool(gw, token, name, args) {
  const res = await call(gw, token, 'tools/call', { name, arguments: args });
  return res.json.result;
}

export { RESOURCE as CANONICAL_RESOURCE };
