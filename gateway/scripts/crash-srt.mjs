#!/usr/bin/env node
// Crash and orphan check for the srt runner (docs/research/srt-test-plan.md, item 2).
// Starts the gateway with runner.kind "srt", opens a project's agent, kills the gateway the hard way,
// lists what survives (processes whose command line names the scratch folder), then starts a second
// gateway on the same state and opens the same project. It never prints BOB_API_KEY.
//   node gateway/scripts/crash-srt.mjs [--srt PATH] [--how kill9|term|srt9|busy9]
// kill9: SIGKILL the gateway. term: SIGTERM. srt9: SIGKILL only the srt process. busy9, busyterm,
// busystop: kill the gateway (SIGKILL, SIGTERM) or stop the agent through the API while a shell
// command is running in a turn.
import { mkdir, realpath, rm, writeFile } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { parseArgs } from 'node:util';
import { randomBytes } from 'node:crypto';
import WebSocket from 'ws';
import { hashToken, spawnGateway } from '../test/helpers.mjs';

const { values } = parseArgs({ options: {
  srt: { type: 'string', default: '/tmp/srt-prefix/bin/srt' },
  how: { type: 'string', default: 'kill9' },
  domains: { type: 'string', default: 'api.us-east.bob.ibm.com,bob.ibm.com,iam.cloud.ibm.com' },
} });
if (!process.env.BOB_API_KEY) { console.error('BOB_API_KEY is not set'); process.exit(2); }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const results = [];
const check = (name, ok, detail = '') => { results.push({ name, ok }); console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? `  (${detail})` : ''}`); };

const base = join(homedir(), '.acpcode-live', `crash-${values.how}-${Date.now()}`);
await mkdir(join(base, 'root', 'proj'), { recursive: true });
const root = await realpath(join(base, 'root'));
const project = join(root, 'proj');
await writeFile(join(project, 'README.md'), 'crash test\n');
const token = randomBytes(24).toString('base64url');
const bobArgs = ['acp', '--accept-license', '--log-level', 'warn'];
const config = {
  listen: { host: '127.0.0.1', port: 0 },
  trustProxy: false,
  tokens: [{ id: 'live', identity: 'owner', sha256: hashToken(token) }],
  agent: { command: [execFileSync('/usr/bin/which', ['bob'], { encoding: 'utf8' }).trim(), ...bobArgs], envPassthrough: ['PATH', 'LANG', 'BOB_API_KEY'] },
  projects: { roots: [root] },
  stateDir: join(base, 'state'),
  runner: { kind: 'srt', srt: values.srt, allowedDomains: values.domains.split(','), allowRead: ['/opt/homebrew', '/usr/local'] },
  limits: { idleSeconds: 600 },
};

/** All processes below pid (children, grandchildren, ...), from one `ps` listing. */
const descendants = (root) => {
  const rows = execFileSync('/bin/ps', ['-axo', 'pid=,ppid=,command='], { encoding: 'utf8' }).split('\n').map((l) => l.trim().match(/^(\d+)\s+(\d+)\s+(.*)$/)).filter(Boolean)
    .map((m) => ({ pid: Number(m[1]), ppid: Number(m[2]), cmd: m[3] }));
  const out = []; const todo = [root];
  while (todo.length) { const p = todo.pop(); for (const r of rows) if (r.ppid === p) { out.push(r); todo.push(r.pid); } }
  return out;
};
const alive = (pid) => { try { process.kill(pid, 0); return true; } catch { return false; } };
// Pids seen under the gateway at the time of the kill; survivors() is the subset still alive.
let tracked = [];
const survivors = () => tracked.filter((r) => alive(r.pid)).map((r) => `${r.pid} ${r.ppid} ${r.cmd}`);
const lockHolders = () => { try { return execFileSync('/bin/sh', ['-c', `lsof -t ${join(base, 'state', 'homes')}/*/.acpcode.lock 2>/dev/null`], { encoding: 'utf8' }).split('\n').filter(Boolean); } catch { return []; } };

let nextId = 1;
function client(gw) {
  const ws = new WebSocket(gw.url, { headers: { Authorization: `Bearer ${token}` }, perMessageDeflate: false });
  const c = { ws, pending: new Map(), events: [] };
  c.ready = new Promise((res, rej) => { ws.once('open', res); ws.once('error', rej); });
  ws.on('message', (d) => {
    const m = JSON.parse(d.toString());
    if (m.id !== undefined && m.method === undefined && c.pending.has(m.id)) { c.pending.get(m.id)(m); c.pending.delete(m.id); }
    else if (m.method === '_acpcode/event') c.events.push(m.params);
  });
  c.rpc = (method, params, ms = 120_000) => new Promise((resolve) => {
    const id = nextId++;
    const t = setTimeout(() => { c.pending.delete(id); resolve({ error: { message: `${method}: timeout` } }); }, ms);
    c.pending.set(id, (m) => { clearTimeout(t); resolve(m); });
    ws.send(JSON.stringify({ jsonrpc: '2.0', id, method, params }));
  });
  return c;
}

let gw = await spawnGateway(config, { env: { ...process.env }, replaceEnv: true, configDir: base });
let gw2;
try {
  const a = client(gw);
  await a.ready;
  const created = await a.rpc('_acpcode/projects/create', { name: 'crash', path: project });
  check('project registered', !!created.result?.project?.id);
  await a.rpc('initialize', { protocolVersion: 1, clientCapabilities: {} });
  const sess = await a.rpc('session/new', { cwd: project, mcpServers: [] });
  const sid = sess.result?.sessionId;
  check('agent started under srt', !!sid);
  await a.rpc('_acpcode/sessions/subscribe', { sessionId: sid, afterSeq: 0 });
  tracked = descendants(gw.pid);
  const running = survivors();
  check('sandboxed processes are running', running.some((l) => /bob/.test(l)) && running.some((l) => /node.*bob|bob\.js|bob acp/.test(l)), `${running.length} processes: ${tracked.map((r) => r.cmd.split(' ')[0].split('/').pop()).join(',')}`);

  if (values.how.startsWith('busy')) {
    // A turn that runs a long shell command: the permission is answered by this script.
    a.ws.on('message', async (d) => {
      const m = JSON.parse(d.toString())?.params?.message;
      if (m?.method !== 'session/request_permission') return;
      const opt = (m.params.options ?? []).find((o) => o.kind === 'allow_once');
      await a.rpc('_acpcode/approvals/answer', { approvalId: m.id, optionId: opt.optionId });
    });
    a.rpc('session/prompt', { sessionId: sid, prompt: [{ type: 'text', text: 'Run the shell command `sleep 300` and wait for it. Do nothing else.' }] }, 300_000);
    for (let i = 0; i < 90 && !descendants(gw.pid).some((r) => r.cmd.includes('sleep 300')); i++) await sleep(1000);
    tracked = descendants(gw.pid);
    check('a long command is running in the sandbox', tracked.some((r) => r.cmd.includes('sleep 300')));
  }

  tracked = descendants(gw.pid);
  const pids = tracked.map((r) => r.pid);
  console.log("pgids: " + execFileSync("/bin/ps", ["-o", "pid=,pgid=,ppid=,command=", "-p", pids.join(",")], { encoding: "utf8" }).split("\n").map((l) => l.trim().slice(0, 60)).join(" | "));
  const srtPid = tracked.find((r) => r.cmd.includes('srt-prefix/bin/srt') || /\bsrt -s\b/.test(r.cmd))?.pid;
  console.log(`tree before kill: ${tracked.map((r) => `${r.pid}<-${r.ppid} ${r.cmd.slice(0, 50)}`).join(' | ')}`);
  const t0 = Date.now();
  if (values.how === 'busyterm') process.kill(gw.pid, 'SIGTERM');
  else if (values.how === 'busystop') { const r = await a.rpc('_acpcode/sessions/stop', { sessionId: sid, scope: 'agent', force: true }, 30_000); console.log(`stop -> ${JSON.stringify(r.error ?? r.result).slice(0, 200)}`); }
  else if (values.how === 'term') process.kill(gw.pid, 'SIGTERM');
  else if (values.how === 'srt9') process.kill(Number(srtPid), 'SIGKILL');
  else process.kill(gw.pid, 'SIGKILL');
  console.log(`killed (${values.how}); gateway pid ${gw.pid}, srt pid ${srtPid}, ${pids.length} processes before`);

  // Give orphans time to notice a closed pipe, then list who is left.
  let left = survivors();
  for (let i = 0; i < 20 && left.length; i++) { await sleep(500); left = survivors(); }
  const secs = ((Date.now() - t0) / 1000).toFixed(1);
  console.log(`after ${secs}s survivors: ${left.length}`);
  for (const l of left) console.log(`  ${l.slice(0, 200)}`);
  // A hard kill (kill9, busy9) cannot run gateway code, so a command Bob detached into its own
  // process group may live on until the project's next start reaps it; that is reported, and the
  // check that counts is the one after the restart. A clean stop or a SIGTERM must leave nothing.
  const hard = values.how === 'kill9' || values.how === 'busy9' || values.how === 'srt9';
  if (hard) console.log(`${left.length ? 'NOTE' : 'ok  '} after a hard kill ${left.length} command(s) survived ${secs}s (reaped at the next start)`);
  else check(`no sandboxed process survives ${values.how}`, left.length === 0, `${left.length} left after ${secs}s`);
  console.log(`lock holders: ${lockHolders().join(',') || 'none'}`);
  console.log(`srt mux sockets: ${execFileSync('/bin/sh', ['-c', 'ls /var/folders/*/*/T/srt-mux-* 2>/dev/null | wc -l'], { encoding: 'utf8' }).trim()}`);

  // Restart on the same state and open the same project.
    if (values.how === 'srt9' || values.how === 'busystop') { await sleep(1500); }
  gw2 = (values.how === 'srt9' || values.how === 'busystop') ? gw : await spawnGateway(config, { env: { ...process.env }, replaceEnv: true, configDir: base });
  const b = client(gw2);
  await b.ready;
  await b.rpc('initialize', { protocolVersion: 1, clientCapabilities: {} });
  const again = await b.rpc('session/new', { cwd: project, mcpServers: [] });
  check('a new gateway can start the project again', !!again.result?.sessionId, again.error ? JSON.stringify(again.error).slice(0, 200) : '');
  await sleep(1500);
  check('after the restart no leftover command from the killed run is alive', tracked.filter((r) => alive(r.pid) && !/bob acp|srt -s|srt-prefix/.test(r.cmd)).length === 0, tracked.filter((r) => alive(r.pid) && !/bob acp|srt -s|srt-prefix/.test(r.cmd)).map((r) => r.cmd.slice(0, 40)).join(','));
  const audits = (gw2.audit ?? []).filter((e) => /agent_error|locked/.test(`${e.event}${e.reason ?? ''}`));
  if (audits.length) console.log(`audit: ${JSON.stringify(audits).slice(0, 300)}`);
} catch (e) {
  check('script completed', false, String(e.message ?? e).slice(0, 300));
} finally {
  for (const g of [gw2, gw]) { try { await g?.stop(); } catch { /* gone */ } }
  await sleep(1500);
  const rest = survivors();
  if (rest.length) { console.log(`cleanup: ${rest.length} leftover processes, killing`); for (const l of rest) { try { process.kill(Number(l.split(/\s+/)[0]), 'SIGKILL'); } catch { /* gone */ } } }
  await rm(base, { recursive: true, force: true });
  const failed = results.filter((r) => !r.ok);
  console.log(`SUMMARY crash ${values.how}: ${results.length - failed.length}/${results.length} passed${failed.length ? `; failed: ${failed.map((f) => f.name).join(' | ')}` : ''}`);
  process.exit(failed.length ? 1 : 0);
}
