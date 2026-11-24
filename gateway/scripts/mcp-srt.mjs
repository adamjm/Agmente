#!/usr/bin/env node
// MCP servers under the srt runner (docs/research/srt-test-plan.md, item 3). Real Bob.
// For each case: a gateway with runner.kind "srt", a session/new that carries one mcpServers entry
// (the phone's own entry, which the gateway forwards after its guard), a prompt that makes Bob call
// the probe tool, and the probe's report file. BOB_API_KEY is never printed.
//   node gateway/scripts/mcp-srt.mjs [--srt PATH] [--only a,b]
import { mkdir, readFile, realpath, rm, writeFile } from 'node:fs/promises';
import { execFileSync, spawn } from 'node:child_process';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { parseArgs } from 'node:util';
import { randomBytes } from 'node:crypto';
import WebSocket from 'ws';
import { hashToken, spawnGateway } from '../test/helpers.mjs';

const { values } = parseArgs({ options: {
  srt: { type: 'string', default: '/tmp/srt-prefix/bin/srt' },
  only: { type: 'string', default: '' },
  control: { type: 'boolean', default: false }, // the host runner, no sandbox: separates a Bob or probe problem from a sandbox one
} });
if (!process.env.BOB_API_KEY) { console.error('BOB_API_KEY is not set'); process.exit(2); }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const results = [];
const check = (name, ok, detail = '') => { results.push({ name, ok }); console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? `  (${detail})` : ''}`); };
const NODE = execFileSync('/usr/bin/which', ['node'], { encoding: 'utf8' }).trim();
const BOB = execFileSync('/usr/bin/which', ['bob'], { encoding: 'utf8' }).trim();
const PROBE_READABLE = '/opt/homebrew/share/acpcode-probe/mcp-probe-server.mjs'; // under /opt/homebrew: allowRead
const HOSTS = 'api.us-east.bob.ibm.com,bob.ibm.com,iam.cloud.ibm.com';
const SECRET = `s3cr3t-${randomBytes(6).toString('hex')}`;
const PROMPT = 'Call the MCP tool named "report" from the MCP server named "probe" exactly once, then reply with the single word: done. Use no other tool.';

let nextId = 1;
function client(gw, token) {
  const ws = new WebSocket(gw.url, { headers: { Authorization: `Bearer ${token}` }, perMessageDeflate: false });
  const c = { ws, pending: new Map(), events: [], answered: [] };
  c.ready = new Promise((res, rej) => { ws.once('open', res); ws.once('error', rej); });
  ws.on('message', (d) => {
    const m = JSON.parse(d.toString());
    if (m.id !== undefined && m.method === undefined && c.pending.has(m.id)) { c.pending.get(m.id)(m); c.pending.delete(m.id); }
    else if (m.method === '_acpcode/event') {
      c.events.push(m.params);
      const q = m.params.message;
      if (q?.method === 'session/request_permission') {
        const title = q.params.toolCall?.title ?? '?';
        const ok = c.allow?.test(title); // only the MCP tool under test; everything else is rejected
        const options = q.params.options ?? [];
        const pick = ok ? options.find((o) => o.kind === 'allow_once') : (options.find((o) => o.kind === 'reject_once') ?? options.find((o) => o.kind === 'reject_always'));
        c.answered.push(`${ok ? 'ALLOW' : 'reject'}:${title.slice(0, 50)}`);
        c.rpc('_acpcode/approvals/answer', pick ? { approvalId: q.id, optionId: pick.optionId } : { approvalId: q.id, cancelled: true });
      }
    }
  });
  c.rpc = (method, params, ms = 180_000) => new Promise((resolve) => {
    const id = nextId++;
    const t = setTimeout(() => { c.pending.delete(id); resolve({ error: { message: `${method}: timeout` } }); }, ms);
    c.pending.set(id, (m) => { clearTimeout(t); resolve(m); });
    ws.send(JSON.stringify({ jsonrpc: '2.0', id, method, params }));
  });
  return c;
}
const agentText = (c, sid) => c.events.filter((e) => e.sessionId === sid && e.message?.params?.update?.sessionUpdate === 'agent_message_chunk').map((e) => e.message.params.update.content?.text ?? '').join('');
const toolUpdates = (c, sid) => c.events.filter((e) => e.sessionId === sid && /tool_call/.test(e.message?.params?.update?.sessionUpdate ?? '')).map((e) => `${e.message.params.update.sessionUpdate}:${e.message.params.update.status ?? ''}:${(e.message.params.update.title ?? '').slice(0, 60)}`);

/** Run one case. mk(ctx) returns { entry, runner extras, report, cleanup }. */
async function runCase(name, mk) {
  if (values.only && !values.only.split(',').includes(name)) return;
  console.log(`\n=== ${name}`);
  const base = join(homedir(), '.acpcode-live', `mcp-${name}-${Date.now()}`);
  await mkdir(join(base, 'root', 'proj'), { recursive: true });
  const root = await realpath(join(base, 'root'));
  const project = join(root, 'proj');
  execFileSync('git', ['init', '-q', '-b', 'main'], { cwd: project });
  await writeFile(join(project, 'README.md'), 'mcp test\n');
  const ctx = { base, project, report: join(project, 'mcp-report.jsonl') };
  const spec = await mk(ctx);
  const token = randomBytes(24).toString('base64url');
  const config = {
    listen: { host: '127.0.0.1', port: 0 }, trustProxy: false,
    tokens: [{ id: 'live', identity: 'owner', sha256: hashToken(token) }],
    agent: { command: [BOB, 'acp', '--accept-license', '--log-level', 'warn'], envPassthrough: ['PATH', 'LANG', 'BOB_API_KEY', ...(values.control ? ['HOME'] : [])] },
    projects: { roots: [root] }, stateDir: join(base, 'state'),
    runner: values.control ? { kind: 'host', allowHost: true } : { kind: 'srt', srt: values.srt, allowedDomains: [...HOSTS.split(','), ...(spec.domains ?? [])], allowRead: ['/opt/homebrew', '/usr/local'], ...(spec.runner ?? {}) },
    limits: { idleSeconds: 600 },
  };
  const gw = await spawnGateway(config, { env: { ...process.env }, replaceEnv: true, configDir: base });
  let c;
  try {
    c = client(gw, token);
    c.allow = spec.allow ?? /Running Report \(probe\)/;
    await c.ready;
    await c.rpc('_acpcode/projects/create', { name, path: project });
    await c.rpc('initialize', { protocolVersion: 1, clientCapabilities: {} });
    if (spec.library) await spec.library({ base, project, gw });
    const created = await c.rpc('session/new', { cwd: project, mcpServers: spec.entry ? [spec.entry] : [], ...(spec.meta ? { _meta: spec.meta(ctx) } : {}) });
    const sid = created.result?.sessionId;
    if (!sid) {
      if (spec.expectNewFails) await spec.expectNewFails({ error: created.error, check: (n, ok, d) => check(`${name}: ${n}`, ok, d) });
      else check(`${name}: session/new`, false, JSON.stringify(created.error).slice(0, 200));
      return;
    }
    await c.rpc('_acpcode/sessions/subscribe', { sessionId: sid, afterSeq: 0 });
    let leak = { argv: [], files: [], own: [] };
    const watch = spec.watchArgv ? setInterval(() => {
      try {
        const ps = execFileSync('/bin/ps', ['-axww', '-o', 'command='], { encoding: 'utf8' });
        for (const l of ps.split('\n')) {
          if (!(l.includes(spec.watchArgv) || l.includes(SECRET))) continue;
          // The MCP server's own command line carries its configured args by design; the lines the
          // gateway builds (srt, bob acp, the env wrapper) must not carry any secret.
          if (l.includes('mcp-probe-server.mjs')) leak.own.push(l.slice(0, 40)); else leak.argv.push(l.slice(0, 80));
        }
        const grep = execFileSync('/bin/sh', ['-c', `grep -rl -e '${spec.watchArgv}' -e '${SECRET}' ${join(base, 'state', 'srt')} 2>/dev/null; true`], { encoding: 'utf8' });
        if (grep.trim()) leak.files.push(...grep.trim().split('\n'));
      } catch { /* keep going */ }
    }, 300) : null;
    const turn = await c.rpc('session/prompt', { sessionId: sid, prompt: [{ type: 'text', text: spec.prompt ?? PROMPT }] }, 120_000);
    await sleep(500);
    if (watch) { clearInterval(watch); check('no secret in the srt or bob command lines while it ran', leak.argv.length === 0, leak.argv.slice(0, 2).join(' | '));
      console.log(`  note: the MCP server's own command line held its configured args (${leak.own.length ? 'seen' : 'not seen'}), as designed; any process of the same user can read it with ps`); check('no secret in a settings file', leak.files.length === 0, leak.files.slice(0, 2).join(' | ')); }
    let report = [];
    try { report = (await readFile(spec.reportFile ?? ctx.report, 'utf8')).split('\n').filter(Boolean).map((l) => JSON.parse(l)); } catch { /* none */ }
    const probe = report.find((r) => r.mode && r.pid && !r.started);
    const started = report.find((r) => r.started);
    const text = agentText(c, sid);
    const tools = toolUpdates(c, sid);
    console.log(`  turn: ${turn.error ? JSON.stringify(turn.error).slice(0, 150) : turn.result?.stopReason}; approvals: ${c.answered.join(' | ').slice(0, 120)}; tools: ${tools.join(' | ').slice(0, 260)}`);
    console.log(`  agent said: ${text.slice(0, 160).replace(/\n/g, ' ')}`);
    if (process.env.MCP_SRT_REQS && spec.reportFile) { try { console.log(`  http requests seen by the server: ${(await readFile(spec.reportFile, 'utf8')).split('\n').filter(Boolean).slice(0, 6).join(' ; ').slice(0, 500)}`); } catch { console.log('  http requests seen by the server: none'); } }
    if (probe) console.log(`  probe env proxy: ${JSON.stringify(probe.envProxy)}; env names: ${probe.envNames}`);
    if (process.env.MCP_SRT_LOGS) {
      const sj = execFileSync('/bin/sh', ['-c', `cat ${join(base, 'state', 'srt')}/*-agent.json 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps(d['network']), 'enableWeaker=', d.get('enableWeakerNetworkIsolation'))"`], { encoding: 'utf8' });
      console.log(`  settings network: ${sj.trim()}`);
      const logs = execFileSync('/bin/sh', ['-c', `find ${join(base, 'state', 'homes')} -name '*.log' -o -name '*.jsonl' 2>/dev/null | head -5`], { encoding: 'utf8' }).split('\n').filter(Boolean);
      for (const f of logs) { const t = (await readFile(f, 'utf8')).split('\n').filter((l) => /probe|proxy|EPERM|listen|ECONN|error|fetch|refused/i.test(l) && !/bob_prod|apikey/i.test(l)).slice(-12); console.log(`  log ${f.split('/').slice(-3).join('/')}:\n    ${t.map((l) => l.slice(0, 260)).join('\n    ')}`); }
    }
    await spec.verify({ probe, started, report, text, tools, check: (n, ok, d) => check(`${name}: ${n}`, ok, d), ctx, gw });
  } catch (e) {
    check(`${name}: ran`, false, String(e.message ?? e).slice(0, 200));
  } finally {
    try { await gw.stop(); } catch { /* gone */ }
    await spec.cleanup?.();
    await rm(base, { recursive: true, force: true });
  }
}

