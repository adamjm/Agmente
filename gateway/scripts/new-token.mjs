#!/usr/bin/env node
// Print a new random token once, and the config entry that holds only its hash.
// Usage: node scripts/new-token.mjs <device-id> <identity>
import { randomBytes, createHash } from 'node:crypto';

const [id, identity] = process.argv.slice(2);
if (!id || !identity) {
  process.stderr.write('Usage: node scripts/new-token.mjs <device-id> <identity>\n');
  process.exit(2);
}
const token = randomBytes(32).toString('base64url'); // 256 bits
const sha256 = createHash('sha256').update(token, 'utf8').digest('hex');

process.stderr.write('Copy the token into the app now. It is not stored anywhere and is shown once.\n');
process.stdout.write(`token: ${token}\n`);
process.stdout.write(`config entry: ${JSON.stringify({ id, identity, sha256 })}\n`);
