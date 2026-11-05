// Start the configured agent and split its stdout into lines (FR-4).
import { spawn } from 'node:child_process';

/** Build the child environment from an allow-list. Nothing else from the gateway leaks in. */
export function buildAgentEnv(envPassthrough, sourceEnv = process.env) {
  const env = {};
  for (const name of envPassthrough) {
    if (typeof sourceEnv[name] === 'string') env[name] = sourceEnv[name];
  }
  return env;
}

/** Spawn the agent from config. The client never supplies command, arguments or environment. */
export function spawnAgent(agentConfig, { cwd } = {}) {
  const [file, ...args] = agentConfig.command;
  return spawn(file, args, {
    cwd,
    env: buildAgentEnv(agentConfig.envPassthrough),
    shell: false,
    stdio: ['pipe', 'pipe', 'pipe'],
    windowsHide: true,
  });
}

/**
 * Split a byte stream into newline-terminated lines. Calls onOverflow (once) if a
 * line grows past maxBytes, and then ignores the rest of the stream.
 */
export class LineSplitter {
  constructor(maxBytes, onLine, onOverflow) {
    this.maxBytes = maxBytes;
    this.onLine = onLine;
    this.onOverflow = onOverflow;
    this.chunks = [];
    this.pending = 0;
    this.dead = false;
  }

  push(chunk) {
    if (this.dead) return;
    let start = 0;
    let idx;
    while ((idx = chunk.indexOf(0x0a, start)) !== -1) {
      const part = chunk.subarray(start, idx);
      if (this.pending + part.length > this.maxBytes) return this.overflow();
      this.chunks.push(part);
      const line = Buffer.concat(this.chunks).toString('utf8').replace(/\r$/, '');
      this.chunks = [];
      this.pending = 0;
      if (line.length > 0) this.onLine(line);
      start = idx + 1;
    }
    const rest = chunk.subarray(start);
    if (this.pending + rest.length > this.maxBytes) return this.overflow();
    if (rest.length > 0) {
      this.chunks.push(rest);
      this.pending += rest.length;
    }
  }

  overflow() {
    this.dead = true;
    this.chunks = [];
    this.pending = 0;
    this.onOverflow();
  }
}
