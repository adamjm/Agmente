#!/usr/bin/env node
// Cold-start timing for a project's Bob: host process vs a fresh Podman container.
// Measures, from the moment the start command is issued:
//   initialize response, session/load of an existing session (+ its replay), session/new response.
// Talks ACP straight over stdio: gateway overhead is measured separately (T-12, under 1 ms).
// Usage (BOB_API_KEY in the environment; never printed):
//   node gateway/scripts/bench-start.mjs [--runs 5] [--image acpcode-bob:2.0.9] [--skip-host] [--runner podman|apple] [--dns 1.1.1.1]
// --runner apple uses Apple's `container` CLI (D-079): bind-mounted home and project folders, the
// container user set with -u, and the same-name lock checked with `container list`. It also prints
// the host memory held by the runtime with one idle Bob container running (RSS of its processes).
import { spawn, execFileSync } from 'node:child_process';
import { mkdtemp, mkdir, realpath, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { parseArgs } from 'node:util';
import { randomBytes } from 'node:crypto';

const { values } = parseArgs({
  options: {
    runs: { type: 'string', default: '5' },
    image: { type: 'string', default: 'acpcode-bob:2.0.9' },
    'skip-host': { type: 'boolean', default: false },
    runner: { type: 'string', default: 'podman' },
    dns: { type: 'string', default: '' },
  },
});
const runs = Number(values.runs);
const log = (...a) => console.log(...a);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const BOB_ARGS = ['acp', '--accept-license', '--log-level', 'warn'];

/** Start an agent and give back an ACP client over its stdio. */
function startAgent(command, args, opts) {
  const t0 = performance.now();
  const child = spawn(command, args, { stdio: ['pipe', 'pipe', 'pipe'], ...opts });
  let buf = '';
  let nextId = 1;
  const pending = new Map();
  let lastUpdateAt = 0;
  let updates = 0;
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
      } else if (msg.method === 'session/update') {
        updates += 1;
        lastUpdateAt = performance.now();
      } else if (msg.id !== undefined && msg.method !== undefined) {
        child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id: msg.id, error: { code: -32601, message: 'bench' } })}\n`);
      }
    }
  });
  let stderr = '';
  child.stderr.on('data', (d) => { stderr += d.toString(); });
  const rpc = (method, params) => new Promise((resolve) => {
    const id = nextId++;
    pending.set(id, resolve);
    child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id, method, params })}\n`);
  });
  const since = () => performance.now() - t0;
  const exited = new Promise((r) => child.once('exit', r));
  // An agent that exits while a request waits would leave the benchmark waiting forever: report it.
  child.once('exit', (code) => {
    if (pending.size > 0) {
      console.error(`agent exited (code ${code}) with ${pending.size} request(s) waiting; stderr tail:\n${stderr.slice(-600)}`);
      process.exit(1);
    }
  });
  const stop = async () => { child.stdin.end(); child.kill('SIGTERM'); await Promise.race([exited, sleep(5000)]); };
  /** Wait until no session/update has arrived for quietMs. Returns the time of the last one. */
  const replayDone = async (quietMs = 400) => {
    const start = performance.now();
    while (performance.now() - Math.max(lastUpdateAt, start) < quietMs) await sleep(25);
    return lastUpdateAt > start ? lastUpdateAt - t0 : null;
  };
  return { rpc, since, stop, replayDone, updates: () => updates, stderr: () => stderr };
}

