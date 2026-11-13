// Phone file upload into a project folder (D-109): _acpcode/files/upload and _acpcode/files/stat, over the wire.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, lstatSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { auth, connect, rpc, startGateway, useProject } from './helpers.mjs';

const PNG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3]);
const b64 = (buf) => buf.toString('base64');
const sha = (buf) => createHash('sha256').update(buf).digest('hex');

// A gateway with one project registered and one session opened. The session spawns the agent once; the
// tests count spawns from there, so an upload that starts an agent is caught.
async function setup() {
  const gw = await startGateway();
  const { ws } = await connect(gw.url, auth());
  const { project } = await useProject(gw, ws);
  return { gw, ws, project, spawnsBefore: gw.spawned() };
}

test('an upload writes the file into the project root at mode 0644 and returns its path and size', async () => {
  const { gw, ws, project, spawnsBefore } = await setup();
  try {
    const res = await rpc(ws, '_acpcode/files/upload', { projectId: project.id, path: 'photo.png', contentBase64: b64(PNG) });
    assert.equal(res.error, undefined, JSON.stringify(res.error));
    assert.deepEqual(res.result, { path: 'photo.png', bytes: PNG.length });
    const file = join(gw.dirs.project, 'photo.png');
    assert.deepEqual(readFileSync(file), PNG);
    assert.equal(statSync(file).mode & 0o777, 0o644);
    assert.equal(gw.spawned(), spawnsBefore, 'an upload starts no agent');
    // The line for the upload holds the size and never the content or its hash.
    const line = await gw.waitForAudit((l) => l.event === 'file_uploaded' && l.project === project.id);
    assert.equal(line.path, 'photo.png');
    assert.equal(line.bytes, PNG.length);
    const raw = JSON.stringify(line);
    assert.equal(raw.includes(b64(PNG)), false, 'no base64 in the audit line');
    assert.equal(raw.includes(sha(PNG)), false, 'no hash in the audit line');
    assert.equal(raw.includes(gw.dirs.project), false, 'no absolute project path in the audit line');
  } finally {
    ws.close();
    await gw.stop();
  }
});

test('each refused name gets its fixed text, and nothing is written', async () => {
  const { gw, ws, project } = await setup();
  try {
    const cases = [
      ['a/b.png', 'the name must be a file name'],
      ['../x.png', 'the name must be a file name'],
      ['.env', 'the name must be a file name'],
      ['main.swift', 'this file type is not allowed'],
      ['AGENTS.md', 'this name is reserved'],
      ['opencode.json', 'this name is reserved'],
      ['api-secret.json', 'this looks like a secret file'],
      ['Résumé.pdf', 'the name must be a file name'],
      ['x'.repeat(61) + '.png', 'the name must be a file name'],
    ];
    for (const [name, text] of cases) {
      const res = await rpc(ws, '_acpcode/files/upload', { projectId: project.id, path: name, contentBase64: b64(PNG) });
      assert.equal(res.error?.code, -32602, `${name}: ${JSON.stringify(res)}`);
      assert.ok(res.error.message.startsWith(text), `${name}: ${res.error.message}`);
    }
    assert.equal(existsSync(join(gw.dirs.project, 'AGENTS.md')), false);
    assert.equal(existsSync(join(gw.dirs.project, 'api-secret.json')), false);
  } finally {
    ws.close();
    await gw.stop();
  }
});

test('an existing name is refused and its content is not changed', async () => {
  const { gw, ws, project } = await setup();
  try {
    writeFileSync(join(gw.dirs.project, 'notes.txt'), 'original');
    const res = await rpc(ws, '_acpcode/files/upload', { projectId: project.id, path: 'notes.txt', contentBase64: b64(Buffer.from('new')) });
    assert.equal(res.error?.code, -32602);
    assert.match(res.error.message, /already exists/);
    assert.equal(readFileSync(join(gw.dirs.project, 'notes.txt'), 'utf8'), 'original');
  } finally {
    ws.close();
    await gw.stop();
  }
});

