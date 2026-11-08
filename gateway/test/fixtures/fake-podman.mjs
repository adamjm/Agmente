#!/usr/bin/env node
// Fake `podman` for T-46 (FR-45, D-015, D-016). It understands only what the gateway's podman
// runner sends: `run --rm -i --name NAME --pull=never --init --userns=keep-id:uid=U,gid=G --user U:G -e K=V | -e K -v A:B -w DIR IMAGE CMD...`.
// Like Podman, it refuses a second container with a name that is in use (the project lock, D-015).
// It runs CMD as the "container", passes SIGTERM and SIGINT on to it, and exits with its code.
//
// FAKE_PODMAN_DIR (required): names in use (one file each) and log.jsonl, one line per event:
//   {"event":"start"|"refused"|"exit","name","pid","t"}   t in ms since the epoch
// FAKE_PODMAN_START_MS: wait this long before the container starts (a slow container start).
import { appendFileSync, existsSync, mkdirSync, openSync, closeSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { spawn } from 'node:child_process';

const dir = process.env.FAKE_PODMAN_DIR;
if (!dir) {
  process.stderr.write('fake-podman: FAKE_PODMAN_DIR is not set\n');
  process.exit(125);
}
mkdirSync(dir, { recursive: true });
const log = (event, extra = {}) => appendFileSync(join(dir, 'log.jsonl'), `${JSON.stringify({ event, ...extra, t: Date.now() })}\n`);

const args = process.argv.slice(2);
// `podman container exists NAME` (0 when the name is in use, 1 when not) and `podman rm -f -t 0 NAME`,
// which stops the container's process and frees the name, as Podman does (D-106). A name file holds
// the pid of the container's process once it started, so `rm` can stop it even when the CLI was killed.
if (args[0] === 'container' && args[1] === 'exists') {
  process.exit(existsSync(join(dir, `${args[2]}.name`)) ? 0 : 1);
}
if (args[0] === 'rm') {
  const name = args[args.length - 1];
  const file = join(dir, `${name}.name`);
  if (!existsSync(file)) {
    process.stderr.write(`Error: no container with name or ID "${name}" found\n`);
    process.exit(1);
  }
  let info = {};
  try {
    info = JSON.parse(readFileSync(file, 'utf8'));
  } catch {}
  if (info.pid) {
    try {
      process.kill(info.pid, 'SIGKILL');
    } catch {}
  }
  try {
    unlinkSync(file);
  } catch {}
  log('removed', { name });
  process.exit(0);
}
if (args[0] !== 'run') {
  process.stderr.write(`fake-podman: unsupported command ${args[0]}\n`);
  process.exit(125);
}
let name = null;
let keepId = false;
let entrypoint = null; // --entrypoint replaces the image entrypoint, as Podman does
let user = null;
let network = null; // --network as given; null when the flag is absent (the default network, D-105)
let cwd = process.cwd();
const env = { PATH: process.env.PATH };
let i = 1;
for (; i < args.length; i += 1) {
  const a = args[i];
  if (a === '--rm' || a === '-i' || a === '--init' || a.startsWith('--pull=')) continue;
  if (/^--userns=keep-id:uid=\d+,gid=\d+$/.test(a)) { keepId = true; continue; } // D-051
  if (a === '--user') { user = args[++i]; continue; }
  if (a === '--network') { network = args[++i]; continue; } // D-105: the push container is the only one with a network
  if (a.startsWith('--network=')) { network = a.slice('--network='.length); continue; }
  if (a === '--name') name = args[++i];
  else if (a === '-w') cwd = args[++i];
  else if (a === "-v") i += 1;
  else if (a === "--entrypoint") entrypoint = args[++i];
  else if (a === '-e') {
    const kv = args[++i];
    const eq = kv.indexOf('=');
    if (eq === -1) {
      if (process.env[kv] !== undefined) env[kv] = process.env[kv];
    } else env[kv.slice(0, eq)] = kv.slice(eq + 1);
  } else break;
}
i += 1; // the image
const command = entrypoint ? [entrypoint, ...args.slice(i)] : args.slice(i);
if (!name || command.length === 0) {
  process.stderr.write('fake-podman: need --name, an image and a command\n');
  process.exit(125);
}
if (!keepId || !/^\d+:\d+$/.test(user ?? '')) { // the runner must map the container user (D-051)
  process.stderr.write('fake-podman: missing --userns=keep-id:uid=U,gid=G or --user U:G\n');
  process.exit(125);
}

const nameFile = join(dir, `${name}.name`);
let fd;
try {
  fd = openSync(nameFile, 'wx');
} catch {
  log('refused', { name, pid: process.pid });
  process.stderr.write(`Error: creating container storage: the container name "${name}" is already in use\n`);
  process.exit(125);
}
closeSync(fd);

const free = () => {
  try {
    unlinkSync(nameFile);
  } catch {}
};
let child = null;
// FAKE_PODMAN_IGNORE_TERM: the CLI ignores SIGTERM, as a CLI can when its container does not stop (D-106).
const ignoreTerm = Boolean(process.env.FAKE_PODMAN_IGNORE_TERM);
for (const sig of ['SIGTERM', 'SIGINT']) {
  process.on(sig, () => {
    if (ignoreTerm && sig === 'SIGTERM') return;
    if (child) child.kill(sig);
    else { // stopped before the container started
      free();
      process.exit(143);
    }
  });
}
const delay = Number(process.env.FAKE_PODMAN_START_MS ?? 0);
setTimeout(() => {
  child = spawn(command[0], command.slice(1), { cwd, env, stdio: 'inherit' });
  // The arguments as the runner passed them, so a test can check what a container was given (for
  // example that a token is named with -e and never written in argv).
  writeFileSync(nameFile, JSON.stringify({ pid: child.pid })); // for `rm`, which stops the process (D-106)
  log('start', { name, pid: child.pid, network: network ?? 'default', args, command });
  child.on('exit', (code, signal) => {
    log('exit', { name, pid: child.pid, code, signal });
    free();
    process.exit(code ?? 1);
  });
}, delay);
