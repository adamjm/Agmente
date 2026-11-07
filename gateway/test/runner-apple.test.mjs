// runner.kind "apple" (D-079): the Apple container runner is accepted by config; its CLI path is absolute.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { dryRun, rawConfig } from './helpers.mjs';

const apple = (extra) => rawConfig('/srv/p', { runner: { kind: 'apple', image: 'agmente-bob:2.0.9', ...extra } });

test('kind apple is accepted and reports its container CLI', async () => {
  const run = await dryRun(apple({ container: '/opt/homebrew/bin/container' }));
  assert.equal(run.status, 0, run.stderr);
  assert.match(run.stdout, /"kind": "apple"/);
  assert.match(run.stdout, /\/opt\/homebrew\/bin\/container/);
});

test('kind apple works with the default CLI name', async () => {
  const run = await dryRun(apple({}));
  assert.equal(run.status, 0, run.stderr);
});

test('a relative runner.container path is refused', async () => {
  const run = await dryRun(apple({ container: 'container' }));
  assert.notEqual(run.status, 0);
  assert.match(run.stderr, /runner\.container must be an absolute path/);
});

test('the error for an unknown runner kind names apple too', async () => {
  const run = await dryRun(rawConfig('/srv/p', { runner: { kind: 'nope' } }));
  assert.notEqual(run.status, 0);
  assert.match(run.stderr, /"podman", "apple" or "host"/);
});

test('runner.dns must be an IP address when it is set', async () => {
  const ok = await dryRun(apple({ dns: '1.1.1.1' }));
  assert.equal(ok.status, 0, ok.stderr);
  for (const bad of ['dns.example.com', '1.1.1.1/32', 42]) {
    const run = await dryRun(apple({ dns: bad }));
    assert.notEqual(run.status, 0, JSON.stringify(bad));
    assert.match(run.stderr, /runner\.dns must be an IP address/);
  }
});
