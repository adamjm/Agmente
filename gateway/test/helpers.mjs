// Shared test helpers: temp project roots, a gateway on a free port, a WebSocket client.
import { mkdtemp, mkdir, rm, realpath } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import WebSocket from 'ws';
import { validateConfig } from '../src/config.js';
import { hashToken } from '../src/auth.js';
import { createGateway } from '../src/server.js';

export const TOKEN = 'test-token-abcdefghijklmnop';
export const OTHER_TOKEN = 'other-token-abcdefghijklmnop';
export const FAKE_AGENT = fileURLToPath(new URL('./fixtures/fake-agent.mjs', import.meta.url));

/** Make temp dirs: <base>/root/project (allowed) and <base>/outside (not allowed). */
export async function makeDirs() {
  const base = await realpath(await mkdtemp(join(tmpdir(), 'agmente-gw-')));
  const root = join(base, 'root');
  const project = join(root, 'project');
  const outside = join(base, 'outside');
  await mkdir(project, { recursive: true });
  await mkdir(outside, { recursive: true });
  return { base, root, project, outside, cleanup: () => rm(base, { recursive: true, force: true }) };
}

export function rawConfig(root, overrides = {}) {
  return {
    listen: { host: '127.0.0.1', port: 0 },
    trustProxy: false,
    tokens: [
      { id: 'phone', identity: 'owner', sha256: hashToken(TOKEN) },
      { id: 'other', identity: 'guest', sha256: hashToken(OTHER_TOKEN) },
    ],
    agent: { command: [process.execPath, FAKE_AGENT], envPassthrough: ['PATH'] },
    projects: { roots: [root] },
    ...overrides,
    limits: { ...(overrides.limits ?? {}) },
  };
}

/** Start a gateway. Returns { gateway, url, auditLines, dirs, stop }. */
export async function startGateway(overrides = {}, options = {}) {
  const dirs = await makeDirs();
  const config = validateConfig(rawConfig(dirs.root, overrides));
  const auditLines = [];
  const gateway = createGateway(config, { audit: (event, fields = {}) => auditLines.push({ event, ...fields }), ...options });
  const address = await gateway.listen(0, '127.0.0.1');
  const url = `ws://127.0.0.1:${address.port}/`;
  const stop = async () => {
    await gateway.close();
    await dirs.cleanup();
  };
  return { gateway, url, auditLines, dirs, stop, config };
}

/** Connect. Resolves { status: 101, ws } on success or { status } on an HTTP rejection. */
export function connect(url, headers = {}) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url, { headers, perMessageDeflate: false });
    ws.once('open', () => resolve({ status: 101, ws }));
    ws.once('unexpected-response', (req, res) => {
      resolve({ status: res.statusCode, headers: res.headers });
      req.destroy();
    });
    ws.once('error', reject);
  });
}

export const auth = (token = TOKEN) => ({ Authorization: `Bearer ${token}` });

let nextId = 1;
/** Send a JSON-RPC request and wait for the response with the same id. */
export function rpc(ws, method, params) {
  const id = nextId++;
  return new Promise((resolve, reject) => {
    const onMessage = (data) => {
      const msg = JSON.parse(data.toString());
      if (msg.id === id) {
        ws.off('message', onMessage);
        resolve(msg);
      }
    };
    ws.on('message', onMessage);
    ws.once('close', (code) => reject(new Error(`closed with ${code}`)));
    ws.send(JSON.stringify({ jsonrpc: '2.0', id, method, params }));
  });
}

/** Wait for the socket to close. Resolves { code, reason }. */
export function nextClose(ws) {
  return new Promise((resolve) => ws.once('close', (code, reason) => resolve({ code, reason: reason.toString() })));
}

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
