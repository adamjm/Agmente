#!/usr/bin/env node
// Measure NFR-1 (T-11) and NFR-2 (T-12). Prints JSON. Exit 1 if a limit is missed.
// Usage: node test/bench.mjs [--calls 2000] [--rejects 500]
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { parseArgs } from 'node:util';
import { auth, connect, FAKE_AGENT, startGateway } from './helpers.mjs';

const { values } = parseArgs({
  options: { calls: { type: 'string', default: '2000' }, rejects: { type: 'string', default: '500' } },
});
const CALLS = Number(values.calls);
const REJECTS = Number(values.rejects);
const WARMUP = 200;
const PAYLOAD = { pad: 'x'.repeat(1024 - 60) }; // about 1 KiB on the wire

const pct = (arr, p) => {
  const s = [...arr].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.ceil((p / 100) * s.length) - 1)];
};
const ms = (ns) => Number(ns) / 1e6;
const round = (x) => Math.round(x * 1000) / 1000;

async function directRtts() {
  const child = spawn(process.execPath, [FAKE_AGENT], { stdio: ['pipe', 'pipe', 'inherit'] });
  const rl = createInterface({ input: child.stdout });
  const waiting = new Map();
  rl.on('line', (line) => {
    const msg = JSON.parse(line);
    waiting.get(msg.id)?.(msg);
  });
  const call = (id) => new Promise((resolve) => {
    waiting.set(id, resolve);
    child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id, method: '_test/echo', params: PAYLOAD })}\n`);
  });
  const rtts = [];
  for (let i = 0; i < WARMUP + CALLS; i += 1) {
    const t0 = process.hrtime.bigint();
    await call(i);
    if (i >= WARMUP) rtts.push(ms(process.hrtime.bigint() - t0));
  }
  child.kill();
  return rtts;
}

async function gatewayRtts(url) {
  const { ws } = await connect(url, auth());
  const waiting = new Map();
  ws.on('message', (d) => {
    const msg = JSON.parse(d.toString());
    waiting.get(msg.id)?.(msg);
  });
  const call = (id) => new Promise((resolve) => {
    waiting.set(id, resolve);
    ws.send(JSON.stringify({ jsonrpc: '2.0', id, method: '_test/echo', params: PAYLOAD }));
  });
  const rtts = [];
  for (let i = 0; i < WARMUP + CALLS; i += 1) {
    const t0 = process.hrtime.bigint();
    await call(i);
    if (i >= WARMUP) rtts.push(ms(process.hrtime.bigint() - t0));
  }
  ws.close();
  return rtts;
}

async function rejectLatencies(url) {
  const out = [];
  for (let i = 0; i < REJECTS; i += 1) {
    const t0 = process.hrtime.bigint();
    const res = await connect(url, {}); // no token; failures are per address, so raise the limit below
    if (res.status !== 401) throw new Error(`expected 401, got ${res.status}`);
    out.push(ms(process.hrtime.bigint() - t0));
  }
  return out;
}

const gw = await startGateway({ limits: { authFailuresPerWindow: REJECTS + 10 } });
try {
  const direct = await directRtts();
  const viaGateway = await gatewayRtts(gw.url);
  const rejects = await rejectLatencies(gw.url);
  const result = {
    node: process.version,
    calls: CALLS,
    messageBytes: JSON.stringify({ jsonrpc: '2.0', id: 1, method: '_test/echo', params: PAYLOAD }).length,
    directMs: { p50: round(pct(direct, 50)), p95: round(pct(direct, 95)) },
    gatewayMs: { p50: round(pct(viaGateway, 50)), p95: round(pct(viaGateway, 95)) },
    overheadP95Ms: round(pct(viaGateway, 95) - pct(direct, 95)),
    rejectMs: { n: REJECTS, p50: round(pct(rejects, 50)), p95: round(pct(rejects, 95)) },
    spawnedDuringRejects: gw.gateway.stats.spawned - 1, // 1 = the measured gateway connection
  };
  result.nfr1 = result.rejectMs.p95 <= 50 ? 'PASS' : 'FAIL';
  result.nfr2 = result.overheadP95Ms <= 5 ? 'PASS' : 'FAIL';
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  process.exitCode = result.nfr1 === 'PASS' && result.nfr2 === 'PASS' ? 0 : 1;
} finally {
  await gw.stop();
}
