#!/usr/bin/env node
// Soak test for the srt runner (docs/research/srt-test-plan.md, item 6). Real Bob, real gateway.
//   node gateway/scripts/soak-srt.mjs [--turns 30] [--cycles 5] [--projects 1] [--minutes 0] [--every 180]
//                                     [--srt PATH] [--domains a,b,c] [--long-seconds 0]
// Phase 1 (always): one project, one session, --turns turns that edit files, run shell commands and
//   run a test; approvals are answered by this script. Every --cycles-th turn the agent is stopped
//   (idle stop) and the next turn resumes it. Git calls (status, turnDiff) run on every turn and are timed.
// Phase 2 (--minutes > 0): --projects projects, one turn every --every seconds each, for that long.
// Phase 3 (--long-seconds > 0): one turn whose shell command sleeps that long; it must not be killed.
// Every 30 s a sample is taken: RSS of the gateway's process tree, its open descriptors, the count of
// srt-mux sockets, the files in <stateDir>/srt, and the Seatbelt denials. It never prints BOB_API_KEY.
import { mkdir, readdir, realpath, rm, writeFile } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import { parseArgs } from 'node:util';
import { randomBytes } from 'node:crypto';
import WebSocket from 'ws';
import { hashToken, spawnGateway } from '../test/helpers.mjs';

