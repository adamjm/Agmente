// Wire-level test harness. The tests never import gateway code: they start the gateway as a
// separate process, write its config file, talk to it over HTTP and WebSocket, and read its audit
// log (one JSON line per event on stderr, FR-9). So the same suite checks any implementation.
//
// Target: ACPCODE_GATEWAY_CMD, a JSON array (the gateway command; the harness appends
// `--config <file>`). Default: the Go gateway at gateway/bin/acpcode-gateway (D-021). Build it
// first: (cd gateway && go build -trimpath -o bin/acpcode-gateway ./cmd/acpcode-gateway)
import { spawn, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtemp, mkdir, rm, realpath, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';
import WebSocket from 'ws';

const liveGateways = new Set();
process.on('exit', () => { for (const child of liveGateways) child.kill('SIGKILL'); });

export const TOKEN = 'test-token-abcdefghijklmnop';
export const OTHER_TOKEN = 'other-token-abcdefghijklmnop';
export const FAKE_AGENT = fileURLToPath(new URL('./fixtures/fake-agent.mjs', import.meta.url));
const GO_BINARY = fileURLToPath(new URL('../bin/acpcode-gateway', import.meta.url));

/** The gateway command under test, without `--config`. Relative paths resolve from the cwd. */
export function gatewayCommand() {
  const raw = process.env.ACPCODE_GATEWAY_CMD;
  if (!raw) return [GO_BINARY];
  const cmd = JSON.parse(raw);
  if (!Array.isArray(cmd) || cmd.length === 0) throw new Error('ACPCODE_GATEWAY_CMD must be a JSON array');
  return [cmd[0].includes('/') ? resolve(cmd[0]) : cmd[0], ...cmd.slice(1)];
}

/** SHA-256 of a token as lowercase hex: the form the config stores (NFR-14). */
export const hashToken = (token) => createHash('sha256').update(token, 'utf8').digest('hex');

/** Make temp dirs: <base>/root/project (allowed) and <base>/outside (not allowed). */
export async function makeDirs() {
  const base = await realpath(await mkdtemp(join(tmpdir(), 'acpcode-gw-')));
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
    stateDir: join(dirname(root), 'state'),
    runner: { kind: 'host', allowHost: true },
    ...overrides,
    limits: { ...(overrides.limits ?? {}) },
  };
}