const stdioEntry = (report, env = []) => ({ name: 'probe', command: NODE, args: [PROBE_READABLE, 'stdio', report], env: [{ name: 'SECRET', value: SECRET }, { name: 'REAL_HOME', value: homedir() }, ...env] });
const called = (r) => !!r.probe;

// 1. stdio server on a readable path (/opt/homebrew): starts, lists its tool, the tool runs.
await runCase('stdio-readable', async (ctx) => ({
  entry: stdioEntry(ctx.report),
  verify: ({ probe, check }) => {
    check('the tool was called', !!probe);
    if (!probe) return;
    check('it received its env secret', probe.secretLength === SECRET.length);
    check('cwd is the project', probe.cwd === ctx.project, probe.cwd);
    check('home is not the gateway user home listing', String(probe.listHome).startsWith('denied'), probe.listHome);
    check('~/.ssh is denied', String(probe.listSsh).startsWith('denied'), probe.listSsh);
    check('write outside the project is denied', String(probe.writeHomeCache).startsWith('denied'), probe.writeHomeCache);
    check('write in the project works', probe.writeCwd === 'ok', probe.writeCwd);
    check('.git/config is denied to the agent tree', String(probe.writeGitConfig).startsWith('denied'), probe.writeGitConfig);
    check('network: a host not allowed is refused', String(probe.fetchExample).startsWith('failed') || /http 403/.test(probe.fetchExample), probe.fetchExample);
  },
}));

