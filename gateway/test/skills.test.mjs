// Skills over the socket (FR-43, T-44, D-085, D-087). Wire-level: a real project folder, the
// gateway as a process, and its audit log. These tests need the route in handleExtension
// (serveSkills in internal/server/skills.go); they fail until the main session adds it.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, symlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { auth, connect, rpc, startGateway } from './helpers.mjs';

const INVALID = -32602;

/** A gateway, a connected phone and one project whose folder is the harness project folder. */
async function setup() {
  const gw = await startGateway();
  const { ws } = await connect(gw.url, auth());
  const created = await rpc(ws, '_agmente/projects/create', { name: 'skills', path: gw.dirs.project });
  assert.ok(created.result?.project, JSON.stringify(created.error));
  return { gw, ws, projectId: created.result.project.id, dir: gw.dirs.project, outside: gw.dirs.outside };
}

async function stopAll(ctx) {
  ctx.ws.close();
  await ctx.gw.stop();
}

const put = (ctx, name, content, scope = 'project') =>
  rpc(ctx.ws, '_agmente/skills/put', { projectId: ctx.projectId, scope, name, content });
const list = (ctx, scope = 'project') => rpc(ctx.ws, '_agmente/skills/list', { projectId: ctx.projectId, scope });
const del = (ctx, name, scope = 'project') =>
  rpc(ctx.ws, '_agmente/skills/delete', { projectId: ctx.projectId, scope, name });

const skillsDir = (ctx) => join(ctx.dir, '.bob', 'skills');

test('T-44: invalid names are refused with -32602 and nothing is written', async () => {
  const ctx = await setup();
  try {
    for (const name of ['Bad Name', '../x', 'a'.repeat(65)]) {
      const res = await put(ctx, name, 'body\n');
      assert.equal(res.error?.code, INVALID, `${name.slice(0, 12)}: ${JSON.stringify(res)}`);
    }
    assert.equal(existsSync(join(ctx.dir, '.bob')), false, 'a refused name created .bob');
    assert.equal(existsSync(join(ctx.outside, 'x')), false);
  } finally {
    await stopAll(ctx);
  }
});

test('T-44: a valid name (and the 64-character maximum) is saved atomically at mode 0644', async () => {
  const ctx = await setup();
  try {
    const content = '---\nname: anything\n---\n\nDo the thing.\n';
    const res = await put(ctx, 'valid-skill', content);
    assert.equal(res.error, undefined, JSON.stringify(res.error));

    const file = join(skillsDir(ctx), 'valid-skill', 'SKILL.md');
    assert.equal(readFileSync(file, 'utf8'), content, 'the content is written as given');
    assert.equal(statSync(file).mode & 0o777, 0o644, 'mode 0644: Bob and the container user read it (P4)');
    assert.deepEqual(readdirSync(join(skillsDir(ctx), 'valid-skill')), ['SKILL.md'], 'no temp file is left');

    const max = 'a'.repeat(64);
    const ok64 = await put(ctx, max, 'x\n');
    assert.equal(ok64.error, undefined, JSON.stringify(ok64.error));

    const listed = await list(ctx);
    assert.equal(listed.error, undefined);
    const names = listed.result.skills.map((s) => s.name).sort();
    assert.deepEqual(names, [max, 'valid-skill'].sort());
    const entry = listed.result.skills.find((s) => s.name === 'valid-skill');
    assert.equal(entry.bytes, Buffer.byteLength(content));
  } finally {
    await stopAll(ctx);
  }
});

test('T-44: content of 70 KiB is refused with -32602 and nothing is written', async () => {
  const ctx = await setup();
  try {
    const res = await put(ctx, 'too-big', 'a'.repeat(70 * 1024));
    assert.equal(res.error?.code, INVALID, JSON.stringify(res));
    assert.equal(existsSync(join(skillsDir(ctx), 'too-big')), false, 'an oversize skill left a folder');
  } finally {
    await stopAll(ctx);
  }
});

test('D-087: a scope other than project is refused with -32602 for every method', async () => {
  const ctx = await setup();
  try {
    for (const scope of ['user', 'home', '']) {
      for (const res of [await list(ctx, scope), await put(ctx, 'alpha', 'x\n', scope), await del(ctx, 'alpha', scope)]) {
        assert.equal(res.error?.code, INVALID, `scope ${JSON.stringify(scope)}: ${JSON.stringify(res)}`);
      }
    }
    assert.equal(existsSync(join(ctx.dir, '.bob')), false);
  } finally {
    await stopAll(ctx);
  }
});

test('list skips folders whose names fail the rule and folders with no SKILL.md', async () => {
  const ctx = await setup();
  try {
    assert.equal((await put(ctx, 'good-one', 'body\n')).error, undefined);
    for (const bad of ['Bad Name', 'UPPER']) mkdirSync(join(skillsDir(ctx), bad), { recursive: true });
    writeFileSync(join(skillsDir(ctx), 'Bad Name', 'SKILL.md'), 'body\n');
    mkdirSync(join(skillsDir(ctx), 'no-file'));

    const listed = await list(ctx);
    assert.equal(listed.error, undefined);
    assert.deepEqual(listed.result.skills.map((s) => s.name), ['good-one']);
  } finally {
    await stopAll(ctx);
  }
});

