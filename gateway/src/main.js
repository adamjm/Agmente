#!/usr/bin/env node
// Gateway entry point. Usage: node src/main.js --config <file> [--dry-run]
import { parseArgs } from 'node:util';
import { existsSync } from 'node:fs';
import { ConfigError, loadConfig } from './config.js';
import { createGateway } from './server.js';
import { createAudit } from './audit.js';

const { values } = parseArgs({
  options: { config: { type: 'string' }, 'dry-run': { type: 'boolean', default: false } },
  strict: true,
});

if (!values.config) {
  process.stderr.write('Usage: node src/main.js --config <file> [--dry-run]\n');
  process.exit(2);
}

let config;
try {
  config = loadConfig(values.config);
} catch (err) {
  process.stderr.write(`${err instanceof ConfigError ? err.message : err.stack}\n`);
  process.exit(1);
}

if (values['dry-run']) {
  // Print a summary without token hashes.
  const summary = {
    listen: `${config.listen.host}:${config.listen.port}`,
    trustProxy: config.trustProxy,
    tokens: config.tokens.map((t) => `${t.id} (${t.identity})`),
    agentCommand: config.agent.command.join(' '),
    envPassthrough: config.agent.envPassthrough,
    roots: config.projects.roots.map((r) => `${r}${existsSync(r) ? '' : ' (missing: no cwd will be allowed)'}`),
    limits: config.limits,
  };
  process.stdout.write(`${JSON.stringify(summary, null, 2)}\nConfig OK (dry run).\n`);
  process.exit(0);
}

const audit = createAudit();
const gateway = createGateway(config, { audit });
const address = await gateway.listen();
audit('listening', { reason: `${address.address}:${address.port}` });

for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, async () => {
    audit('shutdown', { signal });
    await gateway.close();
    process.exit(0);
  });
}
