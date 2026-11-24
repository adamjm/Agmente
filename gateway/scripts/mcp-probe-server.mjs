#!/usr/bin/env node
// Minimal MCP server for the srt runner checks (docs/research/srt-test-plan.md, item 3).
//   stdio: node mcp-probe-server.mjs stdio <reportFile>
//   http : node mcp-probe-server.mjs http <port> <reportFile>      (Streamable HTTP, JSON replies)
// One tool, `report`. When it is called the server tries what a sandboxed server may or may not do and
// writes the outcome as JSON to <reportFile> (a path the server may or may not be able to write; the
// http server runs on the host and always can). It never prints secrets: the SECRET variable is
// reported as present or absent and its length.
import { createServer } from 'node:http';
import { appendFileSync, existsSync, mkdirSync, readdirSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const [mode, ...rest] = process.argv.slice(2);
const reportFile = mode === 'http' ? rest[1] : rest[0];

const TOOL = { name: 'report', description: 'Report what this MCP server process can do. Takes no arguments.', inputSchema: { type: 'object', properties: {} } };

async function probe() {
  const out = { mode, pid: process.pid, cwd: process.cwd(), home: process.env.HOME, secretLength: (process.env.SECRET ?? '').length };
  const t = (f) => { try { return f(); } catch (e) { return `denied: ${e.code ?? e.message}`; } };
  out.envProxy = Object.fromEntries(Object.entries(process.env).filter(([k]) => /proxy|^NODE_USE_ENV_PROXY$|^SANDBOX|^SRT/i.test(k)).map(([k, v]) => [k, String(v).slice(0, 60)]));
  out.envNames = Object.keys(process.env).sort().join(',');
  out.listHome = t(() => `ok ${readdirSync(process.env.REAL_HOME ?? '/Users/adammakarucha').length}`); // the gateway user's real home
  out.listSsh = t(() => `ok ${readdirSync(join(process.env.REAL_HOME ?? '/Users/adammakarucha', '.ssh')).length}`);
  out.writeTmpdir = t(() => { writeFileSync(join(process.env.TMPDIR ?? '/tmp', 'probe.txt'), 'x'); return 'ok'; });
  out.writeHomeCache = t(() => { const d = join(process.env.REAL_HOME ?? '/Users/adammakarucha', '.cache', 'acpcode-probe'); mkdirSync(d, { recursive: true }); writeFileSync(join(d, 'x'), 'x'); return 'ok'; });
  out.writeCwd = t(() => { writeFileSync(join(process.cwd(), 'probe-cwd.txt'), 'x'); return 'ok'; });
  out.writeGitConfig = t(() => { appendFileSync(join(process.cwd(), '.git', 'config'), '\n'); return 'ok'; });
  for (const [key, url] of [['fetchExample', 'https://example.com/'], ['fetchDeepwiki', 'https://mcp.deepwiki.com/']]) {
    try { const r = await fetch(url, { method: 'GET', signal: AbortSignal.timeout(6000) }); out[key] = `http ${r.status}`; } catch (e) { out[key] = `failed: ${e.cause?.code ?? e.name}`; }
  }
  try { const r = await fetch('http://127.0.0.1:9/', { signal: AbortSignal.timeout(3000) }); out.fetchLoopback = `http ${r.status}`; } catch (e) { out.fetchLoopback = `failed: ${e.cause?.code ?? e.name}`; }
  return out;
}

async function handle(msg) {
  switch (msg.method) {
    case 'initialize':
      return { protocolVersion: msg.params?.protocolVersion ?? '2025-03-26', capabilities: { tools: {} }, serverInfo: { name: 'probe', version: '1.0.0' } };
    case 'tools/list':
      return { tools: [TOOL] };
    case 'tools/call': {
      const out = await probe();
      try { appendFileSync(reportFile, `${JSON.stringify(out)}\n`); } catch (e) { out.reportWrite = `denied: ${e.code}`; }
      return { content: [{ type: 'text', text: `probe done: ${JSON.stringify(out).slice(0, 600)}` }] };
    }
    case 'ping':
      return {};
    default:
      return undefined;
  }
}
const reply = (id, result) => ({ jsonrpc: '2.0', id, result });

if (mode === 'stdio') {
  try { appendFileSync(reportFile, `${JSON.stringify({ started: true, mode, cwd: process.cwd(), secretLength: (process.env.SECRET ?? '').length })}\n`); } catch { /* the sandbox may refuse */ }
  let buf = '';
  process.stdin.on('data', async (d) => {
    buf += d.toString();
    let i;
    while ((i = buf.indexOf('\n')) !== -1) {
      const line = buf.slice(0, i); buf = buf.slice(i + 1);
      let msg; try { msg = JSON.parse(line); } catch { continue; }
      if (msg.id === undefined) continue;
      const result = await handle(msg);
      process.stdout.write(`${JSON.stringify(result === undefined ? { jsonrpc: '2.0', id: msg.id, error: { code: -32601, message: 'no such method' } } : reply(msg.id, result))}\n`);
    }
  });
  process.stdin.on('end', () => process.exit(0));
} else if (mode === 'http') {
  const port = Number(rest[0]);
  createServer((req, res) => {
    appendFileSync(reportFile, `${JSON.stringify({ req: req.method, url: req.url, host: req.headers.host, via: req.headers.via ?? null, ua: req.headers['user-agent'] ?? null, ver: req.headers['mcp-protocol-version'] ?? null, accept: req.headers.accept ?? null })}\n`);
    if (req.method !== 'POST') { res.writeHead(405).end(); return; }
    let body = '';
    req.on('data', (d) => { body += d; });
    req.on('end', async () => {
      let msg; try { msg = JSON.parse(body); } catch { res.writeHead(400).end(); return; }
      if (msg.id === undefined) { res.writeHead(202).end(); return; }
      appendFileSync(reportFile, `${JSON.stringify({ http: msg.method, at: Date.now() })}\n`);
      const result = await handle(msg);
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify(result === undefined ? { jsonrpc: '2.0', id: msg.id, error: { code: -32601, message: 'no such method' } } : reply(msg.id, result)));
    });
  }).listen(port, '127.0.0.1', () => console.error(`listening ${port}`));
} else {
  console.error('usage: stdio <report> | http <port> <report>');
  process.exit(2);
}
