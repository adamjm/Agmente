// Signed file URLs (FR-38, NFR-12, PLAN 5.3, D-061 to D-064). Wire-level: a real project folder,
// the gateway as a process, and HTTP on the files host (Host header) and on the ACP socket.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { chmodSync, mkdirSync, mkdtempSync, symlinkSync, truncateSync, unlinkSync, writeFileSync } from 'node:fs';
import { rm } from 'node:fs/promises';
import { request } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { auth, connect, dryRun, rpc, startGateway, sleep, TOKEN } from './helpers.mjs';

const HOST = 'files.test';
const SECRET = 'FILE-SECRET-VALUE-4242';

/** One HTTP request to the gateway's listener with a chosen Host header. */
function http(gw, path, { method = 'GET', host = HOST, headers = {} } = {}) {
  const port = Number(new URL(gw.url).port);
  return new Promise((resolve, reject) => {
    const req = request({ host: '127.0.0.1', port, path, method, headers: { Host: host, ...headers } }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks) }));
    });
    req.on('error', reject);
    req.end();
  });
}

/** A raw WebSocket upgrade with a Host header. Resolves the status (101 or the rejection code). */
function upgradeStatus(gw, host, token = TOKEN) {
  const port = Number(new URL(gw.url).port);
  return new Promise((resolve, reject) => {
    const req = request({
      host: '127.0.0.1', port, path: '/', method: 'GET',
      headers: {
        Host: host, Connection: 'Upgrade', Upgrade: 'websocket', 'Sec-WebSocket-Version': '13',
        'Sec-WebSocket-Key': Buffer.from('0123456789abcdef').toString('base64'), Authorization: `Bearer ${token}`,
      },
    });
    req.on('response', (res) => { res.resume(); resolve(res.statusCode); });
    req.on('upgrade', (res, socket) => { socket.destroy(); resolve(res.statusCode); });
    req.on('error', reject);
    req.end();
  });
}

const fileEvents = (gw) => gw.audit.filter((a) => a.event.startsWith('file_'));
const pathOf = (url) => new URL(url).pathname;
const tokenOf = (url) => pathOf(url).slice('/f/'.length);

/**
 * A gateway with files enabled, a connected phone and one registered project. The project folder
 * holds a set of files, a symlink to /etc/passwd, a symlink to a folder outside the project, and a
 * symlink to .env inside it. `outside` is a folder beside the root, not in the project.
 */
async function setup(files = {}, { denyPaths = ['*.db'] } = {}) {
  const gw = await startGateway({ files: { host: HOST, ...files }, limits: {} });
  const { ws } = await connect(gw.url, auth());
  const dir = gw.dirs.project;
  const put = (name, data) => {
    mkdirSync(join(dir, name, '..'), { recursive: true });
    writeFileSync(join(dir, name), data);
  };
  put('pixel.png', Buffer.from([0x89, 0x50, 0x4e, 0x47, 1, 2, 3]));
  put('page.html', '<p>hello</p>');
  put('notes.txt', 'plain notes\n');
  put('image.svg', '<svg xmlns="http://www.w3.org/2000/svg" onload="alert(1)"></svg>');
  put('sub/inner.txt', 'inner\n');
  put('.env', `TOKEN=${SECRET}\n`);
  put('data.db', 'db\n');
  put('run.sh', 'echo hi\n');
  put('config/prod.yml', 'prod: 1\n');
  mkdirSync(join(dir, 'adir'));
  writeFileSync(join(gw.dirs.outside, 'secret.txt'), `OUTSIDE-${SECRET}\n`);
  symlinkSync('/etc/passwd', join(dir, 'passwd-link'));
  symlinkSync(gw.dirs.outside, join(dir, 'outside-dir'));
  symlinkSync('.env', join(dir, 'env-link.txt'));
  execFileSync('mkfifo', [join(dir, 'pipe.txt')]);
  const created = await rpc(ws, '_agmente/projects/create', { name: 'files', path: dir, denyPaths });
  assert.ok(created.result?.project, JSON.stringify(created.error));
  return { gw, ws, dir, projectId: created.result.project.id, outside: gw.dirs.outside };
}

