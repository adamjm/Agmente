#!/usr/bin/env node
// Live probe of IBM Bob behind the gateway: T-32, T-33, T-34 and Q-6.
// Usage (BOB_API_KEY must be in the environment; this script never prints it):
//   node gateway/scripts/probe-bob.mjs [--bob <path>] [--skip-load-race]
//     [--trust-project | --distrust-project] [--deny-root]
// --deny-root adds "/": DONT_TRUST, so only folders marked TRUST_FOLDER are trusted (PLAN 4.3).
// The probe registers a temp project (D-024); the gateway runs Bob in it with the project's HOME under
// a temp stateDir (host runner, D-025), so the probe never touches ~/.bob. Registration writes
// TRUST_FOLDER for the project; the probe then rewrites that trust file from its options:
// none (no file), --trust-project (the registration entry), --distrust-project, --deny-root.
// The gateway starts Bob as FR-32 says: --accept-license, no --trust, no --auto-approve.
// Every session/request_permission is answered with a reject option (D-009).
import { mkdtemp, mkdir, readFile, realpath, rm } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { parseArgs } from 'node:util';
import { randomBytes } from 'node:crypto';
import WebSocket from 'ws';
import { hashToken, spawnGateway } from '../test/helpers.mjs';
import { writeFile } from 'node:fs/promises';

const { values } = parseArgs({
  options: {
    bob: { type: 'string' },
    'skip-load-race': { type: 'boolean', default: false },
    'trust-project': { type: 'boolean', default: false },
    'distrust-project': { type: 'boolean', default: false },
    'deny-root': { type: 'boolean', default: false },
  },
});

const bobPath = values.bob ?? execFileSync('/usr/bin/which', ['bob'], { encoding: 'utf8' }).trim();
const bobVersion = execFileSync(bobPath, ['--version'], { encoding: 'utf8' }).split('\n')[0].trim();
const hasKey = typeof process.env.BOB_API_KEY === 'string' && process.env.BOB_API_KEY.length > 0;
const log = (...a) => console.log(...a);

log(`bob: ${bobPath} (${bobVersion}); BOB_API_KEY set: ${hasKey}`);

const base = await realpath(await mkdtemp(join(tmpdir(), 'acpcode-bob-probe-')));
const root = join(base, 'root');
const project = join(root, `untrusted-${randomBytes(4).toString('hex')}`);
await mkdir(project, { recursive: true });
const stateDir = join(base, 'state');
/** Rewrite the project's trust file (in its HOME) from the probe's options. */
async function setTrust(home) {
  const file = join(home, '.bob', 'trustedFolders.json');
  const folders = {};
  if (values['deny-root']) folders['/'] = 'DONT_TRUST';
  if (values['trust-project']) folders[project] = 'TRUST_FOLDER';
  if (values['distrust-project']) folders[project] = 'DONT_TRUST';
  if (Object.keys(folders).length === 0) await rm(file, { force: true });
  else await writeFile(file, JSON.stringify({ version: 1, folders }));
}
log(`deny root: ${values['deny-root']}; project trust: ${values['trust-project'] ? 'TRUST_FOLDER' : values['distrust-project'] ? 'DONT_TRUST' : 'none'}; HOME: the project home under a temp stateDir`);

const token = randomBytes(24).toString('base64url');
const config = {
  listen: { host: '127.0.0.1', port: 0 },
  trustProxy: false,
  tokens: [{ id: 'probe', identity: 'owner', sha256: hashToken(token) }],
  agent: {
    command: [bobPath, 'acp', '--accept-license', '--log-level', 'warn'],
    envPassthrough: ['PATH', 'HOME', 'LANG', 'BOB_API_KEY'],
  },
  projects: { roots: [root] },
  stateDir,
  runner: { kind: 'host', allowHost: true },
  limits: {},
};
// The gateway process (from ACPCODE_GATEWAY_CMD, default the Go binary) starts Bob in the project.
const gateway = await spawnGateway(config);
const auditLines = gateway.audit;

const ws = new WebSocket(gateway.url, {
  headers: { Authorization: `Bearer ${token}` },
  perMessageDeflate: false,
});
await new Promise((resolve, reject) => { ws.once('open', resolve); ws.once('error', reject); });
log('upgrade status 101');

let nextId = 1;
const pending = new Map();
const updates = []; // { at, sessionId, kind }
const permissionRequests = [];

ws.on('message', (data) => {
  const msg = JSON.parse(data.toString());
  if (msg.id !== undefined && pending.has(msg.id) && msg.method === undefined) {
    const { resolve, started } = pending.get(msg.id);
    pending.delete(msg.id);
    resolve({ ...msg, ms: Date.now() - started });
    return;
  }
  if (msg.method === 'session/update') {
    updates.push({ at: Date.now(), sessionId: msg.params?.sessionId, kind: msg.params?.update?.sessionUpdate });
    return;
  }
  if (msg.method === 'session/request_permission') {
    // D-009: never approve. Pick a reject option, or cancel.
    const options = msg.params?.options ?? [];
    const reject = options.find((o) => o.kind === 'reject_once') ?? options.find((o) => o.kind === 'reject_always');
    permissionRequests.push({ title: msg.params?.toolCall?.title, chose: reject?.kind ?? 'cancelled' });
    const outcome = reject ? { outcome: 'selected', optionId: reject.optionId } : { outcome: 'cancelled' };
    ws.send(JSON.stringify({ jsonrpc: '2.0', id: msg.id, result: { outcome } }));
    return;
  }
  if (msg.id !== undefined && msg.method !== undefined) {
    // Other agent-to-client requests (fs, terminal): we advertise none, so refuse.
    ws.send(JSON.stringify({ jsonrpc: '2.0', id: msg.id, error: { code: -32601, message: 'not supported by probe' } }));
  }
});

