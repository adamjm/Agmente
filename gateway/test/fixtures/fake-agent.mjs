#!/usr/bin/env node
// Fake ACP agent for tests. Speaks line-delimited JSON-RPC on stdin/stdout, like `bob acp`.
// It answers initialize with Bob 2.0.9's captured capabilities (SPEC F-11), and copies the Bob
// behaviour that the live probes recorded (RESULTS 2026-11-06, PLAN 3.1):
//
// - Turns take time. A prompt's text can carry directives:
//     [chunks:N]      stream the reply as N agent_message_chunk updates (default 1)
//     [slow:MS]       wait MS between chunks (default 0)
//     [permission]    before replying, send session/request_permission and wait for the answer
//     [permission:allow-only]  the same, with only allow options (to test a timeout with no reject)
//     [write:NAME]    write the file NAME ("x\n") under the session's cwd before replying
//     [remove:NAME]   remove the file NAME under the session's cwd
//     [symlink:NAME>TARGET]  create a symlink NAME that points at TARGET
//     [edit:NAME]     report a completed file edit (kind edit, a diff as output), for the app's file-change row
//     [image]         send a 160x100 PNG as an image content block
//     [link]          send a resource_link block
//   The reply text is "echo: <prompt text>". session/cancel ends a running turn with "cancelled".
// - session/load and session/resume (F-12): while a turn runs in this process, they are refused with
//   -32600 "Invalid request: Session is already running a prompt" and the turn goes on. When the
//   session is idle, the session is thrown away and rebuilt from the store; the response comes
//   first, then the history is replayed as coalesced session/update notifications: one
//   available_commands_update, then one user_message_chunk or agent_message_chunk per message.
// - Sessions persist across restarts in a JSON store (see --store). Like Bob's task store, the store
//   is read when a session is created, loaded or resumed, and the whole session record is written
//   back at the end of each turn. So two processes on one store lose a write without an error
//   (F-21): the process that saves last overwrites the other's turn.
//
// Arguments (from the gateway config, never from a client):
//   --store <file>   the store; default $HOME/.fake-agent/store.json when HOME is set, else memory only
//   --exit-delay MS  on SIGTERM, keep running for MS (as Bob does while it saves), then exit 0
//   --exit-marker F  write "exited <pid>" to F at the moment the process exits after SIGTERM
// Everything after the known flags is ignored (the env and argv tests pass extra arguments).
//
// Shapes marked "verify" follow the ACP schema and were not seen in a Bob probe:
//   modes.currentModeId, session/list cwd and updatedAt, the permission option list.
import { mkdirSync, readFileSync, renameSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { randomBytes } from 'node:crypto';
import { crc32, deflateSync } from 'node:zlib';
import { createInterface } from 'node:readline';

const fixture = JSON.parse(readFileSync(new URL('./bob-initialize-2.0.9.json', import.meta.url), 'utf8'));

// --- arguments ----------------------------------------------------------------------------------
const argv = process.argv.slice(2);
const storeArg = argv.indexOf('--store');
const storePath = storeArg !== -1 ? argv[storeArg + 1]
  : process.env.HOME ? join(process.env.HOME, '.fake-agent', 'store.json') : null;
const argValue = (name) => (argv.indexOf(name) !== -1 ? argv[argv.indexOf(name) + 1] : undefined);
const exitDelay = Number(argValue('--exit-delay') ?? 0);
const exitMarker = argValue('--exit-marker');
if (exitDelay > 0 || exitMarker) {
  process.on('SIGTERM', () => setTimeout(() => {
    if (exitMarker) writeFileSync(exitMarker, `exited ${process.pid}`);
    process.exit(0);
  }, exitDelay));
}

// --- output -------------------------------------------------------------------------------------
const send = (obj) => process.stdout.write(`${JSON.stringify(obj)}\n`);
const reply = (id, result) => send({ jsonrpc: '2.0', id, result });
const fail = (id, code, message, data) => send({ jsonrpc: '2.0', id, error: data ? { code, message, data } : { code, message } });
const update = (sessionId, u) => send({ jsonrpc: '2.0', method: 'session/update', params: { sessionId, update: u } });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// --- store (F-21: read at open, whole record written at turn end, last writer wins) -------------
let memoryStore = { version: 1, sessions: {} };
function readStore() {
  if (!storePath) return structuredClone(memoryStore);
  try {
    return JSON.parse(readFileSync(storePath, 'utf8'));
  } catch {
    return { version: 1, sessions: {} };
  }
}
function writeStore(store) {
  if (!storePath) {
    memoryStore = structuredClone(store);
    return;
  }
  mkdirSync(dirname(storePath), { recursive: true });
  const tmp = `${storePath}.${process.pid}.tmp`;
  writeFileSync(tmp, JSON.stringify(store));
  renameSync(tmp, storePath);
}
function saveSession(record) {
  const store = readStore();
  store.sessions[record.sessionId] = structuredClone(record);
  writeStore(store);
}
function forgetSession(sessionId) {
  const store = readStore();
  delete store.sessions[sessionId];
  writeStore(store);
}

// --- sessions live in this process --------------------------------------------------------------
const MODES = [
  { id: 'agent', name: 'Agent', description: 'Edits files and runs commands' },
  { id: 'plan', name: 'Plan', description: 'Plans without editing' },
  { id: 'ask', name: 'Ask', description: 'Answers questions only' },
];
const modesOf = (record) => ({ currentModeId: record.mode ?? 'agent', availableModes: MODES }); // currentModeId: verify
const COMMANDS = [{ name: 'init', description: 'Create an AGENTS.md for this project', input: null }];

/** sessionId -> { record, turn: null | { id, cancelled, permission } } */
const live = new Map();
let nextAgentRequestId = 1;
const pendingAgentRequests = new Map(); // agent request id -> resolve(response)

function requestClient(method, params) {
  const id = `agent-${nextAgentRequestId++}`;
  return { id, response: new Promise((resolve) => { pendingAgentRequests.set(id, resolve); send({ jsonrpc: '2.0', id, method, params }); }) };
}

/** A 160x100 PNG with a colour gradient, built here so the fixture needs no binary file. */
function samplePng() {
  const w = 160, h = 100;
  const raw = Buffer.alloc((w * 3 + 1) * h);
  for (let y = 0; y < h; y += 1) {
    const row = y * (w * 3 + 1);
    for (let x = 0; x < w; x += 1) { raw[row + 1 + x * 3] = Math.round((x / w) * 255); raw[row + 2 + x * 3] = Math.round((y / h) * 255); raw[row + 3 + x * 3] = 160; }
  }
  const chunk = (type, data) => {
    const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
    const body = Buffer.concat([Buffer.from(type), data]);
    const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(body) >>> 0);
    return Buffer.concat([len, body, crc]);
  };
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 2;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]).toString('base64');
}