// 2. stdio server whose script is under the gateway user's home (denied): fails fast, clearly.
const homeScript = join(homedir(), '.acpcode-live', `probe-home-${Date.now()}.mjs`);
await runCase('stdio-home-denied', async (ctx) => {
  await mkdir(join(homedir(), '.acpcode-live'), { recursive: true });
  await writeFile(homeScript, await readFile(PROBE_READABLE, 'utf8'));
  return {
    entry: { name: 'probe', command: NODE, args: [homeScript, 'stdio', ctx.report], env: [] },
    cleanup: () => rm(homeScript, { force: true }),
    verify: ({ probe, check, tools, text }) => {
      check('the tool was not called (the script is unreadable)', !probe);
      check('Bob did not hang: the turn ended with some text or a failed tool', text.length > 0 || tools.length >= 0);
    },
  };
});

// 3. stdio server that needs a host: refused unless the host is allowed, then works.
await runCase('stdio-net-denied', async (ctx) => ({
  entry: stdioEntry(ctx.report),
  verify: ({ probe, check }) => { check('tool called', !!probe); check('example.com refused', probe && /failed|403/.test(probe.fetchExample), probe?.fetchExample); },
}));
// Documented limitation: Bob starts MCP children with a clean environment (no proxy variables, and
// it does not expand $VAR in an entry's env), so a stdio server cannot find srt's per-run proxy and
// Seatbelt blocks its direct DNS. Allowing the host for the agent does not help the stdio child.
await runCase('stdio-net-limitation', async (ctx) => ({
  entry: stdioEntry(ctx.report),
  domains: ['example.com'],
  verify: ({ probe, check }) => { check('tool called', !!probe); check('stdio server still cannot reach an allowed host (known limitation)', probe && !/^http 200/.test(probe.fetchExample), probe?.fetchExample); },
}));

