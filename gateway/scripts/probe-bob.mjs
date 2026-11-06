#!/usr/bin/env node
// Live probe of IBM Bob behind the gateway: T-32, T-33, T-34 and Q-6.
// Usage (BOB_API_KEY must be in the environment; this script never prints it):
//   node gateway/scripts/probe-bob.mjs [--bob <path>] [--skip-load-race] [--agent-cwd gateway|project]
//     [--trust-project | --distrust-project] [--deny-root]
// --deny-root adds "/": DONT_TRUST, so only folders marked TRUST_FOLDER are trusted (PLAN 4.3).
// Bob runs with a disposable HOME, so the probe never touches ~/.bob. --trust-project writes the
// project folder to that HOME's .bob/trustedFolders.json, as PLAN 4.3 would at registration.
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
    'agent-cwd': { type: 'string', default: 'project' },
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

const base = await realpath(await mkdtemp(join(tmpdir(), 'agmente-bob-probe-')));
const root = join(base, 'root');
const project = join(root, `untrusted-${randomBytes(4).toString('hex')}`);
await mkdir(project, { recursive: true });
const home = join(base, 'home');
await mkdir(join(home, '.bob'), { recursive: true });
if (values['trust-project'] || values['deny-root']) {
  const folders = {};
  if (values['deny-root']) folders['/'] = 'DONT_TRUST';
  if (values['trust-project']) folders[project] = 'TRUST_FOLDER';
  await writeFile(join(home, '.bob', 'trustedFolders.json'), JSON.stringify({ version: 1, folders }));
}
if (values['distrust-project']) {
  await writeFile(join(home, '.bob', 'trustedFolders.json'), JSON.stringify({ version: 1, folders: { [project]: 'DONT_TRUST' } }));
}
log(`deny root: ${values['deny-root']}; agent cwd: ${values['agent-cwd']}; project trust: ${values['trust-project'] ? 'TRUST_FOLDER' : values['distrust-project'] ? 'DONT_TRUST' : 'none'}; HOME: disposable`);

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
  limits: {},
};
// The gateway process (from AGMENTE_GATEWAY_CMD, default the Go binary) runs with the agent's cwd
// and a disposable HOME; the agent inherits the cwd and gets HOME through envPassthrough.
const gateway = await spawnGateway(config, { cwd: values['agent-cwd'] === 'project' ? project : process.cwd(), env: { HOME: home } });
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
  // T-32: initialize, compared with the 2.0.9 fixture.
  const init = await rpc('initialize', { protocolVersion: 1, clientCapabilities: {} });
  show('initialize', init);
  const fixture = JSON.parse(await readFile(new URL('../test/fixtures/bob-initialize-2.0.9.json', import.meta.url), 'utf8')).result;
  const strip = (r) => ({ ...r, agentInfo: { ...r.agentInfo, version: '<v>' } });
  const same = JSON.stringify(strip(init.result ?? {})) === JSON.stringify(strip(fixture));
  log(`initialize agentInfo: ${JSON.stringify(init.result?.agentInfo)}`);
  log(`initialize matches fixture (ignoring version): ${same}`);
  if (!same) log(`initialize result: ${JSON.stringify(init.result)}`);
  results.T32 = same;

  // T-8 sanity: cwd outside roots never reaches Bob.
  show('session/new outside roots', await rpc('session/new', { cwd: base, mcpServers: [] }));

  // T-33 + Q-6: session/new in a folder that was never trusted.
  const created = await rpc('session/new', { cwd: project, mcpServers: [] });
  show('session/new in untrusted folder (Q-6)', created);
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
