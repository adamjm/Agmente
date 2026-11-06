#!/usr/bin/env node
// Tiny stdio MCP server for the Bob open-question probe (Q-2 / T-39). No dependencies: it speaks
// newline-delimited JSON-RPC 2.0 by hand, as MCP stdio does. One tool, `make_image`, returns text
// and a 1x1 PNG as MCP `image` content. It does nothing else and reads no files.
import { createInterface } from 'node:readline';

const PNG = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';
const write = (m) => process.stdout.write(`${JSON.stringify(m)}\n`);

createInterface({ input: process.stdin }).on('line', (line) => {
  let msg;
  try { msg = JSON.parse(line); } catch { return; }
  if (msg.id === undefined) return; // notifications (initialized, cancelled) need no answer
  process.stderr.write(`probe-image: ${msg.method}\n`);
  switch (msg.method) {
    case 'initialize':
      write({ jsonrpc: '2.0', id: msg.id, result: { protocolVersion: msg.params?.protocolVersion ?? '2025-06-18', capabilities: { tools: {} }, serverInfo: { name: 'probe-image', version: '0.1.0' } } });
      break;
    case 'tools/list':
      write({ jsonrpc: '2.0', id: msg.id, result: { tools: [{ name: 'make_image', description: 'Returns a small PNG image. Takes no arguments.', inputSchema: { type: 'object', properties: {} } }] } });
      break;
    case 'tools/call':
      if (msg.params?.name === 'make_image') {
        write({ jsonrpc: '2.0', id: msg.id, result: { content: [{ type: 'text', text: 'Here is the image.' }, { type: 'image', data: PNG, mimeType: 'image/png' }], isError: false } });
      } else {
        write({ jsonrpc: '2.0', id: msg.id, error: { code: -32602, message: 'unknown tool' } });
      }
      break;
    case 'ping':
      write({ jsonrpc: '2.0', id: msg.id, result: {} });
      break;
    default:
      write({ jsonrpc: '2.0', id: msg.id, error: { code: -32601, message: 'method not found' } });
  }
});
