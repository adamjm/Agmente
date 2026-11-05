#!/usr/bin/env node
// Live race probes on IBM Bob behind the gateway (follow-up to T-34, Q-1 and Q-5).
//   R1: session/resume while a turn runs, same Bob process.
//   R2: a second socket (so a second Bob process, D-006) loads, then prompts, a session that is
//       running in the first process. Both processes share HOME and the project folder.
//   R3: a third process loads the session afterwards; which user prompts are in the replay?
// Usage (BOB_API_KEY must be in the environment; this script never prints it):
//   node gateway/scripts/probe-bob-races.mjs [--bob <path>]
// Bob runs with a disposable HOME and a trusted temp project, as in probe-bob.mjs.
// Every session/request_permission is answered with a reject option (D-009).
import { mkdtemp, mkdir, readdir, realpath, rm, writeFile } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { parseArgs } from 'node:util';
import { randomBytes } from 'node:crypto';
import WebSocket from 'ws';
import { validateConfig } from '../src/config.js';
import { hashToken } from '../src/auth.js';
import { createGateway } from '../src/server.js';
import { spawnAgent } from '../src/agent-process.js';

const { values } = parseArgs({ options: { bob: { type: 'string' } } });
const bobPath = values.bob ?? execFileSync('/usr/bin/which', ['bob'], { encoding: 'utf8' }).trim();
const bobVersion = execFileSync(bobPath, ['--version'], { encoding: 'utf8' }).split('\n')[0].trim();
const log = (...a) => console.log(...a);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
log(`bob: ${bobPath} (${bobVersion}); BOB_API_KEY set: ${!!process.env.BOB_API_KEY}`);

const base = await realpath(await mkdtemp(join(tmpdir(), 'agmente-bob-race-')));
const root = join(base, 'root');
const project = join(root, 'project');
const home = join(base, 'home');
await mkdir(project, { recursive: true });
await mkdir(join(home, '.bob'), { recursive: true });
await writeFile(join(home, '.bob', 'trustedFolders.json'), JSON.stringify({ version: 1, folders: { [project]: 'TRUST_FOLDER' } }));

const token = randomBytes(24).toString('base64url');
const config = validateConfig({
  listen: { host: '127.0.0.1', port: 0 },
  trustProxy: false,
  tokens: [{ id: 'probe', identity: 'owner', sha256: hashToken(token) }],
  agent: { command: [bobPath, 'acp', '--accept-license', '--log-level', 'warn'], envPassthrough: ['PATH', 'HOME', 'LANG', 'BOB_API_KEY'] },
  projects: { roots: [root] },
  limits: {},
});
const stderrByPid = new Map();
const probeSpawn = (agentConfig) => {
  const saved = process.env.HOME;
  process.env.HOME = home;
  try {
    const child = spawnAgent(agentConfig, { cwd: project });
    const chunks = [];
    stderrByPid.set(child.pid, chunks);
    child.stderr.on('data', (d) => chunks.push(d.toString()));
    return child;
  } finally {
    process.env.HOME = saved;
  }
};
const gateway = createGateway(config, { audit: () => {}, spawn: probeSpawn });
const address = await gateway.listen(0, '127.0.0.1');

/** One socket = one Bob process (phase 1, D-006). */
async function client(label) {
  const ws = new WebSocket(`ws://127.0.0.1:${address.port}/`, { headers: { Authorization: `Bearer ${token}` }, perMessageDeflate: false });
  await new Promise((resolve, reject) => { ws.once('open', resolve); ws.once('error', reject); });
  let nextId = 1;
  const pending = new Map();
  const updates = []; // { kind, text }
  ws.on('message', (data) => {
    const msg = JSON.parse(data.toString());
    if (msg.id !== undefined && msg.method === undefined && pending.has(msg.id)) {
      const p = pending.get(msg.id);
      pending.delete(msg.id);
      p.resolve({ ...msg, ms: Date.now() - p.started });
    } else if (msg.method === 'session/update') {
      const u = msg.params?.update ?? {};
      updates.push({ kind: u.sessionUpdate, text: typeof u.content?.text === 'string' ? u.content.text : '' });
    } else if (msg.method === 'session/request_permission') {
      const reject = (msg.params?.options ?? []).find((o) => o.kind === 'reject_once' || o.kind === 'reject_always');
      ws.send(JSON.stringify({ jsonrpc: '2.0', id: msg.id, result: { outcome: reject ? { outcome: 'selected', optionId: reject.optionId } : { outcome: 'cancelled' } } }));
    } else if (msg.id !== undefined && msg.method !== undefined) {
      ws.send(JSON.stringify({ jsonrpc: '2.0', id: msg.id, error: { code: -32601, message: 'not supported by probe' } }));
    }
  });
  const rpc = (method, params, timeoutMs = 240_000) => {
    const id = nextId++;
    return new Promise((resolve) => {
      const timer = setTimeout(() => { pending.delete(id); resolve({ error: { code: 'timeout' } }); }, timeoutMs);
      pending.set(id, { resolve: (r) => { clearTimeout(timer); resolve(r); }, started: Date.now() });
      ws.send(JSON.stringify({ jsonrpc: '2.0', id, method, params }));
    });
  };
  const show = (what, res) => log(`[${label}] ${what} -> ${res.error ? `ERROR ${JSON.stringify(res.error)}` : `ok${res.result?.stopReason ? ` stopReason=${res.result.stopReason}` : ''}`} (${res.ms ?? '?'} ms)`);
  const userTexts = () => updates.filter((u) => u.kind === 'user_message_chunk').map((u) => u.text).join('');
  const close = async () => { ws.close(); await sleep(300); };
  await rpc('initialize', { protocolVersion: 1, clientCapabilities: {} });
  return { rpc, show, updates, userTexts, close };
}