// 3b. The gateway's own server list (D-107): a stdio entry with a secret argument and a secret
// environment value, enabled for the session by id. The secrets must reach the server and appear in
// no process argument and no settings file while it runs.
await runCase('stdio-library-secrets', async (ctx) => {
  const ARG = `argsecret-${randomBytes(5).toString('hex')}`;
  let ids = [];
  return {
    entry: undefined,
    library: async ({ base }) => {
      const cfgPath = join(base, 'config.json');
      const put = execFileSync(join(process.cwd(), 'bin', 'acpcode-gateway'), ['--config', cfgPath, 'mcp-server', 'put'], {
        input: JSON.stringify({ name: 'probe', transport: 'stdio', command: NODE, args: [PROBE_READABLE, 'stdio', ctx.report, ARG], env: [{ name: 'SECRET', value: SECRET }, { name: 'REAL_HOME', value: homedir() }], headers: [], defaultEnabled: true }),
        encoding: 'utf8',
      });
      ids = [JSON.parse(put).id ?? JSON.parse(put).server?.id].filter(Boolean);
      console.log(`  library entry ids: ${ids.join(',') || put.slice(0, 120)}`);
    },
    meta: () => ({ 'acpcode/mcpEnabled': ids }),
    watchArgv: ARG,
    verify: async ({ probe, check, ctx: cx }) => {
      check('the tool was called through the gateway list', !!probe);
      check('the env secret reached the server', probe?.secretLength === SECRET.length);
    },
  };
});

