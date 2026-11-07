#!/usr/bin/env node
// Concurrent Bob sessions: N containers at once on one runtime, each with its own home and project
// folder (the gateway's layout, one container per project, D-008). Measures, per container: load of
// an existing session, and one short prompt; and the host memory the runtime holds while they run.
// Runtime: Apple `container` (D-079) or Podman with the gateway's flags (--userns=keep-id, D-051).
// Talks ACP over stdio to each `bob acp`. BOB_API_KEY must be in the environment; it is never printed.
// Usage: node gateway/scripts/bench-concurrent.mjs --runner apple|podman --image IMG [--counts 1,2,4,8] [--dns 1.1.1.1]
import { spawn, execFileSync } from 'node:child_process';
import { mkdtemp, mkdir, realpath, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { parseArgs } from 'node:util';
import { randomBytes } from 'node:crypto';

const { values } = parseArgs({
  options: {
    runner: { type: 'string', default: 'apple' },
    image: { type: 'string', default: 'localhost/agmente-bob:2.0.9' },
    counts: { type: 'string', default: '1,2,4,8' },
    dns: { type: 'string', default: '' },
  },
});
if (!process.env.BOB_API_KEY) { console.error('BOB_API_KEY is not set'); process.exit(2); }
const apple = values.runner === 'apple';
if (!apple && values.runner !== 'podman') { console.error('--runner must be apple or podman'); process.exit(2); }
const CLI = apple ? 'container' : 'podman';
const BOB_ARGS = ['acp', '--accept-license', '--log-level', 'warn'];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const pct = (xs, p) => { const s = [...xs].sort((a, b) => a - b); return s[Math.min(s.length - 1, Math.ceil((p / 100) * s.length) - 1)]; };
const tag = randomBytes(3).toString('hex');
const cname = (i) => `agmente-conc-${tag}-${i}`;

/** An ACP client over one agent process's stdio. */
function startAgent(args) {
  const child = spawn(CLI, args, { stdio: ['pipe', 'pipe', 'pipe'], env: process.env });
  let buf = '';
  let nextId = 1;
  const pending = new Map();
  let stderr = '';
  child.stdout.on('data', (d) => {
    buf += d.toString();
    let i;
    while ((i = buf.indexOf('\n')) !== -1) {
      const line = buf.slice(0, i);
      buf = buf.slice(i + 1);
      let msg;
      try { msg = JSON.parse(line); } catch { continue; }
      if (msg.id !== undefined && msg.method === undefined && pending.has(msg.id)) {
        pending.get(msg.id)(msg);
        pending.delete(msg.id);
      } else if (msg.id !== undefined && msg.method !== undefined) {
        child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id: msg.id, error: { code: -32601, message: 'bench' } })}\n`);
      }
    }
  });
  child.stderr.on('data', (d) => { stderr += d.toString(); });
  const exited = new Promise((r) => child.once('exit', (code) => r(code)));
  const rpc = (method, params) => new Promise((resolve, reject) => {
    const id = nextId++;
    pending.set(id, resolve);
    child.once('exit', () => reject(new Error(`agent exited during ${method}: ${stderr.slice(-300)}`)));
    child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id, method, params })}\n`);
  });
  const stop = async () => { child.stdin.end(); child.kill('SIGTERM'); await Promise.race([exited, sleep(5000)]); };
  return { rpc, stop, stderr: () => stderr };
}

/** Host memory: the runtime's processes, and the Virtualization VMs (Apple) or the libkrun VM (Podman). */
function rssProcs() {
  const pattern = apple
    ? /container-runtime-linux|container-apiserver|container-network|container-core-images|machine-apiserver|Virtualization\.VirtualMachine/
    : /gvproxy|krunkit|podman/;
  const out = execFileSync('ps', ['-axo', 'pid=,rss=,command='], { encoding: 'utf8' });
  const procs = [];
  for (const line of out.split('\n')) {
    const m = line.trim().match(/^(\d+)\s+(\d+)\s+(.*)$/);
    if (m && pattern.test(m[3]) && !m[3].includes('bench-concurrent')) procs.push({ pid: Number(m[1]), mib: Number(m[2]) / 1024 });
  }
  return procs;
}
const sum = (ps) => ps.reduce((t, p) => t + p.mib, 0);

