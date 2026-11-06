// T-30 / NFR-8: `_agmente/git/status` on a generated 10,000-file repository, 20 runs, p95 <= 1 s.
//   node test/bench-git.mjs                       host runner (git in the project folder)
//   node test/bench-git.mjs --podman IMAGE        podman runner: each call is a container (D-034)
//   options: --files 10000 --runs 20
// Same gateway binary as the wire tests (AGMENTE_GATEWAY_CMD). Prints one JSON line.
import { execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { auth, connect, rpc, startGateway } from './helpers.mjs';

const arg = (name, fallback) => { const i = process.argv.indexOf(name); return i === -1 ? fallback : process.argv[i + 1]; };
const files = Number(arg('--files', 10000));
const runs = Number(arg('--runs', 20));
const image = arg('--podman', null);

const gw = await startGateway({}, {
  configFn: (dirs, config) => { if (image) config.runner = { kind: 'podman', image, podman: process.env.PODMAN ?? '/opt/podman/bin/podman' }; },
});
try {
  const ws = (await connect(gw.url, auth())).ws;
  // Register the project only: no session, so no agent starts (git needs none, D-034).
  const project = (await rpc(ws, '_agmente/projects/create', { name: 'bench', path: gw.dirs.project })).result.project;
  const dir = gw.dirs.project;
  const git = (...args) => execFileSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@t', ...args], { cwd: dir, stdio: 'pipe' });
  git('init', '-q', '-b', 'main');
  for (let d = 0; d < 100; d += 1) {
    mkdirSync(join(dir, `d${d}`));
    for (let f = 0; f < files / 100; f += 1) writeFileSync(join(dir, `d${d}`, `f${f}.txt`), `file ${d}/${f}\n`);
  }
  git('add', '.');
  git('commit', '-q', '-m', 'many');
  for (let d = 0; d < 10; d += 1) writeFileSync(join(dir, `d${d}`, 'f0.txt'), 'changed\n'); // a dirty tree
  writeFileSync(join(dir, 'new.txt'), 'new\n');

  const times = [];
  for (let i = 0; i < runs + 1; i += 1) { // the first run warms caches and is not counted
    const t0 = performance.now();
    const res = await rpc(ws, '_agmente/git/status', { projectId: project.id });
    const ms = performance.now() - t0;
    if (!res.result || res.result.files.length !== 11) throw new Error(`bad status: ${JSON.stringify(res).slice(0, 200)}`);
    if (i > 0) times.push(ms);
  }
  times.sort((a, b) => a - b);
  const p = (q) => times[Math.min(times.length - 1, Math.ceil(q * times.length) - 1)];
  const out = { runner: image ? 'podman' : 'host', files, runs, p50_ms: +p(0.5).toFixed(1), p95_ms: +p(0.95).toFixed(1), max_ms: +times.at(-1).toFixed(1), pass: p(0.95) <= 1000 };
  console.log(JSON.stringify(out));
  ws.close();
  process.exitCode = out.pass ? 0 : 1;
} finally {
  await gw.stop();
}