/** Run the gateway with `--dry-run` on a config object. Returns { status, stdout, stderr }. */
export async function dryRun(config) {
  const dir = await mkdtemp(join(tmpdir(), 'acpcode-cfg-'));
  try {
    const file = join(dir, 'config.json');
    await writeFile(file, typeof config === 'string' ? config : JSON.stringify(config));
    const [cmd, ...args] = gatewayCommand();
    const run = spawnSync(cmd, [...args, '--config', file, '--dry-run'], { encoding: 'utf8', timeout: 10_000 });
    return { status: run.status, stdout: run.stdout, stderr: run.stderr };
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

/**
 * Start a gateway process on a free loopback port.
 * `overrides` change the config; `configFn(dirs, config)` may edit it further.
 * `env` adds variables to the gateway's own environment.
 * Returns spawnGateway's handle plus { dirs, config }.
 */
export async function startGateway(overrides = {}, { env = {}, configFn } = {}) {
  const dirs = await makeDirs();
  const config = rawConfig(dirs.root, overrides);
  if (configFn) configFn(dirs, config);
  let gw;
  try {
    gw = await spawnGateway(config, { env, configDir: dirs.base });
  } catch (err) {
    await dirs.cleanup();
    throw err;
  }
  return {
    ...gw,
    dirs,
    config,
    async stop() {
      await gw.stop();
      await dirs.cleanup();
    },
  };
}

/**
 * Start a gateway process for a ready config object. The config file goes into `configDir`
 * (default: a new temp folder). `cwd` is the gateway's working directory, which the agent inherits;
 * `env` replaces the gateway's environment when `replaceEnv` is set, and is added to it otherwise.
 * Returns { url, httpUrl, audit, pid, spawned(), waitForAudit(), settle(), stop() }.
 */
export async function spawnGateway(config, { env = {}, replaceEnv = false, cwd, configDir } = {}) {
  const dir = configDir ?? await mkdtemp(join(tmpdir(), 'acpcode-gwcfg-'));
  const file = join(dir, 'config.json');
  await writeFile(file, JSON.stringify(config));
  const removeDir = () => (configDir ? Promise.resolve() : rm(dir, { recursive: true, force: true }));

  const [cmd, ...args] = gatewayCommand();
  const child = spawn(cmd, [...args, '--config', file], {
    cwd,
    env: replaceEnv ? env : { ...process.env, ...env },
    stdio: ['ignore', 'ignore', 'pipe'],
  });
  const exited = new Promise((r) => child.once('exit', (code, signal) => r({ code, signal })));
  // A test that times out must not keep the runner alive, or leave a gateway behind.
  child.unref();
  child.stderr.unref();
  liveGateways.add(child);
  exited.then(() => liveGateways.delete(child));
  const audit = [];
  const stderrNoise = [];
  const waiters = new Set();
  createInterface({ input: child.stderr }).on('line', (line) => {
    let record;
    try {
      record = JSON.parse(line);
    } catch {
      stderrNoise.push(line);
      return;
    }
    audit.push(record);
    for (const w of waiters) w();
  });

  /** Wait until some audit record matches `pred`. Returns it. */
  const waitForAudit = (pred, ms = 5000) => new Promise((resolveWait, reject) => {
    const check = () => {
      const hit = audit.find(pred);
      if (!hit) return false;
      waiters.delete(check);
      clearTimeout(timer);
      resolveWait(hit);
      return true;
    };
    const timer = setTimeout(() => {
      waiters.delete(check);
      reject(new Error(`no matching audit line within ${ms} ms; got ${JSON.stringify(audit.map((a) => a.event))} ${stderrNoise.join(' | ')}`));
    }, ms);
    waiters.add(check);
    check();
  });

  let listening;
  try {
    listening = await Promise.race([
      waitForAudit((a) => a.event === 'listening', 10_000),
      exited.then(({ code }) => { throw new Error(`gateway exited with ${code} before listening: ${stderrNoise.join(' | ')}`); }),
    ]);
  } catch (err) {
    child.kill('SIGKILL');
    await removeDir();
    throw err;
  }
  const port = Number(String(listening.reason).split(':').at(-1));
  const url = `ws://127.0.0.1:${port}/`;

  return {
    url,
    httpUrl: `http://127.0.0.1:${port}/`,
    audit,
    pid: child.pid,
    /** Agent processes started so far: one `agent_start` audit line each (FR-9, D-025). */
    spawned: () => audit.filter((a) => a.event === 'agent_start').length,
    waitForAudit,
    /** Give the gateway's stderr time to arrive before a negative check. */
    settle: (ms = 150) => sleep(ms),
    async stop() {
      if (child.exitCode === null && child.signalCode === null) {
        child.kill('SIGTERM');
        const t = setTimeout(() => child.kill('SIGKILL'), 5000);
        await exited;
        clearTimeout(t);
      }
      await removeDir();
    },
  };
}

/** Connect. Resolves { status: 101, ws } on success or { status, headers } on an HTTP rejection. */
export function connect(url, headers = {}) {
  return new Promise((resolveConnect, reject) => {
    const ws = new WebSocket(url, { headers, perMessageDeflate: false });
    ws.once('open', () => resolveConnect({ status: 101, ws }));
    ws.once('unexpected-response', (req, res) => {
      resolveConnect({ status: res.statusCode, headers: res.headers });
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
  return new Promise((resolveRpc, reject) => {
    const onMessage = (data) => {
      const msg = JSON.parse(data.toString());
      if (msg.id === id) {
        ws.off('message', onMessage);
        resolveRpc(msg);
      }
    };
    ws.on('message', onMessage);
    ws.once('close', (code) => reject(new Error(`closed with ${code}`)));
    ws.send(JSON.stringify({ jsonrpc: '2.0', id, method, params }));
  });
}

/** Wait for the socket to close. Resolves { code, reason }. */
export function nextClose(ws) {
  return new Promise((resolveClose) => ws.once('close', (code, reason) => resolveClose({ code, reason: reason.toString() })));
}

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// The gateway's default project, working_dir (gateway internal/server/working_dir.go), is listed on
// every start. Tests about the projects a phone made leave it out; test/working-dir.test.mjs checks it.
export const WORKING_DIR_NAME = 'working_dir';
export const userProjects = (list) => list.filter((p) => p.name !== WORKING_DIR_NAME);

/**
 * Register gw.dirs.project (or `path`) as a project and open a session in it on this socket.
 * Requests with no cwd or sessionId then go to this project (D-025). Returns { project, sessionId }.
 */
export async function useProject(gw, ws, path = gw.dirs.project) {
  let res = await rpc(ws, '_acpcode/projects/create', { name: 'test', path });
  let project = res.result?.project;
  if (!project) {
    const list = await rpc(ws, '_acpcode/projects/list', {});
    project = list.result.projects.find((p) => p.path === path);
    if (!project) throw new Error(`cannot use project: ${JSON.stringify(res.error)}`);
  }
  res = await rpc(ws, 'session/new', { cwd: path, mcpServers: [] });
  if (!res.result) throw new Error(`session/new failed: ${JSON.stringify(res.error)}`);
  return { project, sessionId: res.result.sessionId };
}