const sign = (ctx, path) => rpc(ctx.ws, '_agmente/files/url', { projectId: ctx.projectId, path });

async function stopAll(ctx) {
  ctx.ws.close();
  await ctx.gw.stop();
}

test('files extension is advertised and the method is refused when files is off', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    const init = await rpc(ws, 'initialize', { protocolVersion: 1, clientCapabilities: {} });
    assert.ok(init.result._meta['agmente/gateway'].extensions.includes('files'));
    const res = await rpc(ws, '_agmente/files/url', { projectId: 'x', path: 'a.txt' });
    assert.equal(res.error?.code, -32000, 'with no files block the feature is off');
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('a signed URL serves the file with its type and the security headers (T-37)', async () => {
  const ctx = await setup();
  try {
    const res = await sign(ctx, 'pixel.png');
    assert.ok(res.result, JSON.stringify(res.error));
    const { url, expiresAt } = res.result;
    assert.match(url, /^https:\/\/files\.test\/f\/[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/);
    const ttl = (Date.parse(expiresAt) - Date.now()) / 1000;
    assert.ok(ttl > 0 && ttl <= 300, `expiry within 300 s, got ${ttl}`);

    const got = await http(ctx.gw, pathOf(url));
    assert.equal(got.status, 200);
    assert.equal(got.headers['content-type'], 'image/png');
    assert.deepEqual(got.body, Buffer.from([0x89, 0x50, 0x4e, 0x47, 1, 2, 3]));
    assert.equal(got.headers['x-content-type-options'], 'nosniff');
    assert.equal(got.headers['cache-control'], 'no-store');
    assert.equal(got.headers['content-disposition'], 'inline');
    assert.equal(got.headers['set-cookie'], undefined, 'no cookies');
    assert.equal(got.headers['content-security-policy'], undefined, 'CSP is for HTML only');

    const issued = ctx.gw.audit.find((a) => a.event === 'file_url_issued');
    assert.equal(issued.project, ctx.projectId);
    assert.equal(issued.path, 'pixel.png');
    assert.equal(ctx.gw.audit.find((a) => a.event === 'file_served').path, 'pixel.png');
  } finally {
    await stopAll(ctx);
  }
});

test('HEAD works and returns the same headers with no body; POST is refused (T-37)', async () => {
  const ctx = await setup();
  try {
    const { url } = (await sign(ctx, 'notes.txt')).result;
    const get = await http(ctx.gw, pathOf(url));
    const head = await http(ctx.gw, pathOf(url), { method: 'HEAD' });
    assert.equal(head.status, 200);
    assert.equal(head.body.length, 0);
    assert.equal(head.headers['content-type'], get.headers['content-type']);
    assert.equal(head.headers['content-length'], String(get.body.length));

    const post = await http(ctx.gw, pathOf(url), { method: 'POST', headers: { 'Content-Length': '0' } });
    assert.equal(post.status, 405);
    assert.equal(post.headers.allow, 'GET, HEAD');
    assert.ok(fileEvents(ctx.gw).some((a) => a.event === 'file_refused' && a.reason === 'method'));
  } finally {
    await stopAll(ctx);
  }
});

test('the files host never reaches the ACP socket and the file handler answers only there (T-37)', async () => {
  const ctx = await setup();
  try {
    const { url } = (await sign(ctx, 'notes.txt')).result;
    assert.equal(await upgradeStatus(ctx.gw, HOST), 403, 'an upgrade on the files host is refused');
    assert.equal(await upgradeStatus(ctx.gw, `${HOST}:8443`), 403, 'the port is ignored in the comparison');
    assert.equal(await upgradeStatus(ctx.gw, 'ws.test'), 101, 'the ACP host still upgrades');
    assert.ok(ctx.gw.audit.some((a) => a.event === 'reject' && a.reason === 'files_host'));

    const before = fileEvents(ctx.gw).length;
    const wrong = await http(ctx.gw, pathOf(url), { host: 'other.test' });
    assert.equal(wrong.status, 404, 'a valid token on another Host is not answered');
    assert.equal(wrong.body.includes(SECRET), false);
    await sleep(100);
    assert.equal(fileEvents(ctx.gw).length, before, 'the file handler never ran for the wrong host');
  } finally {
    await stopAll(ctx);
  }
});

test('paths outside the project or syntactically wrong are refused at signing (T-37)', async () => {
  const ctx = await setup();
  try {
    const refused = {
      '../x': 'path',
      '/etc/passwd': 'path',
      'sub/../../x': 'path',
      'sub//inner.txt': 'path',
      '': 'path',
      './notes.txt': 'path',
      'a\u0000b.txt': 'path',
      'a\nb.txt': 'path',
      'sub\\inner.txt': 'path',
      'passwd-link': 'outside_root',
      'outside-dir/secret.txt': 'outside_root',
      'missing.txt': 'not_found',
      adir: 'not_regular',
      'pipe.txt': 'not_regular',
      'env-link.txt': 'secret',
      '.env': 'secret',
      'data.db': 'secret',
      'config/prod.yml': 'secret',
      'run.sh': 'type',
    };
    for (const [path, reason] of Object.entries(refused)) {
      const res = await sign(ctx, path);
      assert.ok(res.error, `${JSON.stringify(path)} should be refused`);
      assert.equal(res.error.code, -32602, JSON.stringify(path));
      assert.ok(
        ctx.gw.audit.some((a) => a.event === 'file_refused' && a.reason === reason && a.project === ctx.projectId),
        `${JSON.stringify(path)} audited as ${reason}`,
      );
    }
    // The secret content never leaves the gateway in an error message.
    const env = await sign(ctx, '.env');
    assert.equal(JSON.stringify(env).includes(SECRET), false);
    // A secret-named link to a harmless file is refused by its name, whatever it points to.
    mkdirSync(join(ctx.dir, 'cfg'), { recursive: true });
    symlinkSync(join(ctx.dir, 'notes.txt'), join(ctx.dir, 'cfg', '.env'));
    const named = await sign(ctx, 'cfg/.env');
    assert.equal(named.error?.code, -32602, 'a link named .env is a secret path');
    assert.ok(ctx.gw.audit.some((a) => a.event === 'file_refused' && a.reason === 'secret' && a.path === 'cfg/.env'));
    assert.equal((await sign(ctx, 'nope')).error.code, -32602);
    assert.equal((await rpc(ctx.ws, '_agmente/files/url', { projectId: 'nosuchproject', path: 'notes.txt' })).error.code, -32602);
    assert.equal((await rpc(ctx.ws, '_agmente/files/url', { projectId: ctx.projectId, path: 7 })).error.code, -32602);
  } finally {
    await stopAll(ctx);
  }
});

test('a symlink that is swapped after signing is refused at serve time (T-37, TOCTOU)', async () => {
  const ctx = await setup();
  try {
    // Sign a path that is a regular file, then point it at a file outside the project.
    writeFileSync(join(ctx.dir, 'swap.txt'), 'in project\n');
    const signed = await sign(ctx, 'swap.txt');
    assert.ok(signed.result, JSON.stringify(signed.error));
    unlinkSync(join(ctx.dir, 'swap.txt'));
    symlinkSync(join(ctx.outside, 'secret.txt'), join(ctx.dir, 'swap.txt'));
    const got = await http(ctx.gw, pathOf(signed.result.url));
    assert.equal(got.status, 403);
    assert.equal(got.body.includes(SECRET), false, 'the outside file is never read');
    assert.ok(ctx.gw.audit.some((a) => a.event === 'file_refused' && a.reason === 'outside_root' && a.path === 'swap.txt'));

    // Swapped to a secret file inside the project: refused as a secret.
    unlinkSync(join(ctx.dir, 'swap.txt'));
    symlinkSync('.env', join(ctx.dir, 'swap.txt'));
    const again = await http(ctx.gw, pathOf(signed.result.url));
    assert.equal(again.status, 403);
    assert.equal(again.body.includes(SECRET), false);
    assert.ok(ctx.gw.audit.some((a) => a.event === 'file_refused' && a.reason === 'secret' && a.path === 'swap.txt'));

    // Swapped back to a regular file: the same URL serves it again, because the path is still good.
    unlinkSync(join(ctx.dir, 'swap.txt'));
    writeFileSync(join(ctx.dir, 'swap.txt'), 'back\n');
    assert.equal((await http(ctx.gw, pathOf(signed.result.url))).status, 200);
  } finally {
    await stopAll(ctx);
  }
});

test('a symlink to /etc/passwd and a directory link to outside are both refused (T-37)', async () => {
  const ctx = await setup();
  try {
    assert.equal((await sign(ctx, 'passwd-link')).error?.code, -32602);
    assert.equal((await sign(ctx, 'outside-dir/secret.txt')).error?.code, -32602);
    assert.ok(!ctx.gw.audit.some((a) => a.event === 'file_url_issued' && a.path === 'passwd-link'));
  } finally {
    await stopAll(ctx);
  }
});

test('a tampered token and a token for another path are refused (T-37)', async () => {
  const ctx = await setup();
  try {
    const a = (await sign(ctx, 'notes.txt')).result.url;
    const b = (await sign(ctx, 'page.html')).result.url;
    const ta = tokenOf(a);
    const tb = tokenOf(b);
    const dotA = ta.indexOf('.');
    const dotB = tb.indexOf('.');
    // Another file's payload with this signature: the claims are the signed part, so it fails.
    const spliced = tb.slice(0, dotB) + ta.slice(dotA);
    assert.equal((await http(ctx.gw, `/f/${spliced}`)).status, 403);
    // One character of the signature changed.
    const sig = ta.slice(dotA + 1);
    const flipped = `${ta.slice(0, dotA + 1)}${sig[0] === 'A' ? 'B' : 'A'}${sig.slice(1)}`;
    assert.equal((await http(ctx.gw, `/f/${flipped}`)).status, 403);
    // Garbage, and a token with no signature.
    assert.equal((await http(ctx.gw, '/f/abc')).status, 403);
    assert.equal((await http(ctx.gw, `/f/${ta.slice(0, dotA)}`)).status, 403);
    assert.ok(ctx.gw.audit.some((a) => a.event === 'file_refused' && a.reason === 'token'));
    // The untouched token still works.
    assert.equal((await http(ctx.gw, pathOf(a))).status, 200);
  } finally {
    await stopAll(ctx);
  }
});

test('an expired URL is refused (T-37, NFR-12)', async () => {
  const ctx = await setup({ ttlSeconds: 1 });
  try {
    const { url, expiresAt } = (await sign(ctx, 'notes.txt')).result;
    assert.ok(Date.parse(expiresAt) - Date.now() <= 1500, 'a 1 s lifetime from the config');
    assert.equal((await http(ctx.gw, pathOf(url))).status, 200, 'valid before expiry');
    await sleep(2100);
    const late = await http(ctx.gw, pathOf(url));
    assert.equal(late.status, 403);
    assert.ok(ctx.gw.audit.some((a) => a.event === 'file_refused' && a.reason === 'expired' && a.path === 'notes.txt'));
  } finally {
    await stopAll(ctx);
  }
});

test('the files block refuses a ttl above 300 s and a key inside the config', async () => {
  const tooLong = await dryRun({ listen: { host: '127.0.0.1', port: 0 }, tokens: [{ id: 'a', identity: 'o', sha256: '0'.repeat(64) }], agent: { command: ['x'] }, projects: { roots: ['/tmp'] }, stateDir: '/tmp/s', runner: { kind: 'host', allowHost: true }, files: { host: HOST, ttlSeconds: 301 } });
  assert.notEqual(tooLong.status, 0);
  assert.match(tooLong.stderr, /files\.ttlSeconds/);
  const inline = await dryRun({ listen: { host: '127.0.0.1', port: 0 }, tokens: [{ id: 'a', identity: 'o', sha256: '0'.repeat(64) }], agent: { command: ['x'] }, projects: { roots: ['/tmp'] }, stateDir: '/tmp/s', runner: { kind: 'host', allowHost: true }, files: { host: HOST, key: 'abc' } });
  assert.notEqual(inline.status, 0);
  assert.match(inline.stderr, /must not hold a key/);
  assert.equal(inline.stderr.includes('abc'), false);
});

test('a file over the size cap is refused at signing and at serving (T-37)', async () => {
  const ctx = await setup({ maxBytes: 1024 });
  try {
    writeFileSync(join(ctx.dir, 'big.txt'), 'x'.repeat(2048));
    assert.equal((await sign(ctx, 'big.txt')).error?.code, -32602);
    assert.ok(ctx.gw.audit.some((a) => a.event === 'file_refused' && a.reason === 'too_large'));

    writeFileSync(join(ctx.dir, 'grow.txt'), 'x'.repeat(100));
    const signed = await sign(ctx, 'grow.txt');
    assert.ok(signed.result);
    writeFileSync(join(ctx.dir, 'grow.txt'), 'x'.repeat(2048));
    const got = await http(ctx.gw, pathOf(signed.result.url));
    assert.equal(got.status, 413);
    assert.equal(got.body.length < 2048, true, 'no content of the big file is sent');
    truncateSync(join(ctx.dir, 'grow.txt'), 10);
    assert.equal((await http(ctx.gw, pathOf(signed.result.url))).status, 200, 'a file within the cap is served');
  } finally {
    await stopAll(ctx);
  }
});

test('HTML carries the CSP, SVG is served as text, and nothing is served as a script type (T-38 headers)', async () => {
  const ctx = await setup();
  try {
    const html = await http(ctx.gw, pathOf((await sign(ctx, 'page.html')).result.url));
    assert.equal(html.status, 200);
    assert.equal(html.headers['content-type'], 'text/html; charset=utf-8');
    assert.equal(html.headers['content-security-policy'], "default-src 'none'; style-src 'unsafe-inline'; img-src 'self' data:");
    assert.equal(html.headers['x-content-type-options'], 'nosniff');

    const svg = await http(ctx.gw, pathOf((await sign(ctx, 'image.svg')).result.url));
    assert.equal(svg.status, 200);
    assert.match(svg.headers['content-type'], /^text\/plain/);
    assert.equal(svg.headers['content-security-policy'], undefined);
  } finally {
    await stopAll(ctx);
  }
});

test('audit lines carry project and path, and never the token (FR-9)', async () => {
  const ctx = await setup();
  try {
    const { url } = (await sign(ctx, 'notes.txt')).result;
    await http(ctx.gw, pathOf(url));
    await http(ctx.gw, '/f/not-a-token');
    await sign(ctx, '../x');
    await sleep(100);
    const lines = JSON.stringify(ctx.gw.audit);
    assert.equal(lines.includes(tokenOf(url)), false, 'the token is never audited');
    assert.equal(lines.includes(SECRET), false, 'file content is never audited');
    for (const a of fileEvents(ctx.gw)) {
      if (a.path !== undefined) assert.equal(a.path.startsWith('/'), false, 'paths are relative');
    }
    assert.ok(ctx.gw.audit.some((a) => a.event === 'file_url_issued'));
    assert.ok(ctx.gw.audit.some((a) => a.event === 'file_served'));
    assert.ok(ctx.gw.audit.some((a) => a.event === 'file_refused' && a.reason === 'token'));
  } finally {
    await stopAll(ctx);
  }
});

test('a key file is read for the signing key; its key is not in any response (NFR-14)', async () => {
  const keyDir = mkdtempSync(join(tmpdir(), 'agmente-key-'));
  const keyFile = join(keyDir, 'files.key');
  const keyValue = 'K'.repeat(40);
  writeFileSync(keyFile, keyValue);
  chmodSync(keyFile, 0o600);
  const ctx = await setup({ secretFile: keyFile });
  try {
    const { url } = (await sign(ctx, 'notes.txt')).result;
    assert.equal((await http(ctx.gw, pathOf(url))).status, 200);
    assert.equal(JSON.stringify(ctx.gw.audit).includes(keyValue), false);
  } finally {
    await stopAll(ctx);
    await rm(keyDir, { recursive: true, force: true });
  }
});