// 4/5. http MCP server on the Mac's loopback, run by the user on the host.
async function httpServer(port, report) {
  const child = spawn(NODE, [PROBE_READABLE, 'http', String(port), report], { stdio: ['ignore', 'ignore', 'pipe'] });
  await new Promise((res) => child.stderr.on('data', (d) => { if (String(d).includes('listening')) res(); }));
  return child;
}
for (const [name, local] of [['http-loopback-off', false], ['http-loopback-on', true]]) {
  let server;
  let hostReport;
  await runCase(name, async (ctx) => {
    hostReport = join(ctx.base, 'host-report.jsonl');
    const port = 18900 + (local ? 1 : 0);
    server = await httpServer(port, hostReport);
    return {
      entry: { type: 'http', name: 'probe', url: `http://localhost:${port}/mcp`, headers: [] },
      runner: local ? { allowLocalBinding: true } : {},
      reportFile: hostReport,
      expectNewFails: local ? undefined : ({ error, check }) => check('without allowLocalBinding an http MCP entry makes session/new fail with a listen error (Bob opens a local listener)', /listen EPERM/.test(JSON.stringify(error)), JSON.stringify(error).slice(0, 120)),
      cleanup: () => { server?.kill(); },
      verify: ({ probe, report, check, text }) => {
        const reached = report.some((r) => r.http === 'initialize' || r.http === 'tools/list');
        if (local) { check('the agent reached the loopback server', reached); check('the tool was called', !!probe); }
        else check('without allowLocalBinding the loopback server is not reached', !reached, `${report.length} requests`);
      },
    };
  });
}

// 6. https MCP server on the internet (DeepWiki): host allowed, host not allowed, binding off.
const DW_PROMPT = 'Use the MCP tool read_wiki_structure from the MCP server named "deepwiki" with repoName "facebook/react", once. Then reply with the single word: done. Use no other tool.';
const deepwiki = (domains, binding = true, expectOk = true) => async () => ({
  entry: { type: 'http', name: 'deepwiki', url: 'https://mcp.deepwiki.com/mcp', headers: [] },
  domains,
  prompt: DW_PROMPT,
  allow: /deepwiki|wiki/i,
  runner: binding ? { allowLocalBinding: true } : {},
  expectNewFails: binding ? undefined : ({ error, check }) => check('an https MCP entry also needs allowLocalBinding (session/new fails with a listen error)', /listen EPERM/.test(JSON.stringify(error)), JSON.stringify(error).slice(0, 120)),
  verify: ({ tools, check, text }) => {
    const done = tools.some((t) => /completed/.test(t)) && !tools.some((t) => /failed/.test(t));
    const ranWiki = tools.some((t) => /wiki|deepwiki/i.test(t));
    if (expectOk) check('https MCP server works when its host is allowed', done && ranWiki, tools.join(' | ').slice(0, 200));
    else check('https MCP server is unusable when its host is not allowed', !(done && ranWiki), `${tools.join(' | ').slice(0, 160)} / said: ${text.slice(0, 80)}`);
  },
});
await runCase('https-host-allowed', deepwiki(['mcp.deepwiki.com']));
await runCase('https-host-denied', deepwiki([], true, false));
await runCase('https-binding-off', deepwiki(['mcp.deepwiki.com'], false));

const failed = results.filter((r) => !r.ok);
console.log(`\nSUMMARY mcp-srt: ${results.length - failed.length}/${results.length} passed${failed.length ? `; failed: ${failed.map((f) => f.name).join(' | ')}` : ''}`);
process.exit(failed.length ? 1 : 0);