function directives(text) {
  const num = (name, dflt) => {
    const m = new RegExp(`\\[${name}:(\\d+)\\]`).exec(text);
    return m ? Number(m[1]) : dflt;
  };
  const allowOnly = text.includes('[permission:allow-only]');
  const all = (name) => [...text.matchAll(new RegExp(`\\[${name}:([^\\]]+)\\]`, 'g'))].map((m) => m[1]);
  return { edits: all('edit'), image: text.includes('[image]'), link: text.includes('[link]'), writes: all('write'), removes: all('remove'), symlinks: all('symlink').map((v) => v.split('>')), chunks: Math.max(1, num('chunks', 1)), slowMs: num('slow', 0), permission: allowOnly || text.includes('[permission]'), allowOnly };
}

function replay(record) {
  update(record.sessionId, { sessionUpdate: 'available_commands_update', availableCommands: COMMANDS });
  for (const m of record.messages) {
    update(record.sessionId, {
      sessionUpdate: m.role === 'user' ? 'user_message_chunk' : 'agent_message_chunk',
      content: { type: 'text', text: m.text },
    });
  }
}

/** load and resume share Bob's disposeExistingSession path (F-12). */
function reopen(msg) {
  const { sessionId } = msg.params ?? {};
  const current = live.get(sessionId);
  if (current?.turn) {
    fail(msg.id, -32600, 'Invalid request: Session is already running a prompt', { sessionId });
    return;
  }
  const record = readStore().sessions[sessionId];
  if (!record) {
    fail(msg.id, -32602, `Session not found: ${sessionId}`);
    return;
  }
  live.set(sessionId, { record, turn: null });
  reply(msg.id, { modes: modesOf(record) });
  replay(record);
}

