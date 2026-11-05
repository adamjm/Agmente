// HTTP server with admission control before the WebSocket upgrade (ARCHITECTURE 2.1, 2.2).
import { createServer } from 'node:http';
import { WebSocketServer } from 'ws';
import { clientKey, FailureLimiter, findTokenEntry } from './auth.js';
import { checkCwd, parseClientMessage, resolveRoots, CLOSE_TOO_BIG } from './acp-guard.js';
import { LineSplitter, spawnAgent } from './agent-process.js';
import { createAudit } from './audit.js';

const STATUS_TEXT = { 401: 'Unauthorized', 403: 'Forbidden', 404: 'Not Found', 429: 'Too Many Requests' };
const CLOSE_AGENT_EXITED = 1011;
const KILL_GRACE_MS = 2000;

function rejectUpgrade(socket, status, extraHeaders = {}) {
  if (socket.destroyed) return;
  const headers = { Connection: 'close', 'Content-Length': '0', ...extraHeaders };
  const head = Object.entries(headers).map(([k, v]) => `${k}: ${v}`).join('\r\n');
  socket.end(`HTTP/1.1 ${status} ${STATUS_TEXT[status]}\r\n${head}\r\n\r\n`);
  setTimeout(() => socket.destroy(), 100).unref();
}

/**
 * Create a gateway. Options are for tests: `audit` (function), `spawn` (agent spawner).
 * Returns { listen(), close(), address(), stats }.
 */