test('a symbolic link at the name is refused and its target is not written', async () => {
  const { gw, ws, project } = await setup();
  try {
    const target = join(gw.dirs.root, 'outside.txt');
    symlinkSync(target, join(gw.dirs.project, 'link.txt'));
    const res = await rpc(ws, '_acpcode/files/upload', { projectId: project.id, path: 'link.txt', contentBase64: b64(Buffer.from('x')) });
    assert.equal(res.error?.code, -32602);
    assert.equal(existsSync(target), false, 'the link target was not created');
    assert.equal(lstatSync(join(gw.dirs.project, 'link.txt')).isSymbolicLink(), true, 'the link is untouched');
  } finally {
    ws.close();
    await gw.stop();
  }
});

test('bad base64 and a decoded size over 8 MiB are refused before anything is written', async () => {
  const { gw, ws, project } = await setup();
  try {
    const spaced = await rpc(ws, '_acpcode/files/upload', { projectId: project.id, path: 'a.txt', contentBase64: 'aGVs bG8=' });
    assert.equal(spaced.error?.code, -32602);
    assert.match(spaced.error.message, /not valid base64/);
    const url = await rpc(ws, '_acpcode/files/upload', { projectId: project.id, path: 'a.txt', contentBase64: 'aGVsbG8-_' });
    assert.match(url.error?.message ?? '', /not valid base64/);

    const big = Buffer.alloc(8 * 1024 * 1024 + 1, 1);
    const tooBig = await rpc(ws, '_acpcode/files/upload', { projectId: project.id, path: 'big.png', contentBase64: b64(big) });
    assert.equal(tooBig.error?.code, -32602);
    assert.match(tooBig.error.message, /larger than 8 MB/);
    assert.equal(existsSync(join(gw.dirs.project, 'big.png')), false);
    assert.equal(existsSync(join(gw.dirs.project, 'a.txt')), false);
  } finally {
    ws.close();
    await gw.stop();
  }
});

test('a project whose folder has gone is refused, and nothing is created in its place', async () => {
  const { gw, ws, project } = await setup();
  try {
    rmSync(gw.dirs.project, { recursive: true, force: true });
    const res = await rpc(ws, '_acpcode/files/upload', { projectId: project.id, path: 'photo.png', contentBase64: b64(PNG) });
    assert.equal(res.error?.code, -32602);
    assert.equal(res.error.message, 'the project folder is missing');
    assert.equal(existsSync(gw.dirs.project), false, 'the folder is not recreated');
  } finally {
    ws.close();
    await gw.stop();
  }
});

test('stat reports a name that is absent, present, or a secret, and hashes only what the upload accepts', async () => {
  const { gw, ws, project, spawnsBefore } = await setup();
  try {
    writeFileSync(join(gw.dirs.project, 'photo.png'), PNG);
    writeFileSync(join(gw.dirs.project, 'api-secret.json'), 'token');
    const absent = await rpc(ws, '_acpcode/files/stat', { projectId: project.id, path: 'nope.png' });
    assert.deepEqual(absent.result, { exists: false });
    const present = await rpc(ws, '_acpcode/files/stat', { projectId: project.id, path: 'photo.png' });
    assert.deepEqual(present.result, { exists: true, size: PNG.length, sha256: sha(PNG) });
    const secret = await rpc(ws, '_acpcode/files/stat', { projectId: project.id, path: 'api-secret.json' });
    assert.equal(secret.result.exists, true);
    assert.equal(secret.result.sha256, undefined, 'a secret name is never hashed');
    const syntax = await rpc(ws, '_acpcode/files/stat', { projectId: project.id, path: '../etc' });
    assert.equal(syntax.error?.code, -32602);
    assert.equal(gw.spawned(), spawnsBefore, 'stat starts no agent');
  } finally {
    ws.close();
    await gw.stop();
  }
});

test('a successful upload can be checked by stat with the same hash', async () => {
  const { gw, ws, project } = await setup();
  try {
    await rpc(ws, '_acpcode/files/upload', { projectId: project.id, path: 'photo.png', contentBase64: b64(PNG) });
    const res = await rpc(ws, '_acpcode/files/stat', { projectId: project.id, path: 'photo.png' });
    assert.equal(res.result.sha256, sha(PNG));
    assert.equal(res.result.size, PNG.length);
  } finally {
    ws.close();
    await gw.stop();
  }
});
