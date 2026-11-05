#!/usr/bin/env node
// An agent that, like Bob saving its task store, keeps running for a while after SIGTERM (F-21).
// It writes "exited" to the file in argv[2] at the moment it really exits.
import { writeFileSync } from 'node:fs';
const marker = process.argv[2];
const delayMs = Number(process.argv[3] ?? 600);
process.on('SIGTERM', () => setTimeout(() => { writeFileSync(marker, 'exited'); process.exit(0); }, delayMs));
process.stdin.resume();
process.stdin.on('end', () => {}); // stdin EOF alone does not end it