const { values } = parseArgs({ options: {
  srt: { type: 'string', default: '/tmp/srt-prefix/bin/srt' },
  domains: { type: 'string', default: 'api.us-east.bob.ibm.com,bob.ibm.com,iam.cloud.ibm.com' },
  turns: { type: 'string', default: '30' },
  cycles: { type: 'string', default: '5' },
  projects: { type: 'string', default: '2' },
  minutes: { type: 'string', default: '0' },
  every: { type: 'string', default: '180' },
  'long-seconds': { type: 'string', default: '0' },
  'sample-seconds': { type: 'string', default: '30' },
  host: { type: 'boolean', default: false },
} });
if (!process.env.BOB_API_KEY) { console.error('BOB_API_KEY is not set'); process.exit(2); }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);
const results = [];
const check = (name, ok, detail = '') => { results.push({ name, ok }); log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? `  (${detail})` : ''}`); };
const pct = (xs, p) => { if (!xs.length) return NaN; const s = [...xs].sort((a, b) => a - b); return s[Math.min(s.length - 1, Math.ceil((p / 100) * s.length) - 1)]; };

const base = join(homedir(), '.acpcode-live', `soak-${Date.now()}`);
const nProjects = Math.max(1, Number(values.projects));
await mkdir(join(base, 'root'), { recursive: true });
const root = await realpath(join(base, 'root'));
const projectPaths = [];
for (let i = 0; i < nProjects; i++) {
  const p = join(root, `proj${i}`);
  await mkdir(p, { recursive: true });
  const git = (...a) => execFileSync('git', a, { cwd: p, env: { ...process.env, GIT_AUTHOR_NAME: 't', GIT_AUTHOR_EMAIL: 't@t', GIT_COMMITTER_NAME: 't', GIT_COMMITTER_EMAIL: 't@t' } });
  git('init', '-q', '-b', 'main');
  await writeFile(join(p, 'README.md'), 'soak test project\n');
  await writeFile(join(p, 'add.js'), 'exports.add = (a, b) => a + b;\n');
  await writeFile(join(p, 'add.test.js'), "const test = require('node:test');\nconst assert = require('node:assert');\nconst { add } = require('./add');\ntest('add', () => assert.strictEqual(add(1, 2), 3));\n");
  git('add', '.');
  git('commit', '-q', '-m', 'init');
  projectPaths.push(p);
}
const token = randomBytes(24).toString('base64url');
const idleSeconds = 6;
const config = {
  listen: { host: '127.0.0.1', port: 0 },
  trustProxy: false,
  tokens: [{ id: 'soak', identity: 'owner', sha256: hashToken(token) }],
  agent: { command: [execFileSync('/usr/bin/which', ['bob'], { encoding: 'utf8' }).trim(), 'acp', '--accept-license', '--log-level', 'warn'], envPassthrough: ['PATH', 'LANG', 'BOB_API_KEY'] },
  projects: { roots: [root] },
  stateDir: join(base, 'state'),
  runner: values.host ? { kind: 'host', allowHost: true } : { kind: 'srt', srt: values.srt, allowedDomains: values.domains.split(','), allowRead: ['/opt/homebrew', '/usr/local'] },
  limits: { idleSeconds },
};
const gw = await spawnGateway(config, { env: { ...process.env }, replaceEnv: true, configDir: base });
const audit = gw.audit;

let nextId = 1;
function client() {
  const ws = new WebSocket(gw.url, { headers: { Authorization: `Bearer ${token}` }, perMessageDeflate: false });
  const c = { ws, pending: new Map(), events: [], onEvent: null };
  c.ready = new Promise((res, rej) => { ws.once('open', res); ws.once('error', rej); });
  ws.on('message', (data) => {
    const msg = JSON.parse(data.toString());
    if (msg.id !== undefined && msg.method === undefined && c.pending.has(msg.id)) { c.pending.get(msg.id)(msg); c.pending.delete(msg.id); }
    else if (msg.method === '_acpcode/event') { c.events.push(msg.params); c.onEvent?.(msg.params); }
  });
  c.rpc = (method, params, ms = 600_000) => new Promise((resolve) => {
    const id = nextId++;
    const t = setTimeout(() => { c.pending.delete(id); resolve({ error: { code: 'timeout', message: `${method}: no response in ${ms} ms` } }); }, ms);
    c.pending.set(id, (m) => { clearTimeout(t); resolve(m); });
    ws.send(JSON.stringify({ jsonrpc: '2.0', id, method, params }));
  });
  return c;
}
/** Approve every permission request (this is a soak of the sandbox, not of the approval policy). */
function approveAll(c) {
  c.onEvent = async (ev) => {
    const m = ev.message;
    if (m?.method !== 'session/request_permission') return;
    const opt = (m.params.options ?? []).find((o) => o.kind === 'allow_once') ?? (m.params.options ?? [])[0];
    await sleep(150);
    await c.rpc('_acpcode/approvals/answer', opt ? { approvalId: m.id, optionId: opt.optionId } : { approvalId: m.id, cancelled: true }, 30_000);
  };
}

// --- sampling ------------------------------------------------------------------
const samples = [];
const gitTimes = [];
function tree(rootPid) {
  const rows = execFileSync('ps', ['-axo', 'pid=,ppid=,rss='], { encoding: 'utf8' }).split('\n').map((l) => l.trim().split(/\s+/).map(Number)).filter((r) => r.length === 3);
  const seen = new Map(); const todo = [rootPid];
  while (todo.length) { const p = todo.pop(); const self = rows.find((r) => r[0] === p); if (self && !seen.has(p)) seen.set(p, self); for (const r of rows) if (r[1] === p && !seen.has(r[0])) { seen.set(r[0], r); todo.push(r[0]); } }
  return [...seen.values()];
}
const fdCount = (pids) => { try { return execFileSync('/bin/sh', ['-c', `lsof -p ${pids.join(',')} 2>/dev/null | wc -l`], { encoding: 'utf8' }).trim() * 1; } catch { return NaN; } };
const muxSockets = () => { try { return execFileSync('/bin/sh', ['-c', 'ls /var/folders/*/*/T/srt-mux-*.sock 2>/dev/null | wc -l'], { encoding: 'utf8' }).trim() * 1; } catch { return NaN; } };
const denials = (since) => {
  try {
    const out = execFileSync('/usr/bin/log', ['show', '--start', since, '--style', 'compact', '--predicate', 'sender == "Sandbox" AND eventMessage CONTAINS "deny"'], { encoding: 'utf8', timeout: 20_000 });
    return out.split('\n').filter((l) => /deny/.test(l));
  } catch { return []; }
};
const startedAt = new Date();
const stamp = (d) => d.toISOString().replace('T', ' ').slice(0, 19);
let sampling = true;
const sampler = (async () => {
  while (sampling) {
    const procs = tree(gw.pid);
    const pids = procs.map((r) => r[0]);
    const s = { t: Date.now(), up: procs.length > 1, rssMiB: procs.reduce((t, r) => t + r[2], 0) / 1024, procs: procs.length, fds: fdCount(pids), mux: muxSockets(), settings: (await readdir(join(base, 'state', 'srt')).catch(() => [])).length };
    samples.push(s);
    for (let i = 0; i < Number(values['sample-seconds']) && sampling; i++) await sleep(1000);
  }
})();

// --- helpers -------------------------------------------------------------------
async function openProject(a, i) {
  const created = await a.rpc('_acpcode/projects/create', { name: `soak${i}`, path: projectPaths[i] });
  const id = created.result?.project?.id;
  const res = await a.rpc('session/new', { cwd: projectPaths[i], mcpServers: [] });
  if (!res.result?.sessionId) throw new Error(`session/new ${i}: ${JSON.stringify(res.error)}`);
  await a.rpc('_acpcode/sessions/subscribe', { sessionId: res.result.sessionId, afterSeq: 0 });
  return { projectId: id, sid: res.result.sessionId, path: projectPaths[i], turns: 0 };
}
const prompts = (n) => [
  `Create a file named note-${n}.txt in the current directory containing the line: turn ${n}. Use your file editing tool. Then say done.`,
  'Run the shell command `node --test` and tell me in one line whether the tests passed.',
  `Run the shell command \`echo marker-${n} >> log.txt && wc -l log.txt\` and tell me the result.`,
  'Edit add.js so that it also exports a function sub(a, b) that returns a - b. Then say done.',
];
async function turn(a, pr, text) {
  const t0 = Date.now();
  const r = await a.rpc('session/prompt', { sessionId: pr.sid, prompt: [{ type: 'text', text }] }, 900_000);
  pr.turns++;
  let g = Date.now();
  const st = await a.rpc('_acpcode/git/status', { projectId: pr.projectId }, 30_000);
  gitTimes.push(Date.now() - g);
  g = Date.now();
  const td = await a.rpc('_acpcode/git/turnDiff', { sessionId: pr.sid, turn: pr.turns }, 30_000);
  gitTimes.push(Date.now() - g);
  const evs = a.events.filter((e) => e.sessionId === pr.sid);
  const said = evs.filter((e) => e.message?.params?.update?.sessionUpdate === 'agent_message_chunk').map((e) => e.message.params.update.content?.text ?? '').join('').slice(-200);
  const tools = evs.filter((e) => e.message?.params?.update?.sessionUpdate === 'tool_call').map((e) => e.message.params.update.title).slice(-3);
  return { ok: r.result?.stopReason === 'end_turn', ms: Date.now() - t0, err: r.error, gitErr: st.error ?? td.error, said, tools };
}

