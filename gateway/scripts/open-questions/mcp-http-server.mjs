#!/usr/bin/env node
// Local streamable-HTTP MCP server for the Bob open-question probe (Q-3 / T-42). Usage:
//   node mcp-http-server.mjs <port>
// It listens on 127.0.0.1 only and exposes one tool, `ping_http`, which returns "http-pong".
// Every request prints `REQ <method>` on stdout, so the probe can see when Bob connects and what it asks.
import { createServer } from 'node:http';

const port = Number(process.argv[2] ?? 8931);
const tools = [{ name: 'ping_http', description: 'Returns the text http-pong. Takes no arguments.', inputSchema: { type: 'object', properties: {} } }];

const server = createServer((req, res) => {
  if (req.method !== 'POST') {
    res.writeHead(405, { Allow: 'POST' }).end();
    return;
  }
  let body = '';
  req.on('data', (c) => { body += c; });
  req.on('end', () => {
    let msg;
    try { msg = JSON.parse(body); } catch { res.writeHead(400).end(); return; }
    console.log(`REQ ${msg.method}`);
    if (msg.id === undefined) { res.writeHead(202).end(); return; } // notification
    const reply = (payload) => {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ jsonrpc: '2.0', id: msg.id, ...payload }));
    };
    switch (msg.method) {
      case 'initialize':
        reply({ result: { protocolVersion: msg.params?.protocolVersion ?? '2025-06-18', capabilities: { tools: {} }, serverInfo: { name: 'probe-http', version: '0.1.0' } } });
        break;
      case 'tools/list':
        reply({ result: { tools } });
        break;
      case 'tools/call':
        reply({ result: { content: [{ type: 'text', text: 'http-pong' }], isError: false } });
        break;
      case 'ping':
        reply({ result: {} });
        break;
      default:
        reply({ error: { code: -32601, message: 'method not found' } });
    }
  });
});

server.listen(port, '127.0.0.1', () => console.log(`LISTENING ${port}`));