async function measure(label, make, projectCwd, sessionId) {
  const a = make();
  const r = {};
  const init = await a.rpc('initialize', { protocolVersion: 1, clientCapabilities: {} });
  r.initialize = a.since();
  if (init.error) throw new Error(`${label} initialize: ${JSON.stringify(init.error)} ${a.stderr().slice(0, 300)}`);
  if (sessionId) {
    const before = a.updates();
    const load = await a.rpc('session/load', { sessionId, cwd: projectCwd, mcpServers: [] });
    r.load = a.since();
    if (load.error) throw new Error(`${label} load: ${JSON.stringify(load.error)}`);
    const last = await a.replayDone();
    r.replayEnd = last;
    r.replayUpdates = a.updates() - before;
  }
  const created = await a.rpc('session/new', { cwd: projectCwd, mcpServers: [] });
  r.sessionNew = a.since();
  if (created.error) throw new Error(`${label} session/new: ${JSON.stringify(created.error)} ${a.stderr().slice(0, 300)}`);
  const t = performance.now();
  await a.stop();
  r.stopMs = performance.now() - t;
  r.sessionId = created.result.sessionId;
  return r;
}

/** Create a session with one prompt, so later runs have history to load. */
async function seed(make, projectCwd) {
  const a = make();
  await a.rpc('initialize', { protocolVersion: 1, clientCapabilities: {} });
  const created = await a.rpc('session/new', { cwd: projectCwd, mcpServers: [] });
  if (created.error) throw new Error(`seed session/new: ${JSON.stringify(created.error)} ${a.stderr().slice(0, 500)}`);
  const sessionId = created.result.sessionId;
  const p = await a.rpc('session/prompt', { sessionId, prompt: [{ type: 'text', text: 'Reply with exactly the word: pong. Do not use any tools.' }] });
  if (p.error) throw new Error(`seed prompt: ${JSON.stringify(p.error)}`);
  await a.stop();
  return sessionId;
}

const pct = (xs, p) => { const s = [...xs].sort((x, y) => x - y); return s[Math.min(s.length - 1, Math.ceil((p / 100) * s.length) - 1)]; };
function report(label, rows) {
  const keys = ['initialize', 'load', 'replayEnd', 'sessionNew', 'stopMs'];
  log(`\n${label} (${rows.length} runs, ms from start command)`);
  for (const k of keys) {
    const xs = rows.map((r) => r[k]).filter((x) => typeof x === 'number');
    if (xs.length) log(`  ${k.padEnd(11)} median ${pct(xs, 50).toFixed(0).padStart(6)}  max ${Math.max(...xs).toFixed(0).padStart(6)}  all ${xs.map((x) => x.toFixed(0)).join(' ')}`);
  }
  log(`  replayed updates per load: ${rows.map((r) => r.replayUpdates ?? '-').join(' ')}`);
}