async function runTurn(msg, entry) {
  const { record } = entry;
  const text = (msg.params?.prompt ?? []).filter((b) => b?.type === 'text').map((b) => b.text).join('');
  const turn = { id: msg.id, cancelled: false, permission: null };
  entry.turn = turn;
  const firstTurn = record.messages.length === 0;
  record.messages.push({ role: 'user', text });
  const d = directives(text);
  let stopReason = 'end_turn';
  try {
    const root = record.cwd ?? process.cwd();
    for (const name of d.writes) {
      mkdirSync(dirname(join(root, name)), { recursive: true });
      writeFileSync(join(root, name), 'x\n');
    }
    for (const name of d.removes) rmSync(join(root, name), { force: true });
    for (const [name, target] of d.symlinks) symlinkSync(target, join(root, name));
    for (const name of d.edits) {
      const toolCallId = `edit-${randomBytes(3).toString('hex')}`;
      update(record.sessionId, { sessionUpdate: 'tool_call', toolCallId, title: `Edit: ${name}`, kind: 'edit', status: 'in_progress' });
      update(record.sessionId, { sessionUpdate: 'tool_call_update', toolCallId, status: 'completed', content: [{ type: 'content', content: { type: 'text', text: `--- a/${name}\n+++ b/${name}\n@@ -1 +1,2 @@\n one\n+two` } }] });
    }
    if (d.image) update(record.sessionId, { sessionUpdate: 'agent_message_chunk', content: { type: 'image', mimeType: 'image/png', data: samplePng() } });
    if (d.link) update(record.sessionId, { sessionUpdate: 'agent_message_chunk', content: { type: 'resource_link', name: 'report.html', uri: 'https://example.com/report.html', mimeType: 'text/html' } });
    if (d.permission) {
      const toolCallId = `call-${randomBytes(3).toString('hex')}`;
      const toolCall = { toolCallId, title: 'Run echo', kind: 'execute', status: 'pending', rawInput: { command: 'echo fake' } };
      update(record.sessionId, { sessionUpdate: 'tool_call', ...toolCall });
      const req = requestClient('session/request_permission', {
        sessionId: record.sessionId,
        toolCall,
        options: [ // verify against Bob
          { optionId: 'proceed_once', name: 'Allow once', kind: 'allow_once' },
          { optionId: 'proceed_always', name: 'Always allow', kind: 'allow_always' },
          ...(d.allowOnly ? [] : [{ optionId: 'cancel', name: 'Reject', kind: 'reject_once' }]),
        ],
      });
      turn.permission = req.id;
      const answer = await req.response;
      turn.permission = null;
      const outcome = answer.result?.outcome;
      permissionLog.push({ requestId: req.id, response: answer });
      if (turn.cancelled || outcome?.outcome === 'cancelled' || answer.error) {
        update(record.sessionId, { sessionUpdate: 'tool_call_update', toolCallId, status: 'failed' });
        stopReason = 'cancelled';
      } else if (outcome?.outcome === 'selected' && String(outcome.optionId).startsWith('proceed')) {
        update(record.sessionId, { sessionUpdate: 'tool_call_update', toolCallId, status: 'completed', content: [{ type: 'content', content: { type: 'text', text: 'fake' } }] });
      } else {
        update(record.sessionId, { sessionUpdate: 'tool_call_update', toolCallId, status: 'failed' });
      }
    }
    let said = '';
    if (stopReason === 'end_turn') {
      const full = `echo: ${text}`;
      const size = Math.ceil(full.length / d.chunks);
      for (let i = 0; i < d.chunks; i += 1) {
        if (turn.cancelled) {
          stopReason = 'cancelled';
          break;
        }
        const part = full.slice(i * size, (i + 1) * size);
        said += part;
        update(record.sessionId, { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: part } });
        if (d.slowMs > 0 && i < d.chunks - 1) await sleep(d.slowMs);
      }
      if (turn.cancelled) stopReason = 'cancelled';
    }
    if (said) record.messages.push({ role: 'agent', text: said });
    if (firstTurn) {
      record.title = text.slice(0, 50);
      update(record.sessionId, { sessionUpdate: 'session_info_update', title: record.title });
    }
    record.updatedAt = new Date().toISOString();
    saveSession(record); // whole record: last writer wins (F-21)
  } finally {
    entry.turn = null;
  }
  reply(msg.id, { stopReason });
}

