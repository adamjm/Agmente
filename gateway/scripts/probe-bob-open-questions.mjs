#!/usr/bin/env node
// Live probes of IBM Bob 2.0.9 for the open questions Q-2 (T-39), Q-3 (T-42), Q-4 (T-43), and the
// idle-close question (session/close, D-032 "verify").
// Usage (BOB_API_KEY must be in the environment; this script never prints it):
//   node gateway/scripts/probe-bob-open-questions.mjs [--bob <path>] [--port 8931] [--keep]
//
// Why Bob's own stdio and not the gateway: the gateway answers session/load and session/resume
// itself for a live session (D-029), so going through it would hide the behaviour under test.
// Bob runs as `bob acp --accept-license --log-level warn` (no --auto-approve, no --trust) in a
// scratch project under ~/.agmente-live/ with a disposable HOME. Every permission request is
// answered here: allow once only for the probe's own tool (make_image, ping_http); reject the rest.
// Output: one line per observation. Raw traffic is kept in the scratch folder and removed unless --keep.
import { spawn, execFileSync } from 'node:child_process';
import { createWriteStream } from 'node:fs';
import { mkdir, mkdtemp, realpath, rm, writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';

const { values } = parseArgs({
  options: {
    bob: { type: 'string' },
    port: { type: 'string', default: '8931' },
    keep: { type: 'boolean', default: false },
    'env-file': { type: 'string' },
    only: { type: 'string' }, // e.g. q2 or q3,q4 (sections run; others skipped)
    raw: { type: 'boolean', default: false }, // print each session/update as received, long strings elided
  },
});
const here = dirname(fileURLToPath(import.meta.url));
const OQ = join(here, 'open-questions');
const bobPath = values.bob ?? execFileSync('/usr/bin/which', ['bob'], { encoding: 'utf8' }).trim();
// The key comes from the environment, or from --env-file (only its BOB_API_KEY line is read, in
// this process; the value is never printed). The shell form `set -a; . file; set +a` is preferred.
if (!process.env.BOB_API_KEY && values['env-file']) {
  const { readFileSync } = await import('node:fs');
  const line = readFileSync(values['env-file'], 'utf8').split('\n').find((l) => /^\s*(export\s+)?BOB_API_KEY=/.test(l));
  if (line) process.env.BOB_API_KEY = line.replace(/^\s*(export\s+)?BOB_API_KEY=/, '').trim().replace(/^['"]|['"]$/g, '');
}
const key = process.env.BOB_API_KEY ?? '';
const scrub = (s) => (key ? String(s).split(key).join('[redacted]') : String(s));
const log = (...a) => console.log(scrub(a.join(' ')));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const short = (v, n = 300) => scrub(JSON.stringify(v) ?? 'undefined').slice(0, n);

log(`bob: ${bobPath}; BOB_API_KEY set: ${key.length > 0}`);
const bobVersion = execFileSync(bobPath, ['--version'], { encoding: 'utf8' }).split('\n')[0].trim();
log(`bob version: ${bobVersion}`);

// --- scratch folders (under ~/.agmente-live, not the repo) -------------------
const liveDir = join(homedir(), '.agmente-live');
await mkdir(liveDir, { recursive: true });
const base = await realpath(await mkdtemp(join(liveDir, `openq-${new Date().toISOString().slice(0, 10)}-`)));
const project = join(base, 'root', 'proj');
const home = join(base, 'home');
await mkdir(project, { recursive: true });
await mkdir(home, { recursive: true });
const git = (...a) => execFileSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@t', ...a], { cwd: project, stdio: 'pipe' });
git('init', '-q', '-b', 'main');
await writeFile(join(project, 'README.md'), 'open questions scratch\n');
git('add', '.');
git('commit', '-q', '-m', 'init');

// Q-2 server: project .bob/mcp.json with one stdio MCP server (keys per Bob 2.0.9 schema: type, command, args).
await mkdir(join(project, '.bob'), { recursive: true });
await writeFile(join(project, '.bob', 'mcp.json'), `${JSON.stringify({
  mcpServers: { 'probe-image': { type: 'stdio', command: process.execPath, args: [join(OQ, 'mcp-image-server.mjs')] } },
}, null, 2)}\n`);

// --- local HTTP MCP server for Q-3 -------------------------------------------
const httpPort = Number(values.port);
const httpUrl = `http://127.0.0.1:${httpPort}/mcp`;
const events = [];
let step = 'setup';
const httpSrv = spawn(process.execPath, [join(OQ, 'mcp-http-server.mjs'), String(httpPort)], { stdio: ['ignore', 'pipe', 'pipe'] });
httpSrv.stdout.on('data', (c) => {
  for (const line of String(c).split('\n')) {
    if (line.startsWith('REQ ')) events.push({ step, kind: 'http_mcp_request', method: line.slice(4) });
  }
});
await new Promise((resolve) => httpSrv.stdout.once('data', resolve));

// --- Bob over stdio -----------------------------------------------------------
const bob = spawn(bobPath, ['acp', '--accept-license', '--log-level', 'warn'], {
  cwd: project,
  env: { PATH: process.env.PATH, HOME: home, LANG: process.env.LANG ?? 'en_US.UTF-8', BOB_API_KEY: key },
  stdio: ['pipe', 'pipe', 'pipe'],
});
const stderrFile = createWriteStream(join(base, 'bob-stderr.log'));
bob.stderr.pipe(stderrFile);
bob.on('exit', (code, sig) => events.push({ step, kind: 'bob_exit', code, sig }));

let nextId = 1;
const pending = new Map();
const send = (obj) => bob.stdin.write(`${JSON.stringify(obj)}\n`);
const rpc = (method, params, ms = 240_000) => new Promise((resolve) => {
  const id = nextId++;
  const t = setTimeout(() => { pending.delete(id); resolve({ error: { code: 'timeout', message: `${method} no answer in ${ms} ms` } }); }, ms);
  pending.set(id, (m) => { clearTimeout(t); resolve(m); });
  send({ jsonrpc: '2.0', id, method, params });
});

let buf = '';
bob.stdout.on('data', (chunk) => {
  buf += chunk;
  let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i);
    buf = buf.slice(i + 1);
    if (!line.trim()) continue;
    let msg;
    try { msg = JSON.parse(line); } catch { events.push({ step, kind: 'non_json_stdout', line: line.slice(0, 120) }); continue; }
    if (msg.id !== undefined && msg.method === undefined) {
      pending.get(msg.id)?.(msg);
      pending.delete(msg.id);
    } else if (msg.method === 'session/update') {
      events.push({ step, kind: 'update', sessionId: msg.params.sessionId, update: msg.params.update });
    } else if (msg.method === 'session/request_permission') {
      const tc = msg.params?.toolCall ?? {};
      const opts = msg.params?.options ?? [];
      // Allow only the probe's own harmless tools, once. Everything else is rejected (D-009).
      // Bob titles the call "Running Make Image (probe-image)", so match both spellings.
      const allowed = /make[_ ]image|ping[_ ]http/i.test(JSON.stringify(tc)) && /probe-(image|http)/.test(JSON.stringify(tc));
      const pick = allowed ? opts.find((o) => o.kind === 'allow_once') : (opts.find((o) => o.kind === 'reject_once') ?? opts.find((o) => o.kind === 'reject_always'));
      events.push({ step, kind: 'permission', title: tc.title, toolKind: tc.kind, chose: pick?.kind ?? 'cancelled' });
      send({ jsonrpc: '2.0', id: msg.id, result: pick ? { outcome: { outcome: 'selected', optionId: pick.optionId } } : { outcome: { outcome: 'cancelled' } } });
    } else if (msg.id !== undefined && msg.method) {
      // Other agent requests (fs, terminal): the probe advertises neither.
      events.push({ step, kind: 'agent_request', method: msg.method });
      send({ jsonrpc: '2.0', id: msg.id, error: { code: -32601, message: 'not supported by probe' } });
    } else {
      events.push({ step, kind: 'other', method: msg.method });
    }
  }
});

// --- helpers --------------------------------------------------------------------
const updatesSince = (start, sid) => events.slice(start).filter((e) => e.kind === 'update' && (sid === undefined || e.sessionId === sid)).map((e) => e.update);
function shapeOf(u) {
  const out = { sessionUpdate: u.sessionUpdate, keys: Object.keys(u).sort() };
  if (u.status) out.status = u.status;
  if (u.kind) out.kind = u.kind;
  const blocks = Array.isArray(u.content) ? u.content : u.content ? [u.content] : [];
  if (blocks.length) {
    out.content = blocks.map((b) => {
      const s = { type: b.type, keys: Object.keys(b).sort() };
      if (b.type === 'text') s.textLength = (b.text ?? '').length;
      if (b.type === 'image') { s.mimeType = b.mimeType; s.dataLength = (b.data ?? '').length; }
      if (b.type === 'content' && b.content) s.inner = { type: b.content.type, keys: Object.keys(b.content).sort(), mimeType: b.content.mimeType };
      return s;
    });
  }
  if (u.sessionUpdate === 'available_commands_update') out.commands = (u.availableCommands ?? []).map((c) => c.name);
  return out;
}
const want = (k) => !values.only || values.only.split(',').includes(k);
const elide = (v) => (typeof v === 'string' ? (v.length > 200 ? `<string len=${v.length}>` : v) : Array.isArray(v) ? v.map(elide) : v && typeof v === 'object' ? Object.fromEntries(Object.entries(v).map(([k, x]) => [k, elide(x)])) : v);
function describe(label, start, sid) {
  const ups = updatesSince(start, sid);
  if (values.raw) for (const u of ups) log(`  raw ${label}: ${short(elide(u), 1500)}`);
  const seen = new Map();
  for (const u of ups) { const k = short(shapeOf(u), 600); seen.set(k, (seen.get(k) ?? 0) + 1); }
  log(`  [${label}] ${ups.length} session/update(s), distinct shapes:`);
  for (const [k, n] of seen) log(`    x${n} ${k}`);
  const perms = events.slice(start).filter((e) => e.kind === 'permission');
  for (const p of perms) log(`    permission: title=${short(p.title, 120)} kind=${p.toolKind} chose=${p.chose}`);
  const http = events.slice(start).filter((e) => e.kind === 'http_mcp_request').map((e) => e.method);
  if (http.length) log(`    http MCP requests seen: ${http.join(', ')}`);
  return ups;
}
function agentText(ups) {
  return ups.filter((u) => u.sessionUpdate === 'agent_message_chunk').map((u) => (Array.isArray(u.content) ? '' : u.content?.text ?? '')).join('');
}
async function turn(label, sid, text) {
  step = label;
  const start = events.length;
  const t0 = Date.now();
  const res = await rpc('session/prompt', { sessionId: sid, prompt: [{ type: 'text', text }] });
  await sleep(400);
  log(`${label}: session/prompt -> ${res.error ? `ERROR ${short(res.error, 300)}` : `stopReason=${res.result?.stopReason}`} (${Date.now() - t0} ms)`);
  const ups = describe(label, start, sid);
  log(`    agent text: ${scrub(agentText(ups)).slice(0, 160)}`);
  return { res, ups };
}

const findCmds = (ups) => ups.filter((u) => u.sessionUpdate === 'available_commands_update').flatMap((u) => (u.availableCommands ?? []).map((c) => c.name));
const httpServer = { type: 'http', name: 'probe-http', url: httpUrl, headers: [] };
const cwd = project;

try {
  // --- handshake ---------------------------------------------------------------
  step = 'init';
  const init = await rpc('initialize', { protocolVersion: 1, clientCapabilities: {} });
  if (init.error) throw new Error(`initialize: ${short(init.error)}`);
  const caps = init.result ?? {};
  log(`initialize: agentCapabilities keys ${short(Object.keys(caps.agentCapabilities ?? {}), 300)}`);
  log(`  loadSession=${caps.agentCapabilities?.loadSession} sessionCapabilities=${short(caps.agentCapabilities?.sessionCapabilities, 300)}`);
  log(`  mcpCapabilities=${short(caps.agentCapabilities?.mcpCapabilities, 200)} promptCapabilities=${short(caps.agentCapabilities?.promptCapabilities, 200)}`);

  // --- Q-2: image content from an MCP tool result ---------------------------------
  if (want('q2')) {
    log('--- Q-2 (T-39): image from an MCP tool result');
    const s2 = await rpc('session/new', { cwd, mcpServers: [] });
    if (s2.error) throw new Error(`session/new q2: ${short(s2.error)}`);
    const sid2 = s2.result.sessionId;
    await sleep(1500);
    await turn('q2-image', sid2, 'Call the make_image tool once, then reply with the single word done.');
  }

  // --- Q-3: session/resume with a changed mcpServers list -----------------------
  if (want('q3')) {
  log('--- Q-3 (T-42): session/resume with a changed mcpServers list');
  const s3= await rpc('session/new', { cwd, mcpServers: [] });
  if (s3.error) throw new Error(`session/new q3: ${short(s3.error)}`);
  const sid3 = s3.result.sessionId;
  await sleep(1000);
  step = 'q3-resume-add';
  let start = events.length;
  const r3a = await rpc('session/resume', { sessionId: sid3, cwd, mcpServers: [httpServer] });
  await sleep(1500);
  log(`q3-resume-add: session/resume with probe-http -> ${r3a.error ? `ERROR ${short(r3a.error, 300)}` : `ok ${short(r3a.result, 200)}`}`);
  describe('q3-resume-add', start, sid3);
  await turn('q3-after-add', sid3, 'If a tool named ping_http is available to you, call it once and reply with exactly its output. If no such tool is available, reply with exactly NO_TOOL.');
  step = 'q3-resume-remove';
  start = events.length;
  const r3b = await rpc('session/resume', { sessionId: sid3, cwd, mcpServers: [] });
  await sleep(1500);
  log(`q3-resume-remove: session/resume with mcpServers [] -> ${r3b.error ? `ERROR ${short(r3b.error, 300)}` : `ok ${short(r3b.result, 200)}`}`);
  describe('q3-resume-remove', start, sid3);
  await turn('q3-after-remove', sid3, 'If a tool named ping_http is available to you, call it once and reply with exactly its output. If no such tool is available, reply with exactly NO_TOOL.');

  }
  // --- Q-4: a skill added to a running session ------------------------------------
  if (want('q4')) {
  log('--- Q-4 (T-43): skill added after the session started');
  const s4= await rpc('session/new', { cwd, mcpServers: [] });
  if (s4.error) throw new Error(`session/new q4: ${short(s4.error)}`);
  const sid4 = s4.result.sessionId;
  await sleep(1500);
  const cmdsBefore = findCmds(updatesSince(0, sid4));
  log(`q4 commands before the skill exists: ${short(cmdsBefore, 400)}`);
  await turn('q4-before-skill', sid4, '/probe-skill');

  step = 'q4-add-skill';
  const skillDir = join(project, '.bob', 'skills', 'probe-skill');
  await mkdir(skillDir, { recursive: true });
  await writeFile(join(skillDir, 'SKILL.md'), [
    '---',
    'name: probe-skill',
    'description: Probe skill for the open-question test. Use when the user asks for probe-skill.',
    '---',
    '',
    'When this skill is invoked, reply with exactly the text SKILL-MARKER-7431 and nothing else. Do not use any tools.',
    '',
  ].join('\n'));
  const addAt = events.length;
  await sleep(5000); // give a watcher time to react without any prompt
  const afterAdd = updatesSince(addAt, sid4).filter((u) => u.sessionUpdate === 'available_commands_update');
  log(`q4 available_commands_update after the file was added, no prompt: ${afterAdd.length} (${short(afterAdd.map((u) => (u.availableCommands ?? []).map((c) => c.name)), 300)})`);
  await turn('q4-no-load', sid4, '/probe-skill');

  step = 'q4-load';
  start = events.length;
  const l4 = await rpc('session/load', { sessionId: sid4, cwd, mcpServers: [] });
  await sleep(1500);
  log(`q4-load: session/load (idle, same process) -> ${l4.error ? `ERROR ${short(l4.error, 300)}` : 'ok'}`);
  const loadUps = describe('q4-load', start, sid4);
  log(`    commands in load replay: ${short(findCmds(loadUps), 300)}`);
  await turn('q4-with-load', sid4, '/probe-skill');

  step = 'q4-new-session';
  const s5 = await rpc('session/new', { cwd, mcpServers: [] });
  const sid5 = s5.result?.sessionId;
  await sleep(1500);
  log(`q4 fresh session/new commands: ${short(findCmds(updatesSince(0, sid5)), 400)}`);

  }
  // --- session/close ---------------------------------------------------------------
  if (want('close')) {
  log('--- session/close (D-032 verify)');
  step = 'close';
  const c = await rpc('session/close', { sessionId: sid4 });
  log(`session/close {sessionId} -> ${c.error ? `ERROR ${short(c.error, 300)}` : `ok ${short(c.result, 200)}`}`);
  await sleep(500);
  start = events.length;
  const lc = await rpc('session/load', { sessionId: sid4, cwd, mcpServers: [] });
  await sleep(1200);
  log(`session/load of the closed session -> ${lc.error ? `ERROR ${short(lc.error, 300)}` : 'ok'}; replayed updates: ${updatesSince(start, sid4).length}`);
  await turn('close-after-load', sid4, 'Reply with exactly: after-close.');
  const cc = await rpc('session/close', { sessionId: sid5 });
  log(`session/close on a second session -> ${cc.error ? `ERROR ${short(cc.error, 200)}` : 'ok'}`);
  }
} catch (err) {
  log(`ERROR ${err.stack ?? err}`);
} finally {
  bob.stdin.end();
  await sleep(500);
  bob.kill('SIGTERM');
  httpSrv.kill('SIGTERM');
  await sleep(800);
  if (!values.keep) await rm(base, { recursive: true, force: true }).catch(() => {});
  else log(`kept scratch folder: ${base}`);
  log(`done; events recorded: ${events.length}; scratch removed: ${!values.keep}`);
  process.exit(0);
}