function logMemory(m) {
  log(`host memory with one idle Bob container: runtime ${m.beforeMiB.toFixed(0)} MiB before, ${m.duringMiB.toFixed(0)} MiB during; processes added for it ${m.addedMiB.toFixed(0)} MiB`);
  for (const line of m.added) log(`  added: ${line}`);
}
const cliName = () => (values.runner === 'apple' ? 'container' : 'podman');
/** Memory the runtime holds on the host: RSS of its processes, in MiB, and their pids. */
function hostRss(pattern) {
  const out = execFileSync('ps', ['-axo', 'pid=,rss=,command='], { encoding: 'utf8' });
  const procs = [];
  for (const line of out.split('\n')) {
    const m = line.trim().match(/^(\d+)\s+(\d+)\s+(.*)$/);
    if (m && new RegExp(pattern).test(m[3]) && !m[3].includes('bench-start')) procs.push({ pid: Number(m[1]), kib: Number(m[2]), cmd: m[3] });
  }
  return { mib: procs.reduce((t, p) => t + p.kib, 0) / 1024, procs };
}
// Apple: the runtime's own helpers, and one Virtualization.framework VM process per running container.
// Podman: gvproxy and the libkrun VM (krunkit) of the machine, which holds every container.
const RUNTIME_PATTERN = {
  apple: 'container-runtime-linux|container-apiserver|container-network|container-core-images|machine-apiserver|Virtualization.VirtualMachine',
  podman: 'gvproxy|krunkit|podman',
};
/** With one idle Bob container running and its session loaded: what the runtime adds on the host. */
async function memoryWithIdleBob(make, cwd, sessionId) {
  const before = hostRss(RUNTIME_PATTERN[values.runner]);
  const beforePids = new Set(before.procs.map((p) => p.pid));
  const a = make();
  await a.rpc('initialize', { protocolVersion: 1, clientCapabilities: {} });
  await a.rpc('session/load', { sessionId, cwd, mcpServers: [] });
  await sleep(2000);
  const during = hostRss(RUNTIME_PATTERN[values.runner]);
  const added = during.procs.filter((p) => !beforePids.has(p.pid));
  await a.stop();
  return {
    beforeMiB: before.mib,
    duringMiB: during.mib,
    addedMiB: added.reduce((t, p) => t + p.kib, 0) / 1024,
    added: added.map((p) => `${p.pid} ${(p.kib / 1024).toFixed(0)} MiB ${p.cmd.slice(0, 60)}`),
  };
}
async function appleContainer() {
  const home = join(base, 'bob-home');
  const work = join(base, 'bob-project');
  await mkdir(join(home, '.bob'), { recursive: true });
  await mkdir(work, { recursive: true });
  await writeFile(join(home, '.bob', 'trustedFolders.json'), JSON.stringify({ version: 1, folders: { '/work': 'TRUST_FOLDER' } }));
  const dnsArgs = values.dns ? ['--dns', values.dns] : [];
  const runArgs = ['run', '-i', '--rm', '--progress', 'none', '--name', name, '--init', '-u', '10001:10001', ...dnsArgs,
    '-e', 'HOME=/home/bob', '-e', 'BOB_API_KEY', '-v', `${home}:/home/bob`, '-v', `${work}:/work`, '-w', '/work', values.image, ...BOB_ARGS];
  const make = () => startAgent('container', runArgs, { env: process.env });
  const listed = () => execFileSync('container', ['list', '--quiet'], { encoding: 'utf8' }).split('\n').map((l) => l.trim()).includes(name);
  const sessionId = await seed(make, '/work');
  const waitGone = async () => { for (let i = 0; i < 100; i++) { if (!listed()) return; await sleep(100); } };
  await waitGone();
  {
    const first = make();
    await first.rpc('initialize', { protocolVersion: 1, clientCapabilities: {} });
    let second = '';
    try { execFileSync('container', ['run', '-d', '--progress', 'none', '--name', name, '--entrypoint', 'true', values.image], { stdio: 'pipe' }); second = 'STARTED (lock does not hold)'; } catch (e) { second = `refused: ${e.stderr.toString().trim().split('\n').pop()}`; }
    log(`\nsame-name second container while one runs: ${second}`);
    await first.stop();
    await waitGone();
  }
  const rows = [];
  for (let i = 0; i < runs; i++) { rows.push(await measure('container', make, '/work', sessionId)); await waitGone(); }
  const memory = await memoryWithIdleBob(make, '/work', sessionId);
  await waitGone();
  report(`apple container per run (${values.image}, ${execFileSync('container', ['--version'], { encoding: 'utf8' }).trim()})`, rows);
  logMemory(memory);
}
async function podmanContainer() {
  // A new container per run (podman run --rm), persistent HOME and project volumes.
  execFileSync('podman', ['volume', 'create', volHome], { stdio: 'ignore' });
  execFileSync('podman', ['volume', 'create', volWork], { stdio: 'ignore' });
  // Volumes are created root-owned; hand them to the image's user and write the trust entry.
  execFileSync('podman', ['run', '--rm', '--user', '0', '-v', `${volHome}:/home/bob`, '-v', `${volWork}:/work`, '--entrypoint', 'sh', values.image, '-c',
    `chown -R 10001:10001 /home/bob /work && mkdir -p /home/bob/.bob && echo '{"version":1,"folders":{"/work":"TRUST_FOLDER"}}' > /home/bob/.bob/trustedFolders.json && chown -R 10001:10001 /home/bob/.bob`], { stdio: 'inherit' });
  const runArgs = ['run', '--rm', '-i', '--name', name, '-e', 'BOB_API_KEY', '-v', `${volHome}:/home/bob`, '-v', `${volWork}:/work`, '-w', '/work', values.image, ...BOB_ARGS];
  const make = () => startAgent('podman', runArgs, { env: process.env });
  const sessionId = await seed(make, '/work');
  // Wait until the name is free again (the lock of D-015) before the next run.
  const waitGone = async () => { for (let i = 0; i < 100; i++) { try { execFileSync('podman', ['container', 'exists', name]); await sleep(100); } catch { return; } } };
  await waitGone();
  // D-015 lock check: a second container with the same name must be refused while one runs.
  {
    const first = make();
    await first.rpc('initialize', { protocolVersion: 1, clientCapabilities: {} });
    let second = '';
    try { execFileSync('podman', ['run', '--rm', '-d', '--name', name, '--entrypoint', 'true', values.image], { stdio: 'pipe' }); second = 'STARTED (lock does not hold)'; } catch (e) { second = `refused: ${e.stderr.toString().trim().split('\n').pop()}`; }
    log(`\nsame-name second container while one runs: ${second}`);
    await first.stop();
    await waitGone();
  }
  const rows = [];
  for (let i = 0; i < runs; i++) { rows.push(await measure('container', make, '/work', sessionId)); await waitGone(); }
  const memory = await memoryWithIdleBob(make, '/work', sessionId);
  await waitGone();
  report(`fresh container per run (${values.image}, podman machine ${execFileSync('podman', ['info', '--format', '{{.Host.CPUs}} CPUs'], { encoding: 'utf8' }).trim()})`, rows);
  logMemory(memory);
}
if (!process.env.BOB_API_KEY) { console.error('BOB_API_KEY is not set'); process.exit(2); }
const base = await realpath(await mkdtemp(join(tmpdir(), 'acpcode-bench-')));
const tag = randomBytes(3).toString('hex');
const volHome = `acpcode-bench-home-${tag}`;
const volWork = `acpcode-bench-work-${tag}`;
const name = `acpcode-bench-${tag}`;
try {
  // --- Host: bob on the Mac, with a disposable HOME that trusts the project.
  if (!values['skip-host']) {
    const project = join(base, 'project');
    const home = join(base, 'home');
    await mkdir(project, { recursive: true });
    await mkdir(join(home, '.bob'), { recursive: true });
    await writeFile(join(home, '.bob', 'trustedFolders.json'), JSON.stringify({ version: 1, folders: { [project]: 'TRUST_FOLDER' } }));
    const env = { PATH: process.env.PATH, HOME: home, LANG: process.env.LANG ?? 'C.UTF-8', BOB_API_KEY: process.env.BOB_API_KEY };
    const bob = execFileSync('/usr/bin/which', ['bob'], { encoding: 'utf8' }).trim();
    const make = () => startAgent(bob, BOB_ARGS, { cwd: project, env });
    const sessionId = await seed(make, project);
    const rows = [];
    for (let i = 0; i < runs; i++) rows.push(await measure('host', make, project, sessionId));
    report(`host bob ${execFileSync(bob, ['--version'], { encoding: 'utf8' }).split('\n')[0]}`, rows);
  }

  if (values.runner === 'apple') await appleContainer();
  else await podmanContainer();
} finally {
  try { execFileSync(cliName(), values.runner === 'apple' ? ['delete', '--force', name] : ['rm', '-f', name], { stdio: 'ignore' }); } catch { /* gone */ }
  for (const v of [volHome, volWork]) { try { execFileSync('podman', ['volume', 'rm', '-f', v], { stdio: 'ignore' }); } catch { /* gone */ } }
  await rm(base, { recursive: true, force: true });
}
