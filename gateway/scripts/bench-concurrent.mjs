#!/usr/bin/env node
// Concurrent Bob sessions: N containers at once on one runtime, each with its own home and project
// folder (the gateway's layout, one container per project, D-008). Measures, per container: load of
// an existing session, and one short prompt; and the host memory the runtime holds while they run.
// Runtime: Apple `container` (D-079), Podman with the gateway's flags (--userns=keep-id, D-051), or
// srt (Anthropic sandbox-runtime, D-122): one srt process per project with the settings the gateway
// writes for the agent; memory is the summed resident size of each srt process tree.
// Talks ACP over stdio to each `bob acp`. BOB_API_KEY must be in the environment; it is never printed.
// Usage: node gateway/scripts/bench-concurrent.mjs --runner apple|podman --image IMG [--counts 1,2,4,8] [--dns 1.1.1.1]
//        node gateway/scripts/bench-concurrent.mjs --runner srt [--srt /path/to/srt] [--counts 1,2,4,8] [--repeat 3]
import { spawn, execFileSync } from 'node:child_process';
import { mkdtemp, mkdir, realpath, rm, writeFile } from 'node:fs/promises';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import { parseArgs } from 'node:util';
import { randomBytes } from 'node:crypto';

const { values } = parseArgs({
  options: {
    runner: { type: 'string', default: 'apple' },
    image: { type: 'string', default: 'localhost/acpcode-bob:2.0.9' },
    counts: { type: 'string', default: '1,2,4,8' },
    dns: { type: 'string', default: '' },
    srt: { type: 'string', default: '/tmp/srt-prefix/bin/srt' },
    domains: { type: 'string', default: 'api.us-east.bob.ibm.com,bob.ibm.com,iam.cloud.ibm.com' },
    repeat: { type: 'string', default: '1' },
    bare: { type: 'boolean', default: false },
    path: { type: 'string', default: '' },
    stagger: { type: 'string', default: '0' },
  },
});
if (!process.env.BOB_API_KEY) { console.error('BOB_API_KEY is not set'); process.exit(2); }
const apple = values.runner === 'apple';
const srt = values.runner === 'srt';
if (!apple && !srt && values.runner !== 'podman') { console.error('--runner must be apple, podman or srt'); process.exit(2); }
const CLI = srt ? (values.bare ? '/usr/bin/env' : values.srt) : apple ? 'container' : 'podman';
const BOB_ARGS = ['acp', '--accept-license', '--log-level', 'warn'];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const pct = (xs, p) => { const s = [...xs].sort((a, b) => a - b); return s[Math.min(s.length - 1, Math.ceil((p / 100) * s.length) - 1)]; };
const tag = randomBytes(3).toString('hex');
const cname = (i) => `acpcode-conc-${tag}-${i}`;

