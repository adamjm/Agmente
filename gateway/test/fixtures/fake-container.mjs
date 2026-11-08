#!/usr/bin/env node
// Fake Apple `container` CLI for the wire suite (migration step 3, D-079). It understands only what
// the gateway's apple runner sends:
//   run  ... --name NAME ... [-e K=V | -e K] [-v A:B] [-w DIR] [--network X] [--entrypoint X] IMAGE CMD...
//   exec -i [-u U:G] [-w DIR] [-e K=V ...] NAME CMD...
//   list --quiet
//   delete --force NAME
// Like Apple's CLI, it refuses a second container with a name in use (the project lock, D-015).
// It runs the command on the host, in the given folder, as the "container" would see it: the project
// and home folders are at the same paths on both sides, so no translation is needed.
//
// FAKE_CONTAINER_DIR (required): names in use (one file each, JSON {pid, child}) and log.jsonl.
//   Events: {"event":"start"|"refused"|"exit"|"exec"|"exec_exit", "name", "pid", ...,"t"}.
// FAKE_CONTAINER_START_MS: wait this long before a run's command starts (a slow container start).
// FAKE_CONTAINER_GIT: when set, a command whose program is `git` runs this program instead (tests
//   use it to make git hang). Exec children are detached, as a process inside a VM is not killed
//   when the CLI is killed (the case the gateway's cleanup handles, D-079).
import { appendFileSync, mkdirSync, openSync, closeSync, unlinkSync, readdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { spawn } from 'node:child_process';

const dir = process.env.FAKE_CONTAINER_DIR;
if (!dir) {
  process.stderr.write('fake-container: FAKE_CONTAINER_DIR is not set\n');
  process.exit(125);
}
mkdirSync(dir, { recursive: true });
const log = (event, extra = {}) => appendFileSync(join(dir, 'log.jsonl'), `${JSON.stringify({ event, ...extra, t: Date.now() })}\n`);
const nameFile = (name) => join(dir, `${name}.name`);
const readRec = (name) => {
  try {
    return JSON.parse(readFileSync(nameFile(name), 'utf8'));
  } catch {
    return null;
  }
};
const free = (name) => {
  try {
    unlinkSync(nameFile(name));
  } catch {}
};
const fail = (msg, code = 1) => {
  process.stderr.write(`${msg}\n`);
  process.exit(code);
};

// With FAKE_CONTAINER_GIT set, a `git` shim folder goes first on PATH, so every git the command runs
// (also through `sh -c 'exec "$@"'`) is the test program.
function withGitShim(path, env) {
  if (!process.env.FAKE_CONTAINER_GIT) return path;
  env.FAKE_CONTAINER_GIT = process.env.FAKE_CONTAINER_GIT; // the shim reads it inside the container
  const shimDir = join(dir, 'bin');
  mkdirSync(shimDir, { recursive: true });
  writeFileSync(join(shimDir, 'git'), '#!/bin/sh\nexec "$FAKE_CONTAINER_GIT" "$@"\n', { mode: 0o755 });
  return `${shimDir}:${path ?? ''}`;
}
const program = (argv) => argv;

const args = process.argv.slice(2);
const cmd = args[0];
if (!['run', 'exec', 'list', 'delete'].includes(cmd)) fail(`fake-container: unsupported command ${cmd}`);

if (cmd === 'list') {
  // Running containers: one name per line. Only --quiet is used by the gateway.
  if (!args.includes('--quiet')) fail('fake-container: list supports only --quiet');
  for (const f of existsSync(dir) ? readdirSync(dir) : []) {
    if (f.endsWith('.name')) process.stdout.write(`${f.slice(0, -'.name'.length)}\n`);
  }
  process.exit(0);
}

if (cmd === 'delete') {
  const name = args[args.length - 1];
  const rec = readRec(name);
  if (!rec) fail(`Error: container ${name} not found`);
  if (rec.child) {
    try {
      process.kill(rec.child, 'SIGKILL');
    } catch {}
  }
  free(name);
  process.exit(0);
}

if (cmd === 'exec') {
  let user = null;
  let cwd = process.cwd();
  const env = { PATH: process.env.PATH };
  let i = 1;
  for (; i < args.length; i += 1) {
    const a = args[i];
    if (a === '-i' || a === '--interactive') continue;
    if (a === '-u' || a === '--user') { user = args[++i]; continue; }
    if (a === '-w' || a === '--workdir' || a === '--cwd') { cwd = args[++i]; continue; }
    if (a === '-e' || a === '--env') {
      const kv = args[++i];
      const eq = kv.indexOf('=');
      if (eq === -1) {
        if (process.env[kv] !== undefined) env[kv] = process.env[kv];
      } else env[kv.slice(0, eq)] = kv.slice(eq + 1);
      continue;
    }
    break;
  }
  const name = args[i];
  const argv = args.slice(i + 1);
  if (!readRec(name)) fail(`Error: container ${name} is not running`);
  if (!/^\d+:\d+$/.test(user ?? '')) fail('fake-container: exec needs -u U:G (the gateway maps the user)');
  if (argv.length === 0) fail('fake-container: exec needs a command');
  // The gateway's cleanup runs a script that scans /proc for the marker in each process's environment.
  // This Mac has no /proc, so the fake answers that script itself: it kills the exec child recorded
  // under the marker. Each marked exec child is recorded as marker-<value> until it exits.
  if (argv[0] === 'sh' && argv.join(' ').includes('/proc/[0-9]*')) {
    const marker = argv[argv.length - 1];
    const file = join(dir, `marker-${marker}`);
    if (existsSync(file)) {
      const pid = Number(readFileSync(file, 'utf8'));
      try {
        process.kill(pid, 'SIGKILL');
        log('killed', { name, pid, marker });
      } catch {}
    }
    process.exit(0);
  }
  env.PATH = withGitShim(env.PATH, env);
  const child = spawn(argv[0], argv.slice(1), { cwd, env, stdio: 'inherit', detached: true });
  log('exec', { name, pid: child.pid, argv0: argv[0], args: argv.slice(1).join(' ') });
  if (env.ACPCODE_EXEC) writeFileSync(join(dir, `marker-${env.ACPCODE_EXEC}`), String(child.pid));
  child.on('exit', (code, signal) => {
    log('exec_exit', { name, pid: child.pid, code, signal });
    if (env.ACPCODE_EXEC) { try { unlinkSync(join(dir, `marker-${env.ACPCODE_EXEC}`)); } catch {} }
    process.exit(code ?? 1);
  });
  // The CLI forwards nothing on its own when it is killed: the detached child keeps running.
  process.on('SIGTERM', () => child.kill('SIGTERM'));
  process.on('SIGINT', () => child.kill('SIGINT'));
} else if (cmd === 'run') {

let name = null;
let cwd = process.cwd();
let entrypoint = null;
let user = null;
const env = { PATH: process.env.PATH };
let i = 1;
for (; i < args.length; i += 1) {
  const a = args[i];
  if (a === '--rm' || a === '-i' || a === '--interactive' || a === '--init' || a.startsWith('--pull=')) continue;
  if (a === '--progress') { i += 1; continue; }
  if (a === '--name') { name = args[++i]; continue; }
  if (a === '-u' || a === '--user') { user = args[++i]; continue; }
  if (a === '-w' || a === '--workdir' || a === '--cwd') { cwd = args[++i]; continue; }
  if (a === '-v' || a === '--network' || a === '--os') { i += 1; continue; }
  if (a === '--entrypoint') { entrypoint = args[++i]; continue; }
  if (a === '-e' || a === '--env') {
    const kv = args[++i];
    const eq = kv.indexOf('=');
    if (eq === -1) {
      if (process.env[kv] !== undefined) env[kv] = process.env[kv];
    } else env[kv.slice(0, eq)] = kv.slice(eq + 1);
    continue;
  }
  break;
}
const image = args[i];
const rest = args.slice(i + 1);
if (!name || !image) fail('fake-container: need --name and an image');
if (!/^\d+:\d+$/.test(user ?? '')) fail('fake-container: run needs -u U:G (the gateway maps the user)');
const argv = entrypoint ? [entrypoint, ...rest] : rest;
if (argv.length === 0) fail('fake-container: need a command');

let fd;
try {
  fd = openSync(nameFile(name), 'wx');
} catch {
  log('refused', { name, pid: process.pid });
  fail(`Error: container with id ${name} already exists`, 1);
}
writeFileSync(fd, JSON.stringify({ pid: process.pid, child: null }));
closeSync(fd);

let child = null;
let stoppedEarly = false;
for (const sig of ['SIGTERM', 'SIGINT']) {
  process.on(sig, () => {
    if (child) child.kill(sig);
    else { // stopped before the command started
      stoppedEarly = true;
      free(name);
      process.exit(143);
    }
  });
}
const delay = Number(process.env.FAKE_CONTAINER_START_MS ?? 0);
setTimeout(() => {
  if (stoppedEarly) return;
  env.PATH = withGitShim(env.PATH, env);
  child = spawn(argv[0], argv.slice(1), { cwd, env, stdio: 'inherit' });
  const rec = readRec(name);
  if (rec) writeFileSync(nameFile(name), JSON.stringify({ ...rec, child: child.pid }));
  log('start', { name, pid: child.pid, args: args.slice(1, i + 1).join(' ') });
  child.on('exit', (code, signal) => {
    log('exit', { name, pid: child.pid, code, signal });
    free(name);
    process.exit(code ?? 1);
  });
}, delay);
}
