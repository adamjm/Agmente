#!/usr/bin/env node
// Cross-check the docs so they stay consistent as phases change them:
// - every test in SPEC section 7 is scheduled in PLAN,
// - PLAN, RESULTS and ARCHITECTURE cite only tests, requirements and decisions that exist,
// - every open question in SPEC section 8 maps to a test,
// - every requirement has a priority and every NFR has a number.
import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const read = (p) => readFileSync(join(root, p), 'utf8');
const errors = [];

const spec = read('docs/SPEC.md');
const plan = read('docs/PLAN.md');
const decisions = read('docs/DECISIONS.md');
const architecture = read('docs/ARCHITECTURE.md');
const results = existsSync(join(root, 'docs/RESULTS.md')) ? read('docs/RESULTS.md') : '';

const section = (text, heading) => {
  const start = text.indexOf(heading);
  if (start === -1) return '';
  const next = text.indexOf('\n## ', start + heading.length);
  return text.slice(start, next === -1 ? undefined : next);
};

const rowIds = (text, prefix) =>
  [...text.matchAll(new RegExp(`^\\|\\s*(${prefix}-\\d+)\\s*\\|`, 'gm'))].map((m) => m[1]);
const cited = (text, prefix) => new Set([...text.matchAll(new RegExp(`\\b(${prefix}-\\d+)\\b`, 'g'))].map((m) => m[1]));

const tests = new Set(rowIds(section(spec, '## 7. Test plan'), 'T'));
const frs = rowIds(section(spec, '### 4.1 Functional'), 'FR');
const nfrs = rowIds(section(spec, '### 4.2 Non-functional'), 'NFR');
const decisionIds = new Set([...decisions.matchAll(/^## (D-\d{3})/gm)].map((m) => m[1]));

if (tests.size === 0) errors.push('SPEC section 7 has no test rows');

// Sequential IDs.
const checkSequence = (ids, prefix) => ids.forEach((id, i) => {
  if (id !== `${prefix}-${i + 1}`) errors.push(`${prefix} IDs are not sequential at ${id} (expected ${prefix}-${i + 1})`);
});
checkSequence([...tests], 'T');
checkSequence(frs, 'FR');
checkSequence(nfrs, 'NFR');

// Every test is scheduled by a task line in PLAN ("- [ ] ..."). Goal lines with ranges do not count.
const taskLines = plan.split('\n').filter((l) => /^- \[[ x!]\]/.test(l)).join('\n');
for (const t of tests) if (!cited(taskLines, 'T').has(t)) errors.push(`${t} is not scheduled by a task in docs/PLAN.md`);

// Citations point at things that exist.
const known = { T: tests, FR: new Set(frs), NFR: new Set(nfrs), D: decisionIds };
for (const [name, text] of [['PLAN', plan], ['RESULTS', results], ['ARCHITECTURE', architecture], ['SPEC', spec]]) {
  for (const prefix of ['T', 'FR', 'NFR']) {
    for (const id of cited(text, prefix)) if (!known[prefix].has(id)) errors.push(`docs/${name}.md cites unknown ${id}`);
  }
  for (const id of [...text.matchAll(/\b(D-\d{3})\b/g)].map((m) => m[1])) {
    if (!decisionIds.has(id)) errors.push(`docs/${name}.md cites unknown ${id}`);
  }
}

// Priorities and numbers.
for (const line of section(spec, '### 4.1 Functional').split('\n').filter((l) => /^\|\s*FR-\d+/.test(l))) {
  if (!/\|\s*(Must|Should|Could)\s*\|/.test(line)) errors.push(`no priority: ${line.slice(0, 60)}`);
}
for (const line of section(spec, '### 4.2 Non-functional').split('\n').filter((l) => /^\|\s*NFR-\d+/.test(l))) {
  if (!/\d/.test(line.replace(/NFR-\d+/, ''))) errors.push(`NFR without a number: ${line.slice(0, 60)}`);
}

// Open questions map to tests.
for (const line of section(spec, '## 8. Risks and open questions').split('\n').filter((l) => /^\|\s*Q-\d+/.test(l))) {
  if (!/T-\d+/.test(line)) errors.push(`open question without a test: ${line.slice(0, 60)}`);
}

if (errors.length > 0) {
  console.error(errors.map((e) => `- ${e}`).join('\n'));
  process.exit(1);
}
console.log(`ok  ${tests.size} tests, ${frs.length} FRs, ${nfrs.length} NFRs, ${decisionIds.size} decisions; all tests scheduled`);
