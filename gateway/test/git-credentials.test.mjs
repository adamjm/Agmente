// Git credential profiles over the wire (D-105, v2). The phone writes a token and reads only
// metadata back. No response, no audit line and no file outside credentials/ holds a token.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { auth, connect, rpc, startGateway, TOKEN } from './helpers.mjs';

const TOKEN_VALUE = 'ghp_wiretoken0123456789abcdefghijklmn';
const set = (ws, params) => rpc(ws, '_acpcode/git/credentials/set', params);
const list = (ws) => rpc(ws, '_acpcode/git/credentials/list', {});
const del = (ws, id) => rpc(ws, '_acpcode/git/credentials/delete', { id });

test('set returns only the id; list shows metadata and never the token; the token file is 0600 in a 0700 folder', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    const res = await set(ws, { name: 'Work GitHub', host: 'github.com', token: TOKEN_VALUE });
    assert.equal(res.error, undefined, JSON.stringify(res.error));
    assert.deepEqual(Object.keys(res.result), ['id']);
    assert.match(res.result.id, /^[0-9a-f]{12}$/);
    assert.doesNotMatch(JSON.stringify(res), new RegExp(TOKEN_VALUE));

    const listed = await list(ws);
    assert.equal(listed.error, undefined);
    assert.equal(listed.result.credentials.length, 1);
    const [c] = listed.result.credentials;
    assert.deepEqual(Object.keys(c).sort(), ['createdAt', 'hasSecret', 'host', 'id', 'name']);
    assert.deepEqual({ name: c.name, host: c.host, hasSecret: c.hasSecret, id: c.id }, { name: 'Work GitHub', host: 'github.com', hasSecret: true, id: res.result.id });
    assert.doesNotMatch(JSON.stringify(listed), new RegExp(TOKEN_VALUE));

    const dir = join(gw.config.stateDir, 'credentials');
    assert.equal(statSync(dir).mode & 0o777, 0o700);
    const file = join(dir, res.result.id);
    assert.equal(statSync(file).mode & 0o777, 0o600);
    assert.equal(readFileSync(file, 'utf8'), TOKEN_VALUE);

    // The only other writes are the audit line (no value) and nothing else under stateDir holds it.
    const audit = gw.audit.find((l) => l.event === 'git_credential_set');
    assert.equal(audit.credential, res.result.id);
    assert.equal(audit.host, 'github.com');
    assert.doesNotMatch(JSON.stringify(gw.audit), new RegExp(TOKEN_VALUE));
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('a token is written to no file other than its own and is never in the state folder listing', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    await set(ws, { name: 'a', host: 'github.com', token: TOKEN_VALUE });
    const names = readdirSync(join(gw.config.stateDir, 'credentials'));
    assert.equal(names.length, 1, JSON.stringify(names));
    assert.equal(existsSync(join(gw.config.stateDir, 'gateway.db')), true);
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('set is refused over a connection the proxy reports as plain, and accepted over https', async () => {
  const gw = await startGateway({ trustProxy: true });
  try {
    const plain = await connect(gw.url, { ...auth(), 'X-Forwarded-Proto': 'http' });
    assert.equal(plain.status, 101);
    const refused = await set(plain.ws, { name: 'x', host: 'github.com', token: TOKEN_VALUE });
    assert.equal(refused.error?.code, -32000, JSON.stringify(refused));
    assert.match(refused.error.message, /secure connection/);
    const after = await list(plain.ws);
    assert.equal(after.result.credentials.length, 0, 'a refused set stores nothing');
    assert.equal(existsSync(join(gw.config.stateDir, 'credentials')), false);
    plain.ws.close();

    const secure = await connect(gw.url, { ...auth(), 'X-Forwarded-Proto': 'https' });
    const ok = await set(secure.ws, { name: 'x', host: 'github.com', token: TOKEN_VALUE });
    assert.equal(ok.error, undefined, JSON.stringify(ok.error));
    secure.ws.close();
  } finally {
    await gw.stop();
  }
});

test('a host off the allow-list is refused; an existing profile keeps its host; an unknown id is refused', async () => {
  const gw = await startGateway({ git: { hosts: ['github.com', '127.0.0.1'] } });
  try {
    const { ws } = await connect(gw.url, auth());
    let res = await set(ws, { name: 'x', host: 'gitlab.com', token: TOKEN_VALUE });
    assert.equal(res.error?.code, -32602);
    assert.match(res.error.message, /allow-list/);

    res = await set(ws, { name: 'loop', host: '127.0.0.1', token: TOKEN_VALUE });
    assert.equal(res.error, undefined, JSON.stringify(res.error));
    const id = res.result.id;
    res = await set(ws, { id, name: 'loop', host: 'github.com', token: TOKEN_VALUE });
    assert.equal(res.error?.code, -32602);
    assert.match(res.error.message, /keeps its host/);
    res = await set(ws, { id: '000000000000', name: 'x', host: '127.0.0.1', token: TOKEN_VALUE });
    assert.equal(res.error?.code, -32602);
    assert.match(res.error.message, /unknown credential/);
    res = await set(ws, { id: '../../etc', name: 'x', host: '127.0.0.1', token: TOKEN_VALUE });
    assert.equal(res.error?.code, -32602);
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('a bad token or name is refused, and the refusal never repeats the token', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    for (const token of ['has space ' + TOKEN_VALUE, TOKEN_VALUE + '\n', 'é' + TOKEN_VALUE, '']) {
      const res = await set(ws, { name: 'x', host: 'github.com', token });
      assert.equal(res.error?.code, -32602);
      assert.doesNotMatch(JSON.stringify(res), new RegExp(TOKEN_VALUE));
    }
    const res = await set(ws, { name: '   ', host: 'github.com', token: TOKEN_VALUE });
    assert.equal(res.error?.code, -32602);
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('delete removes the token file and the metadata, and is audited without the value', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    const { result } = await set(ws, { name: 'gone', host: 'github.com', token: TOKEN_VALUE });
    const file = join(gw.config.stateDir, 'credentials', result.id);
    assert.equal(existsSync(file), true);
    const res = await del(ws, result.id);
    assert.equal(res.error, undefined, JSON.stringify(res.error));
    assert.deepEqual(res.result, {});
    assert.equal(existsSync(file), false);
    assert.equal((await list(ws)).result.credentials.length, 0);
    const again = await del(ws, result.id);
    assert.equal(again.error?.code, -32602);
    const line = await gw.waitForAudit((l) => l.event === 'git_credential_deleted');
    assert.equal(line.credential, result.id);
    assert.doesNotMatch(JSON.stringify(gw.audit), new RegExp(TOKEN_VALUE));
    ws.close();
  } finally {
    await gw.stop();
  }
});

test('another identity sees the same metadata and never the token', async () => {
  const gw = await startGateway();
  try {
    const { ws } = await connect(gw.url, auth());
    await set(ws, { name: 'shared', host: 'github.com', token: TOKEN_VALUE });
    const other = await connect(gw.url, auth('other-token-abcdefghijklmnop'));
    const seen = await list(other.ws);
    assert.equal(seen.result.credentials[0].name, 'shared');
    assert.doesNotMatch(JSON.stringify(seen), new RegExp(TOKEN_VALUE));
    other.ws.close();
    ws.close();
  } finally {
    await gw.stop();
  }
});