// --- handlers -----------------------------------------------------------------------------------
const received = [];
const responses = [];
const permissionLog = [];

const handlers = {
  initialize: (msg) => reply(msg.id, fixture.result),
  'session/new': (msg) => {
    const record = {
      sessionId: `sess-${randomBytes(8).toString('hex')}`,
      cwd: msg.params?.cwd ?? null,
      title: null,
      mode: msg.params?._meta?.['bob/mode'] ?? 'agent',
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
      messages: [],
    };
    live.set(record.sessionId, { record, turn: null });
    saveSession(record);
    reply(msg.id, { sessionId: record.sessionId, modes: modesOf(record) });
  },
  'session/load': reopen,
  'session/resume': reopen,
  'session/prompt': (msg) => {
    const entry = live.get(msg.params?.sessionId);
    if (!entry) return fail(msg.id, -32602, `Session not found: ${msg.params?.sessionId}`);
    if (entry.turn) return fail(msg.id, -32600, 'Invalid request: Session is already running a prompt', { sessionId: entry.record.sessionId });
    runTurn(msg, entry);
  },
  'session/cancel': (msg) => {
    const entry = live.get(msg.params?.sessionId);
    if (!entry?.turn) return;
    entry.turn.cancelled = true;
    // ACP: the client answers pending permission requests with cancelled; stop waiting either way.
    const waiting = entry.turn.permission && pendingAgentRequests.get(entry.turn.permission);
    if (waiting) {
      pendingAgentRequests.delete(entry.turn.permission);
      waiting({ result: { outcome: { outcome: 'cancelled' } } });
    }
  },
  'session/list': (msg) => {
    const sessions = Object.values(readStore().sessions)
      .map((r) => ({ sessionId: r.sessionId, cwd: r.cwd, title: r.title, updatedAt: r.updatedAt })) // cwd, updatedAt: verify
      .sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
    reply(msg.id, { sessions });
  },
  'session/delete': (msg) => {
    const { sessionId } = msg.params ?? {};
    if (live.get(sessionId)?.turn) return fail(msg.id, -32600, 'Invalid request: Session is already running a prompt', { sessionId });
    live.delete(sessionId);
    forgetSession(sessionId);
    reply(msg.id, {});
  },
  // session/close (sessionCapabilities.close in Bob 2.0.9's initialize): the session leaves this
  // process; its store record stays, so a later load opens it again. Behaviour during a turn: verify.
  'session/close': (msg) => {
    const { sessionId } = msg.params ?? {};
    if (live.get(sessionId)?.turn) return fail(msg.id, -32600, 'Invalid request: Session is already running a prompt', { sessionId });
    live.delete(sessionId);
    reply(msg.id, {});
  },
  'session/set_mode': (msg) => {
    const entry = live.get(msg.params?.sessionId);
    if (!entry) return fail(msg.id, -32602, `Session not found: ${msg.params?.sessionId}`);
    if (!MODES.some((m) => m.id === msg.params?.modeId)) return fail(msg.id, -32602, `Unknown mode: ${msg.params?.modeId}`);
    entry.record.mode = msg.params.modeId;
    reply(msg.id, {});
    update(entry.record.sessionId, { sessionUpdate: 'current_mode_update', currentModeId: entry.record.mode });
  },

  // Test-only methods.
  '_test/echo': (msg) => reply(msg.id, msg.params ?? null),
  // Names of every variable, and values only for AGMENTE_TEST_* names.
  '_test/env': (msg) => reply(msg.id, {
    names: Object.keys(process.env).sort(),
    values: Object.fromEntries(Object.entries(process.env).filter(([k]) => k.startsWith('AGMENTE_TEST_'))),
  }),
  '_test/argv': (msg) => reply(msg.id, { args: process.argv.slice(2) }),
  '_test/received': (msg) => reply(msg.id, { methods: received }),
  '_test/responses': (msg) => reply(msg.id, { responses }),
  '_test/permissions': (msg) => reply(msg.id, { answers: permissionLog }),
  // Send the client a request (for example fs/read_text_file) and reply with its response.
  '_test/ask-client': async (msg) => {
    const req = requestClient(msg.params.method, msg.params.params ?? {});
    reply(msg.id, { response: await req.response });
  },
  '_test/state': (msg) => reply(msg.id, {
    pid: process.pid,
    cwd: process.cwd(),
    home: process.env.HOME ?? null,
    store: storePath,
    live: [...live.values()].map((e) => ({ sessionId: e.record.sessionId, running: !!e.turn, messages: e.record.messages.length })),
  }),
  // Write raw stdout parts with a delay between them, then reply.
  '_test/chunks': async (msg) => {
    for (const part of msg.params.parts) {
      process.stdout.write(part);
      await sleep(msg.params.delayMs ?? 0);
    }
    reply(msg.id, { ok: true });
  },
  '_test/big': (msg) => {
    process.stdout.write(`${JSON.stringify({ jsonrpc: '2.0', method: '_test/blob', params: { pad: 'x'.repeat(msg.params.bytes) } })}\n`);
  },
  '_test/noise': (msg) => {
    process.stdout.write('log: this line is not JSON\n');
    reply(msg.id, { ok: true });
  },
  '_test/exit': () => process.exit(3),
  '_test/say-and-exit': (msg) => process.stdout.write(`${JSON.stringify({ jsonrpc: '2.0', id: msg.id, result: { bye: true } })}\n`, () => process.exit(0)),
  '_test/ignore-sigterm': (msg) => {
    process.on('SIGTERM', () => {});
    reply(msg.id, { ok: true });
  },
  // Stop reading stdin for `ms`, so the gateway sees backpressure.
  '_test/stall': (msg) => {
    rl.pause();
    setTimeout(() => {
      rl.resume();
      reply(msg.id, { stalled: msg.params.ms });
    }, msg.params.ms);
  },
};

const rl = createInterface({ input: process.stdin });
rl.on('line', (line) => {
  let msg;
  try {
    msg = JSON.parse(line);
  } catch {
    return;
  }
  if (typeof msg.method === 'string') {
    received.push(msg.method);
  } else if (msg.id !== undefined) {
    responses.push(msg);
    const waiting = pendingAgentRequests.get(msg.id);
    if (waiting) {
      pendingAgentRequests.delete(msg.id);
      waiting(msg);
    }
    return;
  }
  const handler = handlers[msg.method];
  if (handler) handler(msg);
  else if (msg.id !== undefined && msg.method) fail(msg.id, -32601, 'Method not found');
});
rl.on('close', () => process.exit(0));