/** Start a long turn and resolve once it is streaming. */
async function startLongTurn(c, sessionId, marker) {
  const start = c.updates.length;
  const turn = c.rpc('session/prompt', {
    sessionId,
    prompt: [{ type: 'text', text: `[${marker}] Without using any tools, write the numbers from 1 to 400 as English words, one per line.` }],
  });
  const t0 = Date.now();
  while (c.updates.length === start && Date.now() - t0 < 60_000) await sleep(100);
  await sleep(1500);
  return { turn, start };
}

const results = {};
let a;
let sessionId;
try {
  a = await client('A');
  const created = await a.rpc('session/new', { cwd: project, mcpServers: [] });
  a.show('session/new', created);
  sessionId = created.result?.sessionId;
  if (!sessionId) throw new Error('no session');
  a.show('warm-up prompt [P0]', await a.rpc('session/prompt', { sessionId, prompt: [{ type: 'text', text: '[P0] Reply with exactly the word: pong. Do not use any tools.' }] }));

  // R0: idle load in the same process. What does Bob send back?
  {
    const start = a.updates.length;
    const load = await a.rpc('session/load', { sessionId, cwd: project, mcpServers: [] });
    await sleep(500);
    a.show('R0 session/load (idle, same process)', load);
    const kinds = a.updates.slice(start).map((u) => u.kind);
    log(`[A] R0 load result keys: ${JSON.stringify(Object.keys(load.result ?? {}))}; updates: ${kinds.length} ${JSON.stringify([...new Set(kinds)])}; user prompts: ${JSON.stringify(a.updates.slice(start).filter((u) => u.kind === 'user_message_chunk').map((u) => u.text.slice(0, 4)))}`);
  }

  // R1: resume during a running turn, same process.
  {
    const { turn, start } = await startLongTurn(a, sessionId, 'P1');
    const mid = a.updates.length - start;
    const resume = await a.rpc('session/resume', { sessionId, cwd: project, mcpServers: [] });
    a.show('R1 session/resume during running turn', resume);
    const done = await turn;
    a.show('R1 running turn', done);
    log(`[A] R1 updates before resume: ${mid}; after: ${a.updates.length - start - mid}`);
    results.R1 = { resume: resume.error ? resume.error.message : 'ok', turn: done.result?.stopReason ?? done.error };
  }

  // R2: a second Bob process loads and prompts the session while process A runs a turn.
  {
    const { turn, start } = await startLongTurn(a, sessionId, 'P2');
    const b = await client('B');
    const bLoad = await b.rpc('session/load', { sessionId, cwd: project, mcpServers: [] });
    b.show('R2 session/load in a second process during A\'s turn', bLoad);
    log(`[B] R2 replay: ${b.updates.length} updates; user prompts seen: ${JSON.stringify((b.userTexts().match(/\[P\d\]/g) ?? []))}`);
    const aBefore = a.updates.length;
    const bPrompt = await b.rpc('session/prompt', { sessionId, prompt: [{ type: 'text', text: '[PB] Reply with exactly the word: from-b. Do not use any tools.' }] });
    b.show('R2 session/prompt in the second process during A\'s turn', bPrompt);
    const done = await turn;
    a.show('R2 A\'s running turn', done);
    log(`[A] R2 A kept streaming while B prompted: ${a.updates.length - aBefore} updates; A total for the turn: ${a.updates.length - start}`);
    results.R2 = { load: bLoad.error ? bLoad.error.message : 'ok', prompt: bPrompt.error ? bPrompt.error.message : bPrompt.result?.stopReason, aTurn: done.result?.stopReason ?? done.error };
    await b.close();
  }

  // R3: a third process loads afterwards. Which prompts does Bob's stored history hold?
  {
    const c = await client('C');
    const cLoad = await c.rpc('session/load', { sessionId, cwd: project, mcpServers: [] });
    c.show('R3 session/load in a third process', cLoad);
    await sleep(1000);
    log(`[C] R3 load result keys: ${JSON.stringify(Object.keys(cLoad.result ?? {}))}; update kinds: ${JSON.stringify([...new Set(c.updates.map((u) => u.kind))])}`);
    const list = await c.rpc('session/list', { cwd: project });
    c.show('R3 session/list', list);
    log(`[C] R3 listed: ${JSON.stringify((list.result?.sessions ?? []).map((x) => ({ id: x.sessionId === sessionId ? 'same' : 'other', title: x.title?.slice(0, 40) })))}`);
    const seen = c.userTexts().match(/\[P[0-9B]\]/g) ?? [];
    log(`[C] R3 replay: ${c.updates.length} updates; user prompts in history: ${JSON.stringify(seen)}`);
    results.R3 = { load: cLoad.error ? cLoad.error.message : 'ok', prompts: seen };
    await c.close();
  }

  a.show('session/delete', await a.rpc('session/delete', { sessionId }));
} finally {
  if (a) await a.close();
  await gateway.close();
  const errLines = [...stderrByPid.values()].flat().join('').split('\n').filter((l) => /lock|SQLITE|busy|conflict|error/i.test(l));
  log(`agent stderr lines matching lock|SQLITE|busy|conflict|error: ${errLines.length}`);
  for (const l of errLines.slice(0, 10)) log(`  ${l.slice(0, 300)}`);
  try { log(`HOME/.bob after run: ${JSON.stringify(await readdir(join(home, '.bob')))}`); } catch { /* none */ }
  await rm(base, { recursive: true, force: true });
  log(`summary: ${JSON.stringify(results)}`);
}