try {
  let a = client();
  await a.ready;
  approveAll(a);

  // Phase 1: one project, N turns, with idle stop and resume every few turns.
  const p0 = await openProject(a, 0);
  const total = Number(values.turns);
  const cycleEvery = Math.max(1, Number(values.cycles) > 0 ? Math.floor(total / (Number(values.cycles) + 1)) : total + 1);
  let ended = 0, failed = 0, resumes = 0, resumeFail = 0;
  const turnMs = [];
  for (let n = 1; n <= total; n++) {
    const r = await turn(a, p0, prompts(n)[n % 4]);
    if (r.ok) { ended++; turnMs.push(r.ms); } else { failed++; log(`turn ${n} failed: ${JSON.stringify(r.err)?.slice(0, 200)}`); }
    if (r.gitErr) log(`git call error on turn ${n}: ${JSON.stringify(r.gitErr).slice(0, 160)}`);
    if (n % 5 === 0) log(`turn ${n}/${total} ok ${ended} failed ${failed}; last ${r.ms} ms`);
    if (n % cycleEvery === 0 && n < total && resumes < Number(values.cycles)) {
      // The gateway never idle-stops an agent that has a subscriber: drop the connection first.
      const idleBefore = audit.filter((x) => x.event === 'agent_idle_stop').length;
      a.ws.close();
      await gw.waitForAudit((x) => x.event === 'agent_idle_stop' && audit.filter((y) => y.event === 'agent_idle_stop').length > idleBefore, (idleSeconds * 2 + 30) * 1000).catch(() => {});
      let leftRows = tree(gw.pid).filter((r2) => r2[0] !== gw.pid);
      for (let k = 0; k < 16 && leftRows.length; k++) { await sleep(500); leftRows = tree(gw.pid).filter((r2) => r2[0] !== gw.pid); }
      const names = execFileSync('ps', ['-o', 'pid=,ppid=,command=', '-p', leftRows.map((r2) => r2[0]).join(',') || '1'], { encoding: 'utf8' }).split('\n').filter(Boolean).map((l) => l.trim().slice(0, 110));
      if (leftRows.length) log(`  left after idle stop: ${names.join(' || ')}`);
      const leftover = leftRows.length;
      const stopped = audit.filter((x) => x.event === 'agent_idle_stop').length > idleBefore;
      const startsBefore = audit.filter((x) => x.event === 'agent_start').length;
      a = client();
      await a.ready;
      approveAll(a);
      await a.rpc('_acpcode/sessions/subscribe', { sessionId: p0.sid, afterSeq: 9999 });
      const q = await turn(a, p0, 'Reply with exactly the word: pong. Do not use any tools.');
      const restarted = audit.filter((x) => x.event === 'agent_start').length === startsBefore + 1;
      resumes++;
      if (!(stopped && leftover === 0 && q.ok && restarted)) { resumeFail++; log(`resume ${resumes}: idle stop ${stopped}, processes left after it ${leftover}, new agent started ${restarted}, turn ok ${q.ok}`); }
      else log(`resume ${resumes}: idle stop fired, no process left, next turn ok in ${q.ms} ms`);
    }
  }
  check(`phase 1: ${total} turns end_turn`, failed === 0, `${ended} ok, ${failed} failed; turn median ${pct(turnMs, 50)} ms p95 ${pct(turnMs, 95)} ms`);
  check(`phase 1: ${resumes} idle stop and resume cycles`, resumes >= Number(values.cycles) && resumeFail === 0, `${resumeFail} failed`);
  const hist = await a.rpc('session/load', { sessionId: p0.sid, cwd: p0.path, mcpServers: [] }, 60_000);
  check('phase 1: the session still loads after all cycles', !hist.error, hist.error ? JSON.stringify(hist.error) : '');

  // Phase 3: a long turn must not be killed.
  if (Number(values['long-seconds']) > 0) {
    const s = Number(values['long-seconds']);
    const r = await turn(a, p0, `Run this shell command in the foreground and wait until it ends (do not run it in the background, do not poll it): \`for i in $(seq 1 ${Math.ceil(s / 10)}); do sleep 10; echo tick-$i; done; echo long-done\`. Then tell me the last line it printed.`);
    log(`  long turn: tools ${JSON.stringify(r.tools)}; agent said: ${r.said.replace(/\s+/g, ' ')}`);
    check(`long turn (${s} s command) is not killed`, r.ok && r.ms > s * 1000, `${r.ms} ms ${r.err ? JSON.stringify(r.err).slice(0, 120) : ''}`);
  }

  // Phase 2: N projects at once, one turn every --every seconds each.
  if (Number(values.minutes) > 0) {
    const ps = [p0];
    for (let i = 1; i < nProjects; i++) ps.push(await openProject(a, i));
    const until = Date.now() + Number(values.minutes) * 60_000;
    let rounds = 0, bad = 0;
    log(`phase 2: ${ps.length} projects for ${values.minutes} minutes, a turn per project every ${values.every} s`);
    while (Date.now() < until) {
      const t0 = Date.now();
      const rs = await Promise.all(ps.map((p, i) => turn(a, p, prompts(rounds * 7 + i)[(rounds + i) % 4])));
      rounds++;
      bad += rs.filter((r) => !r.ok).length;
      if (rounds % 3 === 0) log(`phase 2 round ${rounds}: ${rs.map((r) => `${r.ms}ms${r.ok ? '' : ' FAILED'}`).join(' ')}`);
      const wait = Number(values.every) * 1000 - (Date.now() - t0);
      if (wait > 0) await sleep(Math.min(wait, Math.max(0, until - Date.now())));
    }
    check(`phase 2: ${rounds} rounds on ${ps.length} projects`, bad === 0, `${bad} failed turns`);
  }
} catch (e) {
  check('soak ran to the end', false, e.message);
} finally {
  sampling = false;
  await sampler;
  // Leave out the warm-up: the first samples are taken before the first agent exists.
  const warm = samples.filter((x) => x.up).slice(Math.ceil(samples.filter((x) => x.up).length * 0.2));
  const rss = warm.map((s) => s.rssMiB);
  const fds = warm.map((s) => s.fds).filter((x) => !Number.isNaN(x));
  const third = Math.max(1, Math.floor(warm.length / 3));
  const avg = (xs) => xs.reduce((t, x) => t + x, 0) / Math.max(1, xs.length);
  log(`samples ${samples.length} (${warm.length} after warm-up); RSS MiB first third ${avg(rss.slice(0, third)).toFixed(0)}, last third ${avg(rss.slice(-third)).toFixed(0)}, max ${Math.max(...samples.map((s) => s.rssMiB)).toFixed(0)}`);
  log(`descriptors: first third ${avg(fds.slice(0, third)).toFixed(0)}, last third ${avg(fds.slice(-third)).toFixed(0)}, max ${Math.max(...fds)}`);
  log(`srt-mux sockets: ${samples[0]?.mux} at start, ${samples.at(-1)?.mux} at end; <stateDir>/srt files max ${Math.max(...samples.map((s) => s.settings))}`);
  log(`git call time (status + turnDiff): n ${gitTimes.length}, median ${pct(gitTimes, 50)} ms, p95 ${pct(gitTimes, 95)} ms, max ${Math.max(...gitTimes)} ms`);
  const timeouts = audit.filter((r) => /git.*timeout|snapshot.*(fail|timeout)/i.test(JSON.stringify(r)));
  check('no git timeout or snapshot failure in the audit log', timeouts.length === 0, timeouts.slice(0, 2).map((r) => JSON.stringify(r).slice(0, 160)).join(' | '));
  check('git calls stay under the 5 s limit', Math.max(...gitTimes, 0) < 5000, `max ${Math.max(...gitTimes, 0)} ms`);
  if (warm.length >= 6) {
    const growth = avg(rss.slice(-third)) / Math.max(1, avg(rss.slice(0, third)));
    check('RSS levels off (last third under 1.5x the first third)', growth < 1.5, `${growth.toFixed(2)}x`);
    const fgrowth = avg(fds.slice(-third)) / Math.max(1, avg(fds.slice(0, third)));
    check('descriptors level off (last third under 1.5x the first third)', fgrowth < 1.5, `${fgrowth.toFixed(2)}x`);
  } else log('too few samples to judge RSS and descriptor trends');
  const muxGrowth = (samples.at(-1)?.mux ?? 0) - (samples[0]?.mux ?? 0);
  check('no srt-mux socket is left behind by the run', muxGrowth <= 0, `${muxGrowth} new`);
  const d = denials(stamp(startedAt));
  const kinds = new Map();
  for (const l of d) { const m = l.match(/deny\(\d+\)\s+(\S+)\s+(\S.*)$/); const k = m ? `${m[1]} ${m[2].replace(/\/[^ ]*\/(?=[^/ ]+$)/, '…/')}` : l.slice(-80); kinds.set(k, (kinds.get(k) ?? 0) + 1); }
  log(`Seatbelt denials in the window: ${d.length}; distinct: ${kinds.size}`);
  for (const [k, n] of [...kinds].sort((x, y) => y[1] - x[1]).slice(0, 15)) log(`  ${n}x ${k.slice(0, 160)}`);
  await gw.stop().catch(() => {});
  await sleep(1500);
  const left = execFileSync('ps', ['-axo', 'pid=,command='], { encoding: 'utf8' }).split('\n').filter((l) => l.includes(base));
  check('no process of the soak is left after the gateway stops', left.length === 0, left.slice(0, 2).join(' | ').slice(0, 160));
  const failedChecks = results.filter((r) => !r.ok);
  log(`SUMMARY soak-srt: ${results.length - failedChecks.length}/${results.length} passed`);
  await rm(base, { recursive: true, force: true }).catch(() => {});
  process.exit(failedChecks.length ? 1 : 0);
}