test('delete removes that one skill folder and no other', async () => {
  const ctx = await setup();
  try {
    assert.equal((await put(ctx, 'keep-me', 'keep\n')).error, undefined);
    assert.equal((await put(ctx, 'drop-me', 'drop\n')).error, undefined);

    const res = await del(ctx, 'drop-me');
    assert.equal(res.error, undefined, JSON.stringify(res));
    assert.equal(existsSync(join(skillsDir(ctx), 'drop-me')), false);
    assert.equal(readFileSync(join(skillsDir(ctx), 'keep-me', 'SKILL.md'), 'utf8'), 'keep\n');

    const again = await del(ctx, 'drop-me');
    assert.equal(again.error?.code, INVALID, 'a second delete of the same skill is refused');
    const badName = await del(ctx, '../keep-me');
    assert.equal(badName.error?.code, INVALID);
    assert.equal(existsSync(join(skillsDir(ctx), 'keep-me', 'SKILL.md')), true);
  } finally {
    await stopAll(ctx);
  }
});

test('D-085: a symlinked skill folder is refused and the link target is not written', async () => {
  const ctx = await setup();
  try {
    mkdirSync(skillsDir(ctx), { recursive: true });
    symlinkSync(ctx.outside, join(skillsDir(ctx), 'evil'));

    const res = await put(ctx, 'evil', 'pwned\n');
    assert.equal(res.error?.code, INVALID, JSON.stringify(res));
    assert.equal(existsSync(join(ctx.outside, 'SKILL.md')), false, 'a file was written through the link');

    const listed = await list(ctx);
    assert.equal(listed.error, undefined);
    assert.equal(listed.result.skills.some((s) => s.name === 'evil'), false, 'a linked folder was listed');
  } finally {
    await stopAll(ctx);
  }
});

test('D-085: a symlinked .bob is refused and nothing is written outside the project', async () => {
  const ctx = await setup();
  try {
    symlinkSync(ctx.outside, join(ctx.dir, '.bob'));
    const res = await put(ctx, 'alpha', 'body\n');
    assert.equal(res.error?.code, INVALID, JSON.stringify(res));
    assert.equal(existsSync(join(ctx.outside, 'skills')), false, 'a folder was made through the link');
    assert.equal((await list(ctx)).error?.code, INVALID);
  } finally {
    await stopAll(ctx);
  }
});

test('D-087: skill_put and skill_deleted carry the project, the name and the byte count, never the content', async () => {
  const ctx = await setup();
  try {
    const secret = 'AUDIT-SECRET-BODY-7731';
    const content = `# notes\n${secret}\n`;
    assert.equal((await put(ctx, 'audited', content)).error, undefined);
    assert.equal((await del(ctx, 'audited')).error, undefined);

    const putLine = ctx.gw.audit.find((a) => a.event === 'skill_put');
    assert.ok(putLine, 'skill_put is logged');
    assert.equal(putLine.skill, 'audited');
    assert.equal(putLine.project, ctx.projectId);
    assert.equal(putLine.bytes, Buffer.byteLength(content));

    const delLine = ctx.gw.audit.find((a) => a.event === 'skill_deleted');
    assert.ok(delLine, 'skill_deleted is logged');
    assert.equal(delLine.skill, 'audited');
    assert.equal(delLine.project, ctx.projectId);

    assert.equal(JSON.stringify(ctx.gw.audit).includes(secret), false, 'the audit holds skill content');
  } finally {
    await stopAll(ctx);
  }
});

const read = (ctx, name, scope = 'project') =>
  rpc(ctx.ws, '_agmente/skills/read', { projectId: ctx.projectId, scope, name });

test('read: put then read returns the same content, name and byte count', async () => {
  const ctx = await setup();
  try {
    const content = '---\nname: readable\n---\n\nEdit me.\n';
    assert.equal((await put(ctx, 'readable', content)).error, undefined);

    const res = await read(ctx, 'readable');
    assert.equal(res.error, undefined, JSON.stringify(res.error));
    assert.equal(res.result.name, 'readable');
    assert.equal(res.result.content, content, 'the content read is the content put');
    assert.equal(res.result.bytes, Buffer.byteLength(content));
  } finally {
    await stopAll(ctx);
  }
});

test('read: a missing skill is refused with -32602 "skill not found"', async () => {
  const ctx = await setup();
  try {
    const res = await read(ctx, 'no-such-skill');
    assert.equal(res.error?.code, INVALID, JSON.stringify(res));
    assert.equal(res.error?.message, 'skill not found');
  } finally {
    await stopAll(ctx);
  }
});

test('read: a read is audited with the project, name and byte count, never the content', async () => {
  const ctx = await setup();
  try {
    const secret = 'READ-AUDIT-SECRET-5519';
    const content = `# notes\n${secret}\n`;
    assert.equal((await put(ctx, 'read-audited', content)).error, undefined);
    const res = await read(ctx, 'read-audited');
    assert.equal(res.error, undefined, JSON.stringify(res.error));
    assert.equal(res.result.content, content);

    const line = ctx.gw.audit.find((a) => a.event === 'skill_read');
    assert.ok(line, 'skill_read is logged');
    assert.equal(line.skill, 'read-audited');
    assert.equal(line.project, ctx.projectId);
    assert.equal(line.bytes, Buffer.byteLength(content));
    assert.equal(JSON.stringify(ctx.gw.audit).includes(secret), false, 'the audit holds skill content');
  } finally {
    await stopAll(ctx);
  }
});