function rpc(method, params, timeoutMs = 180_000) {
  const id = nextId++;
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      resolve({ error: { code: 'timeout', message: `no response in ${timeoutMs} ms` } });
    }, timeoutMs);
    pending.set(id, { resolve: (r) => { clearTimeout(timer); resolve(r); }, started: Date.now() });
    ws.send(JSON.stringify({ jsonrpc: '2.0', id, method, params }));
  });
}

const show = (label, res) => log(`${label} -> ${res.error ? `ERROR ${JSON.stringify(res.error)}` : 'ok'} (${res.ms ?? '?'} ms)`);
const results = {};

try {
  const registered = await rpc('_acpcode/projects/create', { name: 'probe', path: project });
  show('_acpcode/projects/create', registered);
  await setTrust(join(stateDir, 'homes', registered.result.project.id));

  // T-8 sanity: cwd outside roots never reaches Bob.
  show('session/new outside roots', await rpc('session/new', { cwd: base, mcpServers: [] }));

  // T-33 + Q-6: session/new, with the trust file the options asked for. This starts Bob.
  const created = await rpc('session/new', { cwd: project, mcpServers: [] });
  show('session/new (Q-6 trust as above)', created);

  // T-32: the gateway now answers initialize with Bob's captured capabilities (D-026).
  const init = await rpc('initialize', { protocolVersion: 1, clientCapabilities: {} });
  show('initialize', init);
  const fixture = JSON.parse(await readFile(new URL('../test/fixtures/bob-initialize-2.0.9.json', import.meta.url), 'utf8')).result;
  const strip = (r) => {
    const out = { ...r, agentInfo: { ...r.agentInfo, version: '<v>' } };
    if (out._meta) {
      const { 'acpcode/gateway': _gw, ...rest } = out._meta;
      if (Object.keys(rest).length) out._meta = rest;
      else delete out._meta;
    }
    return out;
  };
  const same = JSON.stringify(strip(init.result ?? {})) === JSON.stringify(strip(fixture));
  log(`initialize agentInfo: ${JSON.stringify(init.result?.agentInfo)}; gateway: ${JSON.stringify(init.result?._meta?.['acpcode/gateway'])}`);
  log(`initialize matches fixture (ignoring version and the gateway _meta): ${same}`);
  if (!same) log(`initialize result: ${JSON.stringify(init.result)}`);
  results.T32 = same;
  const sessionId = created.result?.sessionId;
  if (created.result) log(`session/new result keys: ${Object.keys(created.result).join(', ')}; modes: ${JSON.stringify(created.result.modes?.availableModes?.map((m) => m.id) ?? null)}`);
  results.sessionNew = !!sessionId;

  if (sessionId) {
    // T-33: a prompt.
    const before = updates.length;
    const prompt = await rpc('session/prompt', {
      sessionId,
      prompt: [{ type: 'text', text: 'Reply with exactly the word: pong. Do not use any tools.' }],
    });
    show('session/prompt', prompt);
    log(`  stopReason: ${prompt.result?.stopReason}; updates: ${[...new Set(updates.slice(before).map((u) => u.kind))].join(', ')}`);
    results.prompt = prompt.result?.stopReason === 'end_turn';

    // session/list
    const list = await rpc('session/list', { cwd: project });
    show('session/list', list);
    if (list.result) log(`  sessions listed: ${list.result.sessions?.length}`);

    // T-33: session/load and session/resume while idle.
    const load = await rpc('session/load', { sessionId, cwd: project, mcpServers: [] });
    show('session/load (idle)', load);
    results.load = !load.error;
    const resume = await rpc('session/resume', { sessionId, cwd: project, mcpServers: [] });
    show('session/resume (idle)', resume);
    results.resume = !resume.error;

    // T-34 / Q-1: does session/load cancel a running turn?
    if (!values['skip-load-race']) {
      const startUpdates = updates.length;
      const longTurn = rpc('session/prompt', {
        sessionId,
        prompt: [{ type: 'text', text: 'Without using any tools, write the numbers from 1 to 300 as English words, one per line.' }],
      });
      // Wait for the turn to start streaming.
      const t0 = Date.now();
      while (updates.length === startUpdates && Date.now() - t0 < 60_000) await new Promise((r) => setTimeout(r, 100));
      await new Promise((r) => setTimeout(r, 1500));
      const midUpdates = updates.length - startUpdates;
      const raceLoad = await rpc('session/load', { sessionId, cwd: project, mcpServers: [] });
      show('session/load during running turn (Q-1)', raceLoad);
      const turn = await longTurn;
      show('  running turn', turn);
      log(`  running turn stopReason: ${turn.result?.stopReason ?? JSON.stringify(turn.error)}; updates before load: ${midUpdates}; after: ${updates.length - startUpdates - midUpdates}`);
      results.Q1 = turn.result?.stopReason ?? 'error';
    }

    // Clean up the session on Bob.
    show('session/delete', await rpc('session/delete', { sessionId }));
  }
  log(`permission requests: ${JSON.stringify(permissionRequests)}`);
} finally {
  ws.close();
  await new Promise((r) => setTimeout(r, 300));
  await gateway.stop();
  await rm(base, { recursive: true, force: true });
  log(`audit events: ${auditLines.map((l) => (l.method ? `${l.event}:${l.method}` : l.event)).join(', ')}`);
  log(`summary: ${JSON.stringify(results)}`);
}