/** An ACP client over one agent process's stdio. */
function startAgent(args, opts = {}) {
  const child = spawn(CLI, args, { stdio: ['pipe', 'pipe', 'pipe'], env: opts.env ?? process.env, cwd: opts.cwd });
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
  let exitCode;
  const exited = new Promise((r) => child.once('exit', (code, sig) => { exitCode = code ?? sig; r(code); }));
  const rpc = (method, params) => new Promise((resolve, reject) => {
    if (exitCode !== undefined) { reject(new Error(`agent had already exited (${exitCode}) before ${method}: ${stderr.slice(-400)}`)); return; }
    const id = nextId++;
    pending.set(id, resolve);
    const timer = setTimeout(() => reject(new Error(`no reply to ${method} in 120 s (pid ${child.pid}): ${stderr.slice(-300)}`)), 120000);
    timer.unref();
    child.once('exit', () => reject(new Error(`agent exited during ${method}: ${stderr.slice(-1500)}`)));
    child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id, method, params })}\n`);
  });
  const stop = async () => { child.stdin.end(); child.kill('SIGTERM'); await Promise.race([exited, sleep(5000)]); };
  return { rpc, stop, stderr: () => stderr, pid: child.pid };
}

/** srt: every process below the given pids (the srt process, its proxy, sh, bob and its children), with RSS. */
function treeProcs(roots) {
  const out = execFileSync('ps', ['-axo', 'pid=,ppid=,rss=,command='], { encoding: 'utf8' });
  const rows = [];
  for (const line of out.split('\n')) {
    const m = line.trim().match(/^(\d+)\s+(\d+)\s+(\d+)\s+(.*)$/);
    if (m) rows.push({ pid: Number(m[1]), ppid: Number(m[2]), mib: Number(m[3]) / 1024, cmd: m[4] });
  }
  const keep = new Map();
  const todo = [...roots];
  while (todo.length) {
    const pid = todo.pop();
    const self = rows.find((r) => r.pid === pid);
    if (self && !keep.has(pid)) keep.set(pid, self);
    for (const r of rows) if (r.ppid === pid && !keep.has(r.pid)) { keep.set(r.pid, r); todo.push(r.pid); }
  }
  return [...keep.values()];
}
/** `footprint` (the kernel's per-process physical footprint) for the pids, in MiB. NaN if it cannot be read. */
function footprintMiB(pids) {
  try {
    const out = execFileSync('footprint', pids.flatMap((p) => ['-p', String(p)]), { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
    const m = out.match(/Footprint:\s+([\d.]+)\s*(KB|MB|GB)/gi);
    if (!m) return NaN;
    const last = m[m.length - 1].match(/([\d.]+)\s*(KB|MB|GB)/i);
    const v = Number(last[1]);
    return /GB/i.test(last[2]) ? v * 1024 : /KB/i.test(last[2]) ? v / 1024 : v;
  } catch { return NaN; }
}
/** System-wide free memory percentage from memory_pressure. */
function memFreePct() {
  try {
    return Number(execFileSync('memory_pressure', [], { encoding: 'utf8' }).match(/free percentage:\s*(\d+)%/)?.[1] ?? NaN);
  } catch { return NaN; }
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
    await writeFile(join(home, '.bob', 'trustedFolders.json'), JSON.stringify({ version: 1, folders: { [srt ? work : '/work']: 'TRUST_FOLDER' } }));
    dirs.push({ home, work });
  }
  const sessionCwd = (i) => (srt ? dirs[i].work : '/work');
  const settingsFor = (i) => {
    const { home, work } = dirs[i];
    const forms = (p) => [...new Set([p, p.replace(/^\/private(?=\/)/, ''), p.startsWith('/private/') ? p : `/private${p}`])];
    const deny = ['/tmp', '/var/folders', base, homedir()].flatMap(forms);
    return {
      network: { allowedDomains: values.domains.split(','), deniedDomains: [] },
      filesystem: { denyRead: deny, allowRead: [work, home, '/opt/homebrew', '/usr/local'].flatMap(forms), allowWrite: [work, home].flatMap(forms), denyWrite: [] },
      allowGitConfig: false,
    };
  };
  const argsFor = (i) => {
    const { home, work } = dirs[i];
    if (srt) {
      return [...(values.bare ? [] : ['-s', join(base, `srt-${i}.json`), '--', '/usr/bin/env']), `TMPDIR=${join(home, 'tmp')}`, 'NODE_USE_ENV_PROXY=1', `PATH=${values.path || process.env.PATH}`,
        '/bin/sh', '-c', 'cd "$0" && exec "$@"', work, 'bob', ...BOB_ARGS];
    }
    if (apple) {
      return ['run', '-i', '--rm', '--progress', 'none', '--name', cname(i), '--init', '-u', '10001:10001',
        ...(values.dns ? ['--dns', values.dns] : []),
        '-e', 'HOME=/home/bob', '-e', 'BOB_API_KEY', '-v', `${home}:/home/bob`, '-v', `${work}:/work`, '-w', '/work', values.image, ...BOB_ARGS];
    }
    return ['run', '--rm', '-i', '--name', cname(i), '--pull=never', '--init', '--userns=keep-id:uid=10001,gid=10001', '--user', '10001:10001',
      '-e', 'HOME=/home/bob', '-e', 'BOB_API_KEY', '-v', `${home}:/home/bob`, '-v', `${work}:/work`, '-w', '/work', values.image, ...BOB_ARGS];
  };
  const optsFor = (i) => (srt ? { cwd: base, env: { PATH: values.path || process.env.PATH, LANG: 'en_US.UTF-8', HOME: dirs[i].home, BOB_API_KEY: process.env.BOB_API_KEY } } : {});
  if (srt) {
    for (let i = 0; i < n; i++) {
      await writeFile(join(base, `srt-${i}.json`), JSON.stringify({ ...settingsFor(i), enableWeakerNetworkIsolation: false }));
      await mkdir(join(dirs[i].home, 'tmp'), { recursive: true });
    }
  }
  const seedText = 'Reply with exactly the word: pong. Do not use any tools.';
  const sessions = [];
  // Seed one session per container (a prompt makes Bob keep the session), one at a time.
  for (let i = 0; i < n; i++) {
    const a = startAgent(argsFor(i), optsFor(i));
    await a.rpc('initialize', { protocolVersion: 1, clientCapabilities: {} });
    const created = await a.rpc('session/new', { cwd: sessionCwd(i), mcpServers: [] });
    if (created.error) throw new Error(`seed ${i}: ${JSON.stringify(created.error)}`);
    const p = await a.rpc('session/prompt', { sessionId: created.result.sessionId, prompt: [{ type: 'text', text: seedText }] });
    if (p.error) throw new Error(`seed prompt ${i}: ${JSON.stringify(p.error)}`);
    sessions.push(created.result.sessionId);
    await a.stop();
    for (let t = 0; t < 100 && !srt; t++) { if (!containerListed(cname(i))) break; await sleep(100); }
  }
  // Start all N at once: initialize, load the session, then one prompt each.
  const before = srt ? [] : rssProcs();
  const freeBefore = memFreePct();
  const beforePids = new Set(before.map((p) => p.pid));
  const agents = [];
  const t0 = performance.now();
  const timings = await Promise.allSettled(Array.from({ length: n }, async (_, i) => {
    await sleep(i * Number(values.stagger));
    const a = startAgent(argsFor(i), optsFor(i));
    agents.push(a);
    const r = {};
    await a.rpc('initialize', { protocolVersion: 1, clientCapabilities: {} }).catch((e) => { throw new Error(`agent ${i}: ${e.message}`); });
    r.initialize = performance.now() - t0;
    const load = await a.rpc('session/load', { sessionId: sessions[i], cwd: sessionCwd(i), mcpServers: [] });
    if (load.error) throw new Error(`load ${i}: ${JSON.stringify(load.error)}`);
    r.load = performance.now() - t0;
    return r;
  }));
  // Memory while all N are up, after the replays settle.
  await sleep(2000);
  const during = srt ? treeProcs(agents.map((a) => a.pid)) : rssProcs();
  const added = during.filter((p) => !beforePids.has(p.pid));
  const freeDuring = memFreePct();
  const footprint = srt ? footprintMiB(during.map((p) => p.pid)) : NaN;
  const srtNode = srt ? sum(during.filter((p) => /sandbox-runtime|\/srt /.test(p.cmd) || /node .*srt/.test(p.cmd))) : NaN;
  // Turn latency: one prompt per container, all at once.
  let peakMiB = 0;
  const sampler = srt ? setInterval(() => { try { peakMiB = Math.max(peakMiB, sum(treeProcs(agents.map((a) => a.pid)))); } catch { /* ps raced */ } }, 400) : null;
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
  if (sampler) clearInterval(sampler);
  const afterTurns = srt ? treeProcs(agents.map((a) => a.pid)) : [];
  for (const a of agents) await a.stop();
  if (srt) await sleep(1000);
  for (let i = 0; i < n && !srt; i++) { try { execFileSync(CLI, apple ? ['delete', '--force', cname(i)] : ['rm', '-f', cname(i)], { stdio: 'ignore' }); } catch { /* gone */ } }
  const loads = timings.filter((t) => t.status === 'fulfilled').map((t) => t.value.load);
  return {
    n,
    ok: loads.length,
    initMedian: timings.filter((t) => t.status === 'fulfilled').length ? pct(timings.filter((t) => t.status === 'fulfilled').map((t) => t.value.initialize), 50) : NaN,
    loadMedian: loads.length ? pct(loads, 50) : NaN,
    loadMax: loads.length ? Math.max(...loads) : NaN,
    turnMedian: turnMs.length ? pct(turnMs, 50) : NaN,
    turnMax: turnMs.length ? Math.max(...turnMs) : NaN,
    totalRuntimeMiB: sum(during) - sum(before),
    addedMiB: sum(added),
    addedProcs: added.length,
    hostRuntimeAfterMiB: sum(during),
    afterTurnsMiB: sum(afterTurns),
    peakMiB,
    footprintMiB: footprint,
    srtNodeMiB: srtNode,
    freeBeforePct: freeBefore,
    freeDuringPct: freeDuring,
    failures,
  };
}

function containerListed(name) {
  try {
    return execFileSync(CLI, apple ? ['list', '--quiet'] : ['ps', '--format', '{{.Names}}'], { encoding: 'utf8' })
      .split('\n').map((l) => l.trim()).includes(name);
  } catch { return false; }
}

const base = await realpath(await mkdtemp(join(tmpdir(), 'acpcode-conc-')));
const results = [];
try {
  if (apple) {
    // Apple: resolver as configured (the default did not answer on this Mac, D-080).
  } else if (srt) {
    execFileSync(values.srt, ['--version'], { stdio: 'ignore' });
  } else {
    execFileSync('podman', ['image', 'exists', values.image]);
  }
  const plan = [];
  for (let k = 0; k < Number(values.repeat); k++) for (const n of values.counts.split(',').map(Number)) plan.push(n);
  for (const n of plan) {
    const r = await runFor(n, base);
    results.push(r);
    console.log(`N=${r.n}: ${r.ok}/${r.n} loaded; initialize median ${r.initMedian.toFixed(0)} ms; load median ${r.loadMedian.toFixed(0)} ms max ${r.loadMax.toFixed(0)}; turn median ${r.turnMedian.toFixed(0)} ms max ${r.turnMax.toFixed(0)}; host runtime +${r.totalRuntimeMiB.toFixed(0)} MiB (new processes ${r.addedMiB.toFixed(0)} MiB in ${r.addedProcs}); runtime total ${r.hostRuntimeAfterMiB.toFixed(0)} MiB${srt ? `; after the turns ${r.afterTurnsMiB.toFixed(0)} MiB (peak ${r.peakMiB.toFixed(0)}); footprint ${r.footprintMiB.toFixed(0)} MiB; free memory ${r.freeBeforePct}% -> ${r.freeDuringPct}%` : ''}${r.failures.length ? `; failures: ${r.failures.map((f) => f.slice(0, 160)).join(' | ')}` : ''}`);
  }
} finally {
  for (const n of srt ? [] : [8, 4, 2, 1]) for (let i = 0; i < n; i++) { try { execFileSync(CLI, apple ? ['delete', '--force', cname(i)] : ['rm', '-f', cname(i)], { stdio: 'ignore' }); } catch { /* gone */ } }
  await rm(base, { recursive: true, force: true });
}
console.log(JSON.stringify(results, null, 2));
