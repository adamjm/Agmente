#!/usr/bin/env node
// Fake ACP agent for tests. Speaks line-delimited JSON-RPC on stdin/stdout.
// It answers initialize with Bob 2.0.9's captured capabilities (SPEC F-11).
// Phase 3 (task 3.1) extends it with Bob's turn, permission and load behaviour.
import { readFileSync } from 'node:fs';
import { createInterface } from 'node:readline';

const fixture = JSON.parse(readFileSync(new URL('./bob-initialize-2.0.9.json', import.meta.url), 'utf8'));
let sessionCounter = 0;

const send = (obj) => process.stdout.write(`${JSON.stringify(obj)}\n`);
const reply = (id, result) => send({ jsonrpc: '2.0', id, result });

const handlers = {
  initialize: (msg) => reply(msg.id, fixture.result),
  'session/new': (msg) => reply(msg.id, { sessionId: `sess-${++sessionCounter}` }),
  'session/prompt': (msg) => {
    const text = msg.params?.prompt?.find?.((b) => b.type === 'text')?.text ?? '';
    send({
      jsonrpc: '2.0',
      method: 'session/update',
      params: {
        sessionId: msg.params?.sessionId,
        update: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: `echo: ${text}` } },
      },
    });
    reply(msg.id, { stopReason: 'end_turn' });
  },
  // Test-only methods.
  '_test/echo': (msg) => reply(msg.id, msg.params ?? null),
  '_test/env': (msg) => reply(msg.id, { names: Object.keys(process.env).sort() }),
  '_test/received': (msg) => reply(msg.id, { methods: received }),
  '_test/big': (msg) => {
    process.stdout.write(`${JSON.stringify({ jsonrpc: '2.0', method: '_test/blob', params: { pad: 'x'.repeat(msg.params.bytes) } })}\n`);
  },
  '_test/noise': (msg) => {
    process.stdout.write('log: this line is not JSON\n');
    reply(msg.id, { ok: true });
  },
  '_test/exit': () => process.exit(3),
  // Stop reading stdin for `ms`, so the gateway sees backpressure.
  '_test/stall': (msg) => {
    rl.pause();
    setTimeout(() => {
      rl.resume();
      reply(msg.id, { stalled: msg.params.ms });
    }, msg.params.ms);
  },
};

const received = [];
const rl = createInterface({ input: process.stdin });
rl.on('line', (line) => {
  let msg;
  try {
    msg = JSON.parse(line);
  } catch {
    return;
  }
  if (typeof msg.method === 'string') received.push(msg.method);
  const handler = handlers[msg.method];
  if (handler) handler(msg);
  else if (msg.id !== undefined && msg.method) send({ jsonrpc: '2.0', id: msg.id, error: { code: -32601, message: 'Method not found' } });
});