async function runFor(n, base) {
  const dirs = [];
  for (let i = 0; i < n; i++) {
    const home = join(base, `home-${i}`);
    const work = join(base, `work-${i}`);
    await mkdir(join(home, '.bob'), { recursive: true });
    await mkdir(work, { recursive: true });
    await writeFile(join(home, '.bob', 'trustedFolders.json'), JSON.stringify({ version: 1, folders: { '/work': 'TRUST_FOLDER' } }));
    dirs.push({ home, work });
  }
  const argsFor = (i) => {
    const { home, work } = dirs[i];
    if (apple) {
      return ['run', '-i', '--rm', '--progress', 'none', '--name', cname(i), '--init', '-u', '10001:10001',
        ...(values.dns ? ['--dns', values.dns] : []),
        '-e', 'HOME=/home/bob', '-e', 'BOB_API_KEY', '-v', `${home}:/home/bob`, '-v', `${work}:/work`, '-w', '/work', values.image, ...BOB_ARGS];
    }
    return ['run', '--rm', '-i', '--name', cname(i), '--pull=never', '--init', '--userns=keep-id:uid=10001,gid=10001', '--user', '10001:10001',
      '-e', 'HOME=/home/bob', '-e', 'BOB_API_KEY', '-v', `${home}:/home/bob`, '-v', `${work}:/work`, '-w', '/work', values.image, ...BOB_ARGS];
  };
  const seedText = 'Reply with exactly the word: pong. Do not use any tools.';
  const sessions = [];
  // Seed one session per container (a prompt makes Bob keep the session), one at a time.
  for (let i = 0; i < n; i++) {
    const a = startAgent(argsFor(i));
    await a.rpc('initialize', { protocolVersion: 1, clientCapabilities: {} });
    const created = await a.rpc('session/new', { cwd: '/work', mcpServers: [] });
    if (created.error) throw new Error(`seed ${i}: ${JSON.stringify(created.error)}`);
    const p = await a.rpc('session/prompt', { sessionId: created.result.sessionId, prompt: [{ type: 'text', text: seedText }] });
    if (p.error) throw new Error(`seed prompt ${i}: ${JSON.stringify(p.error)}`);
    sessions.push(created.result.sessionId);
    await a.stop();
    for (let t = 0; t < 100; t++) { if (!containerListed(cname(i))) break; await sleep(100); }
  }
  // Start all N at once: initialize, load the session, then one prompt each.
  const before = rssProcs();
  const beforePids = new Set(before.map((p) => p.pid));
  const agents = [];
  const t0 = performance.now();
  const timings = await Promise.allSettled(Array.from({ length: n }, async (_, i) => {
    const a = startAgent(argsFor(i));
    agents.push(a);
    const r = {};
    await a.rpc('initialize', { protocolVersion: 1, clientCapabilities: {} });
    r.initialize = performance.now() - t0;
    const load = await a.rpc('session/load', { sessionId: sessions[i], cwd: '/work', mcpServers: [] });
    if (load.error) throw new Error(`load ${i}: ${JSON.stringify(load.error)}`);
    r.load = performance.now() - t0;
    return r;
  }));
  // Memory while all N are up, after the replays settle.
  await sleep(2000);
  const during = rssProcs();
  const added = during.filter((p) => !beforePids.has(p.pid));
  // Turn latency: one prompt per container, all at once.
  const turnStart = performance.now();
  const turns = await Promise.allSettled(agents.map((a, i) => (async () => {
    const s = performance.now();
    const r = await a.rpc('session/prompt', { sessionId: sessions[i], prompt: [{ type: 'text', text: 'Reply with exactly the word: pong. Do not use any tools.' }] });
    if (r.error) throw new Error(`turn ${i}: ${JSON.stringify(r.error)}`);
    return performance.now() - s;
  })()));
  const turnMs = turns.filter((t) => t.status === 'fulfilled').map((t) => t.value);
  const failures = [
    ...timings.filter((t) => t.status === 'rejected').map((t) => t.reason.message),
    ...turns.filter((t) => t.status === 'rejected').map((t) => t.reason.message),
  ];
  for (const a of agents) await a.stop();
  for (let i = 0; i < n; i++) { try { execFileSync(CLI, apple ? ['delete', '--force', cname(i)] : ['rm', '-f', cname(i)], { stdio: 'ignore' }); } catch { /* gone */ } }
  const loads = timings.filter((t) => t.status === 'fulfilled').map((t) => t.value.load);
  return {
    n,
    ok: loads.length,
    loadMedian: loads.length ? pct(loads, 50) : NaN,
    loadMax: loads.length ? Math.max(...loads) : NaN,
    turnMedian: turnMs.length ? pct(turnMs, 50) : NaN,
    turnMax: turnMs.length ? Math.max(...turnMs) : NaN,
    totalRuntimeMiB: sum(during) - sum(before),
    addedMiB: sum(added),
    addedProcs: added.length,
    hostRuntimeAfterMiB: sum(during),
    failures,
  };
}

function containerListed(name) {
  try {
    return execFileSync(CLI, apple ? ['list', '--quiet'] : ['ps', '--format', '{{.Names}}'], { encoding: 'utf8' })
      .split('\n').map((l) => l.trim()).includes(name);
  } catch { return false; }
}

const base = await realpath(await mkdtemp(join(tmpdir(), 'agmente-conc-')));
const results = [];
try {
  if (apple) {
    // Apple: resolver as configured (the default did not answer on this Mac, D-080).
  } else {
    execFileSync('podman', ['image', 'exists', values.image]);
  }
  for (const n of values.counts.split(',').map(Number)) {
    const r = await runFor(n, base);
    results.push(r);
    console.log(`N=${r.n}: ${r.ok}/${r.n} loaded; load median ${r.loadMedian.toFixed(0)} ms max ${r.loadMax.toFixed(0)}; turn median ${r.turnMedian.toFixed(0)} ms max ${r.turnMax.toFixed(0)}; host runtime +${r.totalRuntimeMiB.toFixed(0)} MiB (new processes ${r.addedMiB.toFixed(0)} MiB in ${r.addedProcs}); runtime total ${r.hostRuntimeAfterMiB.toFixed(0)} MiB${r.failures.length ? `; failures: ${r.failures.map((f) => f.slice(0, 160)).join(' | ')}` : ''}`);
  }
} finally {
  for (const n of [8, 4, 2, 1]) for (let i = 0; i < n; i++) { try { execFileSync(CLI, apple ? ['delete', '--force', cname(i)] : ['rm', '-f', cname(i)], { stdio: 'ignore' }); } catch { /* gone */ } }
  await rm(base, { recursive: true, force: true });
}
console.log(JSON.stringify(results, null, 2));
