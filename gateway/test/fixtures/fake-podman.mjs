#!/usr/bin/env node
// Fake `podman` for T-46 (FR-45, D-015, D-016). It understands only what the gateway's podman
// runner sends: `run --rm -i --name NAME --pull=never --init -e K=V | -e K -v A:B -w DIR IMAGE CMD...`.
// Like Podman, it refuses a second container with a name that is in use (the project lock, D-015).
// It runs CMD as the "container", passes SIGTERM and SIGINT on to it, and exits with its code.
//
// FAKE_PODMAN_DIR (required): names in use (one file each) and log.jsonl, one line per event:
//   {"event":"start"|"refused"|"exit","name","pid","t"}   t in ms since the epoch
// FAKE_PODMAN_START_MS: wait this long before the container starts (a slow container start).
import { appendFileSync, mkdirSync, openSync, closeSync, unlinkSync } from 'node:fs';
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
if (args[0] !== 'run') {
  process.stderr.write(`fake-podman: unsupported command ${args[0]}\n`);
  process.exit(125);
}
let name = null;
let cwd = process.cwd();
const env = { PATH: process.env.PATH };
let i = 1;
for (; i < args.length; i += 1) {
  const a = args[i];
  if (a === '--rm' || a === '-i' || a === '--init' || a.startsWith('--pull=')) continue;
  if (a === '--name') name = args[++i];
  else if (a === '-w') cwd = args[++i];
  else if (a === '-v') i += 1;
  else if (a === '-e') {
    const kv = args[++i];
    const eq = kv.indexOf('=');
    if (eq === -1) {
      if (process.env[kv] !== undefined) env[kv] = process.env[kv];
    } else env[kv.slice(0, eq)] = kv.slice(eq + 1);
  } else break;
}
i += 1; // the image
const command = args.slice(i);
if (!name || command.length === 0) {
  process.stderr.write('fake-podman: need --name, an image and a command\n');
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
for (const sig of ['SIGTERM', 'SIGINT']) {
  process.on(sig, () => {
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
  log('start', { name, pid: child.pid });
  child.on('exit', (code, signal) => {
    log('exit', { name, pid: child.pid, code, signal });
    free();
    process.exit(code ?? 1);
  });
}, delay);