export function createGateway(config, options = {}) {
  const audit = options.audit ?? createAudit();
  const spawn = options.spawn ?? spawnAgent;
  const { limits } = config;
  const limiter = new FailureLimiter({
    maxFailures: limits.authFailuresPerWindow,
    windowMs: limits.authWindowSeconds * 1000,
    lockoutMs: limits.lockoutSeconds * 1000,
    now: options.now,
  });
  const stats = { spawned: 0, active: 0, perIdentity: new Map(), backpressureEvents: 0 };
  let rootsPromise = resolveRoots(config.projects.roots);
  let connCounter = 0;

  const wss = new WebSocketServer({ noServer: true, maxPayload: limits.maxMessageBytes, perMessageDeflate: false });

  const server = createServer((req, res) => {
    // Plain HTTP: only a health check. It reveals nothing about the agent.
    if (req.method === 'GET' && req.url === '/healthz') {
      res.writeHead(200, { 'Content-Type': 'text/plain' }).end('ok');
      return;
    }
    res.writeHead(404).end();
  });

  server.on('upgrade', (req, socket, head) => {
    socket.on('error', () => socket.destroy());
    const client = clientKey(req, config.trustProxy);

    // 1. Browsers always send Origin. A native client does not. Reject browsers (FR-3).
    if (req.headers.origin !== undefined) {
      audit('reject', { client, status: 403, reason: 'origin' });
      return rejectUpgrade(socket, 403);
    }
    // 2. Locked-out address (FR-8).
    if (limiter.isLocked(client)) {
      audit('reject', { client, status: 429, reason: 'locked_out' });
      return rejectUpgrade(socket, 429, { 'Retry-After': String(limits.lockoutSeconds) });
    }
    // 3. Token (FR-1).
    const entry = findTokenEntry(config.tokens, req.headers.authorization);
    if (entry === null) {
      limiter.recordFailure(client);
      audit('reject', { client, status: 401, reason: 'token' });
      return rejectUpgrade(socket, 401, { 'WWW-Authenticate': 'Bearer' });
    }
    // 4. Capacity (FR-5).
    const mine = stats.perIdentity.get(entry.identity) ?? 0;
    if (mine >= limits.maxAgentsPerIdentity || stats.active >= limits.maxAgentsTotal) {
      audit('reject', { client, identity: entry.identity, device: entry.id, status: 429, reason: 'capacity' });
      return rejectUpgrade(socket, 429, { 'Retry-After': '30' });
    }
    // Reserve the slot before the async upgrade so parallel requests cannot pass the cap.
    stats.active += 1;
    stats.perIdentity.set(entry.identity, mine + 1);
    let released = false;
    const release = () => {
      if (released) return;
      released = true;
      stats.active -= 1;
      stats.perIdentity.set(entry.identity, (stats.perIdentity.get(entry.identity) ?? 1) - 1);
    };
    socket.once('close', () => { if (!upgraded) release(); });
    let upgraded = false;
    wss.handleUpgrade(req, socket, head, (ws) => {
      upgraded = true;
      handleConnection(ws, entry, client, release);
    });
  });

  function handleConnection(ws, entry, client, release) {
    const conn = ++connCounter;
    const who = { identity: entry.identity, device: entry.id, client, conn };
    let child;
    try {
      child = spawn(config.agent);
    } catch (err) {
      audit('agent_spawn_failed', { ...who, reason: err.code ?? 'error' });
      release();
      ws.close(CLOSE_AGENT_EXITED, 'agent failed to start');
      return;
    }
    stats.spawned += 1;
    audit('connect', { ...who, pid: child.pid });

    let closed = false;
    const finish = () => {
      if (closed) return;
      closed = true;
      // The slot is released on 'exit', not here: a new agent must not start while this one may
      // still be saving to the shared task store (F-21, D-015).
      if (child.exitCode === null && child.signalCode === null) {
        child.kill('SIGTERM');
        setTimeout(() => { if (child.exitCode === null) child.kill('SIGKILL'); }, KILL_GRACE_MS).unref();
      }
    };

    child.on('error', (err) => {
      audit('agent_error', { ...who, reason: err.code ?? 'error' });
      // A process that failed to spawn never emits 'exit'. One that did spawn is reaped by 'exit'.
      if (child.pid === undefined) release();
      if (ws.readyState === ws.OPEN) ws.close(CLOSE_AGENT_EXITED, 'agent failed to start');
    });
    child.on('exit', (exitCode, signal) => {
      audit('agent_exit', { ...who, exitCode, signal });
      release();
      if (ws.readyState === ws.OPEN) ws.close(CLOSE_AGENT_EXITED, 'agent exited');
      finish();
    });
    child.stdin.on('error', () => {}); // EPIPE after exit is handled by 'exit'
    child.stderr.on('data', () => {}); // drain; agent logs stay on the host

    // Agent -> phone (ARCHITECTURE 2.2).
    const splitter = new LineSplitter(
      limits.maxMessageBytes,
      (line) => {
        let msg;
        try {
          msg = JSON.parse(line);
        } catch {
          audit('agent_noise', who); // non-JSON stdout line, dropped
          return;
        }
        if (typeof msg?.method === 'string') audit('rpc', { ...who, dir: 'out', method: msg.method });
        if (ws.readyState !== ws.OPEN) return;
        ws.send(line);
        // Backpressure: a slow phone must not make the gateway buffer without limit.
        if (ws.bufferedAmount > limits.maxMessageBytes && !child.stdout.isPaused()) {
          child.stdout.pause();
          stats.backpressureEvents += 1;
          const timer = setInterval(() => {
            if (ws.readyState !== ws.OPEN || ws.bufferedAmount <= limits.maxMessageBytes / 2) {
              clearInterval(timer);
              child.stdout.resume();
            }
          }, 20);
        }
      },
      () => {
        audit('agent_line_too_big', who);
        if (ws.readyState === ws.OPEN) ws.close(CLOSE_TOO_BIG, 'agent message too big');
        finish();
      },
    );
    child.stdout.on('data', (chunk) => splitter.push(chunk));

    // Phone -> agent, in order, because the cwd check is async.
    let chain = Promise.resolve();
    ws.on('message', (data, isBinary) => {
      chain = chain.then(() => handleClientMessage(data, isBinary)).catch(() => ws.terminate());
    });

    async function handleClientMessage(data, isBinary) {
      // After a violation the socket is CLOSING: nothing queued behind it may reach the agent.
      if (closed || ws.readyState !== ws.OPEN) return;
      const parsed = parseClientMessage(data, isBinary, limits.maxMessageBytes);
      if (!parsed.ok) {
        audit('protocol_violation', { ...who, code: parsed.closeCode, reason: parsed.reason });
        ws.close(parsed.closeCode, parsed.reason);
        return;
      }
      const { message } = parsed;
      const rejection = await checkCwd(message, await rootsPromise);
      if (rejection) {
        audit('cwd_rejected', { ...who, method: message.method });
        if (!rejection.drop) ws.send(JSON.stringify(rejection));
        return;
      }
      if (ws.readyState !== ws.OPEN) return;
      audit('rpc', { ...who, dir: 'in', method: typeof message.method === 'string' ? message.method : 'response' });
      // Re-serialize: guarantees exactly one line on the agent's stdin.
      const flushed = child.stdin.write(`${JSON.stringify(message)}\n`);
      // Backpressure: stop reading from the phone until the agent drains its stdin.
      if (!flushed && !child.stdin.destroyed) {
        ws.pause();
        stats.backpressureEvents += 1;
        child.stdin.once('drain', () => ws.resume());
      }
    }

    ws.on('close', (code) => {
      audit('disconnect', { ...who, code });
      finish();
    });
    ws.on('error', (err) => audit('ws_error', { ...who, reason: err.code ?? 'error' }));
  }

  return {
    stats,
    listen(port = config.listen.port, host = config.listen.host) {
      return new Promise((resolve, reject) => {
        server.once('error', reject);
        server.listen(port, host, () => resolve(server.address()));
      });
    },
    address: () => server.address(),
    async close() {
      for (const ws of wss.clients) ws.terminate();
      await new Promise((resolve) => server.close(resolve));
    },
    /** Re-read the roots (for tests or after creating a root). */
    refreshRoots() {
      rootsPromise = resolveRoots(config.projects.roots);
      return rootsPromise;
    },
  };
}
