#!/usr/bin/env node
// Live run of the gateway with real IBM Bob (PLAN 4, RESULTS 2026-11-07).
// BOB_API_KEY must be in the environment (e.g. `set -a; . ./.env; set +a`); this script never prints it.
//   node gateway/scripts/live-bob.mjs --runner host|podman|apple [--image localhost/agmente-bob:2.0.9] [--dns IP, default the Mac's resolver] [--serve] [--no-key]
// Scenarios use a scratch git project under ~/.agmente-live/ (a place Podman's VM can mount), real Bob,
// and short prompts. The gateway never approves; this test client answers: allow only for the one
// scratch-file edit, reject for everything else (D-009).
import { mkdir, readFile, realpath, rm, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { parseArgs } from 'node:util';
import { randomBytes } from 'node:crypto';
import WebSocket from 'ws';
import { hashToken, spawnGateway } from '../test/helpers.mjs';

const { values } = parseArgs({
  options: {
    runner: { type: 'string', default: 'host' },
    image: { type: 'string', default: 'localhost/agmente-bob:2.0.9' },
    dns: { type: 'string', default: '' },
    serve: { type: 'boolean', default: false },
    'no-key': { type: 'boolean', default: false },
    'idle-seconds': { type: 'string', default: '8' },
  },
});
const apple = values.runner === 'apple';
// Apple containers: the Mac's own IPv4 resolver (scutil) answers from inside the VM; the vmnet default did not (D-081).
const macResolver = () => {
  const m = execFileSync('/usr/sbin/scutil', ['--dns'], { encoding: 'utf8' }).match(/nameserver\[\d+\] : (\d+\.\d+\.\d+\.\d+)/);
  return m ? m[1] : '';
};
if (apple && !values.dns) values.dns = macResolver();
if (apple && !values.dns) { console.error('no IPv4 resolver found; pass --dns'); process.exit(2); }
const podman = values.runner === 'podman' || apple; // a container runner: the image's entrypoint is bob
const log = (...a) => console.log(...a);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const results = [];
const check = (name, ok, detail = '') => {
  results.push({ name, ok });
  log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? `  (${detail})` : ''}`);
};

if (!values['no-key'] && !process.env.BOB_API_KEY) {
  console.error('BOB_API_KEY is not set in the environment');
  process.exit(2);
}
const env = { ...process.env };
if (values['no-key']) delete env.BOB_API_KEY;

// --- scratch project --------------------------------------------------------
const base = join(homedir(), '.agmente-live', `${values.runner}-${Date.now()}`);
await mkdir(join(base, 'root', 'proj'), { recursive: true });
const root = await realpath(join(base, 'root'));
const project = join(root, 'proj');
const git = (...a) => execFileSync('git', a, { cwd: project, env: { ...process.env, GIT_AUTHOR_NAME: 't', GIT_AUTHOR_EMAIL: 't@t', GIT_COMMITTER_NAME: 't', GIT_COMMITTER_EMAIL: 't@t' } });
git('init', '-q', '-b', 'main');
await writeFile(join(project, 'README.md'), 'live test project\n');
git('add', '.');
git('commit', '-q', '-m', 'init');

const token = randomBytes(24).toString('base64url');
const bobArgs = ['acp', '--accept-license', '--log-level', 'warn'];
const config = {
  listen: { host: '127.0.0.1', port: values.serve ? 8799 : 0 },
  trustProxy: false,
  tokens: [{ id: 'live', identity: 'owner', sha256: hashToken(token) }],
  agent: podman
    ? { command: bobArgs, envPassthrough: ['LANG', 'BOB_API_KEY'] } // the image's entrypoint is bob
    : { command: [execFileSync('/usr/bin/which', ['bob'], { encoding: 'utf8' }).trim(), ...bobArgs], envPassthrough: ['PATH', 'LANG', 'BOB_API_KEY'] },
  projects: { roots: [root] },
  stateDir: join(base, 'state'),
  runner: apple
    ? { kind: 'apple', image: values.image, container: '/opt/homebrew/bin/container', ...(values.dns ? { dns: values.dns } : {}) }
    : podman ? { kind: 'podman', image: values.image } : { kind: 'host', allowHost: true },
  limits: { idleSeconds: Number(values['idle-seconds']) },
};
log(`runner: ${values.runner}; project: ${project}; key present: ${!!env.BOB_API_KEY}`);
const gw = await spawnGateway(config, { env, replaceEnv: true, configDir: base });
const audit = gw.audit;

// --- client -----------------------------------------------------------------
let nextId = 1;
function client() {
  const ws = new WebSocket(gw.url, { headers: { Authorization: `Bearer ${token}` }, perMessageDeflate: false });
  const c = { ws, pending: new Map(), events: [], plain: [], onEvent: null };
  c.ready = new Promise((res, rej) => { ws.once('open', res); ws.once('error', rej); });
  ws.on('message', (data) => {
    const msg = JSON.parse(data.toString());
    if (msg.id !== undefined && msg.method === undefined && c.pending.has(msg.id)) {
      c.pending.get(msg.id)(msg);
      c.pending.delete(msg.id);
    } else if (msg.method === '_agmente/event') {
      c.events.push(msg.params);
      c.onEvent?.(msg.params);
    } else if (msg.method) {
      c.plain.push(msg);
    }
  });
  c.rpc = (method, params, ms = 240_000) => new Promise((resolve) => {
    const id = nextId++;
    const t = setTimeout(() => { c.pending.delete(id); resolve({ error: { code: 'timeout', message: `${method}: no response in ${ms} ms` } }); }, ms);
    c.pending.set(id, (m) => { clearTimeout(t); resolve(m); });
    ws.send(JSON.stringify({ jsonrpc: '2.0', id, method, params }));
  });
  return c;
}
const kinds = (c, sid) => c.events.filter((e) => e.sessionId === sid).map((e) => e.message?.method === 'session/update' ? e.message.params.update.sessionUpdate : e.message?.method);
const contiguous = (c, sid, from = 1) => {
  const seqs = c.events.filter((e) => e.sessionId === sid).map((e) => e.seq);
  return seqs.every((s, i) => s === (seqs[i - 1] ?? from - 1) + 1) && seqs.length > 0;
};
const text = (c, sid) => c.events.filter((e) => e.sessionId === sid && e.message?.params?.update?.sessionUpdate === 'agent_message_chunk')
  .map((e) => e.message.params.update.content?.text ?? '').join('');
/** Answer permission requests that arrive as events. `allowIf(toolCall)` decides; else reject. */
function autoAnswer(c, allowIf) {
  const seen = [];
  c.onEvent = async (ev) => {
    const m = ev.message;
    if (m?.method !== 'session/request_permission') return;
    const options = m.params.options ?? [];
    const tool = m.params.toolCall ?? {};
    const allow = allowIf?.(tool) ? options.find((o) => o.kind === 'allow_once') : null;
    const reject = options.find((o) => o.kind === 'reject_once') ?? options.find((o) => o.kind === 'reject_always');
    const pick = allow ?? reject;
    seen.push({ title: tool.title, kind: tool.kind, chose: pick?.kind ?? 'cancelled' });
    await sleep(300); // let `pending` and the index show the open request
    const res = await c.rpc('_agmente/approvals/answer', pick ? { approvalId: m.id, optionId: pick.optionId } : { approvalId: m.id, cancelled: true });
    if (res.error) seen.push({ answerError: res.error });
  };
  return seen;
}

try {
  const a = client();
  await a.ready;
  const created = await a.rpc('_agmente/projects/create', { name: 'live', path: project });
  const projectId = created.result?.project?.id;
  check('project registered', !!projectId);

  if (values.serve) {
    log(`SERVING ws://127.0.0.1:8799/  project ${project}`);
    log(`TOKEN ${token}`);
    await new Promise(() => {}); // until killed
  }

  const init = await a.rpc('initialize', { protocolVersion: 1, clientCapabilities: {} });
  const gwMeta = init.result?._meta?.['agmente/gateway'];
  check('initialize carries gateway extensions', gwMeta?.extensions?.includes('git') && gwMeta.extensions.includes('push'), JSON.stringify(gwMeta?.extensions));

  // --- T-35: no key -----------------------------------------------------------
  if (values['no-key']) {
    const res = await a.rpc('session/new', { cwd: project, mcpServers: [] });
    log(`T-35 session/new without a key -> ${JSON.stringify(res.error ?? res.result).slice(0, 400)}`);
    const nk = res.result?.sessionId;
    if (nk) {
      const pr = await a.rpc('session/prompt', { sessionId: nk, prompt: [{ type: 'text', text: 'Reply with the word: pong' }] }, 90_000);
      log(`T-35 session/prompt without a key -> ${JSON.stringify(pr.error ?? pr.result).slice(0, 600)}`);
    }
    check('T-35 recorded (see lines above)', true);
    throw new Error('done');
  }

  // --- S2/S3 new session, subscribe, a plain turn -----------------------------
  const newRes = await a.rpc('session/new', { cwd: project, mcpServers: [] });
  const sid = newRes.result?.sessionId;
  check('session/new on real Bob', !!sid, newRes.error ? JSON.stringify(newRes.error) : `modes ${JSON.stringify(newRes.result?.modes?.availableModes?.map((m) => m.id))}`);
  if (!sid) throw new Error('no session');
  const sub = await a.rpc('_agmente/sessions/subscribe', { sessionId: sid, afterSeq: 0 });
  check('subscribe on a new session', sub.result?.headSeq === 0 || sub.result?.headSeq >= 0);
  autoAnswer(a, null);
  const t0 = Date.now();
  const p1 = await a.rpc('session/prompt', { sessionId: sid, prompt: [{ type: 'text', text: 'Reply with exactly the word: pong. Do not use any tools.' }] });
  check('turn 1 ends end_turn', p1.result?.stopReason === 'end_turn', `${Date.now() - t0} ms ${p1.error ? JSON.stringify(p1.error) : ''}`);
  await sleep(500);
  const k1 = kinds(a, sid);
  check('event log has turn_started, updates, turn_ended in order', k1.indexOf('_agmente/turn_started') >= 0 && k1.indexOf('_agmente/turn_started') < k1.indexOf('agent_message_chunk') && k1.at(-1) === '_agmente/turn_ended' && k1.includes('agent_message_chunk'), k1.join(','));
  check('seq contiguous from 1', contiguous(a, sid));
  check('agent said pong', /pong/i.test(text(a, sid)), text(a, sid).slice(0, 60));
  const idx = await a.rpc('_agmente/sessions/index', {});
  const row = idx.result?.sessions?.find((s) => s.sessionId === sid);
  check('index: idle, one unread turn', row?.status === 'idle' && row.unread === 1, JSON.stringify({ status: row?.status, unread: row?.unread, title: row?.title }));

  // --- T-18: disconnect mid-turn, resubscribe ---------------------------------
  const b = client();
  await b.ready;
  await b.rpc('_agmente/sessions/subscribe', { sessionId: sid, afterSeq: 0 });
  const long = b.rpc('session/prompt', { sessionId: sid, prompt: [{ type: 'text', text: 'Without any tools, write the numbers from 1 to 120 as English words, one per line.' }] });
  const startLen = b.events.length;
  for (let i = 0; i < 600 && b.events.length < startLen + 4; i++) await sleep(100);
  const lastSeq = b.events.at(-1)?.seq ?? 0;
  b.ws.terminate(); // phone drops mid-turn
  await sleep(2000);
  const c = client();
  await c.ready;
  const sub2 = await c.rpc('_agmente/sessions/subscribe', { sessionId: sid, afterSeq: lastSeq });
  for (let i = 0; i < 1800 && !kinds(c, sid).includes('_agmente/turn_ended'); i++) await sleep(100);
  const seqs = c.events.map((e) => e.seq);
  check('T-18: resubscribe after a drop gets the rest with no gap', kinds(c, sid).at(-1) === '_agmente/turn_ended' && seqs[0] === lastSeq + 1 && seqs.every((s, i) => i === 0 || s === seqs[i - 1] + 1),
    `dropped after seq ${lastSeq}, head ${sub2.result?.headSeq}, got ${seqs[0]}..${seqs.at(-1)}`);
  void long;

  // --- FR-20: reopen answered by the gateway, never forwarded -----------------
  const d = client();
  await d.ready;
  const before = audit.length;
  const load = await d.rpc('session/load', { sessionId: sid, cwd: project, mcpServers: [] });
  await sleep(800);
  const hist = d.plain.filter((m) => m.method === 'session/update').map((m) => m.params.update.content?.text ?? '').join('');
  check('FR-20: load of a live session answered by the gateway', !load.error && audit.slice(before).some((r) => r.event === 'reopen_answered') && !audit.slice(before).some((r) => r.event === 'reload'),
    `${audit.slice(before).map((r) => r.event).join(',')}`);
  check('reopen replays history from the log', /pong/i.test(hist) && /Reply with exactly/.test(hist));
  d.ws.close();

  // --- approvals + file edit + git + turn diff --------------------------------
  const perms = autoAnswer(a, (tool) => /hello\.txt/.test(JSON.stringify(tool)));
  const turnsBefore = a.events.filter((e) => e.message?.method === '_agmente/turn_started').length;
  const p2 = a.rpc('session/prompt', { sessionId: sid, prompt: [{ type: 'text', text: 'Create a file named hello.txt in the current directory containing the single line: hi. Use your file editing tool. Then say done.' }] });
  let sawPending = null;
  for (let i = 0; i < 1200; i++) {
    const pend = await a.rpc('_agmente/approvals/pending', {}, 5000);
    if (pend.result?.approvals?.length) {
      const idx2 = await a.rpc('_agmente/sessions/index', {}, 5000);
      sawPending = { title: pend.result.approvals[0].toolCall?.title, status: idx2.result?.sessions?.find((s) => s.sessionId === sid)?.status };
      break;
    }
    if (a.events.some((e) => e.message?.method === '_agmente/turn_ended' && e.seq > (a.events.find((x) => x.message?.method === '_agmente/turn_started' && x.seq > 0)?.seq ?? 0)) && i > 50 && a.pending.size === 1) { /* keep waiting for p2 below */ }
    const done = await Promise.race([p2.then(() => true), sleep(250).then(() => false)]);
    if (done) break;
  }
  const r2 = await p2;
  check('turn 2 ends', r2.result?.stopReason === 'end_turn', r2.error ? JSON.stringify(r2.error) : r2.result?.stopReason);
  log(`  permission requests seen: ${JSON.stringify(perms)}; pending view: ${JSON.stringify(sawPending)}`);
  check('a permission request reached the queue and was answered by the client', perms.length > 0 && !perms.some((p) => p.answerError), perms.length ? '' : 'Bob asked for no permission to edit');
  if (sawPending) check('index showed awaiting_approval while the request was open', sawPending.status === 'awaiting_approval', sawPending.status);
  const made = existsSync(join(project, 'hello.txt'));
  check('hello.txt exists on the host', made);
  await sleep(1500); // end snapshot
  const st = await a.rpc('_agmente/git/status', { projectId });
  check('git/status lists hello.txt', st.result?.files?.some((f) => f.path === 'hello.txt'), st.error ? JSON.stringify(st.error) : `${st.result?.files?.length} files, branch ${st.result?.branch}`);
  const turnNo = turnsBefore + 1;
  const td = await a.rpc('_agmente/git/turnDiff', { sessionId: sid, turn: turnNo });
  check(`turn diff for turn ${turnNo} shows hello.txt`, /hello\.txt/.test(td.result?.diff ?? ''), td.error ? JSON.stringify(td.error) : '');
  const td1 = await a.rpc('_agmente/git/turnDiff', { sessionId: sid, turn: 1 });
  check('turn diff for the text-only turn is empty', td1.result && (td1.result.diff ?? '') === '', td1.error ? JSON.stringify(td1.error) : `${(td1.result?.diff ?? '').length} chars`);

  // --- reject path ------------------------------------------------------------
  const perms2 = autoAnswer(a, null);
  const p3 = await a.rpc('session/prompt', { sessionId: sid, prompt: [{ type: 'text', text: 'Run the shell command `echo gateway-live-marker > marker.txt` and tell me what happened.' }] });
  check('turn 3 ends after a rejected request', p3.result?.stopReason === 'end_turn', p3.error ? JSON.stringify(p3.error) : p3.result?.stopReason);
  log(`  permission requests seen: ${JSON.stringify(perms2)}`);
  check('the rejected command did not run (no marker.txt)', !existsSync(join(project, 'marker.txt')), perms2.length ? 'rejected' : 'Bob made no permission request');

  // --- D-032: idle stop, then the gateway's own load --------------------------
  a.ws.close(); c.ws.close();
  const idleStarts = audit.filter((r) => r.event === 'agent_start').length;
  await gw.waitForAudit((r) => r.event === 'agent_idle_stop', (Number(values['idle-seconds']) * 1.5 + 20) * 1000).then(
    () => check('idle stop fired after the idle time', true), () => check('idle stop fired after the idle time', false));
  const e = client();
  await e.ready;
  await e.rpc('_agmente/sessions/subscribe', { sessionId: sid, afterSeq: 9999 });
  const beforeReload = audit.length;
  const p4 = await e.rpc('session/prompt', { sessionId: sid, prompt: [{ type: 'text', text: 'What was the first word I asked you to reply with? Answer with just that word. No tools.' }] });
  await sleep(800);
  const newAudit = audit.slice(beforeReload).map((r) => r.event);
  check('after the idle stop the gateway started a new agent and loaded the session itself', audit.filter((r) => r.event === 'agent_start').length === idleStarts + 1 && newAudit.includes('reload'), newAudit.join(','));
  check('Bob still knows the earlier conversation after the reload', p4.result?.stopReason === 'end_turn' && /pong/i.test(text(e, sid)), `${p4.error ? JSON.stringify(p4.error) : text(e, sid).slice(0, 60)}`);
  e.ws.close();
} catch (err) {
  if (err.message !== 'done') { log(`ERROR ${err.stack ?? err}`); check('script ran to the end', false); }
} finally {
  await sleep(300);
  await gw.stop();
  const names = audit.map((r) => r.event);
  log(`audit events: ${[...new Set(names)].join(', ')}`);
  const bad = audit.filter((r) => ['panic', 'store_error', 'snapshot_failed', 'agent_error', 'protocol_violation'].includes(r.event));
  if (bad.length) log(`NOTABLE audit lines: ${JSON.stringify(bad).slice(0, 800)}`);
  if (podman) { try { execFileSync('podman', ['ps', '-a', '--format', '{{.Names}}'], { encoding: 'utf8' }).split('\n').filter((n) => n.startsWith('agmente-')).forEach((n) => log(`LEFTOVER container ${n}`)); } catch {} }
  const failed = results.filter((r) => !r.ok);
  log(`SUMMARY ${values.runner}: ${results.length - failed.length}/${results.length} passed${failed.length ? `; failed: ${failed.map((f) => f.name).join(' | ')}` : ''}`);
  if (!values.serve) await rm(base, { recursive: true, force: true }).catch(() => {});
  process.exit(failed.length ? 1 : 0);
}
