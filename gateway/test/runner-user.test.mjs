// runner.containerUid / containerGid (D-051): optional, 1 to 65535, podman runner only.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { dryRun, rawConfig } from './helpers.mjs';

const podman = (extra) => rawConfig('/srv/p', { runner: { kind: 'podman', image: 'agmente-bob:2.0.9', ...extra } });

test('the container user is optional and defaults to the image user', async () => {
  const run = await dryRun(podman({}));
  assert.equal(run.status, 0, run.stderr);
  const withIds = await dryRun(podman({ containerUid: 1234, containerGid: 4321 }));
  assert.equal(withIds.status, 0, withIds.stderr);
  const summary = JSON.parse(withIds.stdout.slice(withIds.stdout.indexOf('{'), withIds.stdout.lastIndexOf('}') + 1));
  assert.equal(summary.runner.containerUid, 1234);
  assert.equal(summary.runner.containerGid, 4321);
});

test('a container uid or gid of 0, out of range or not an integer is refused', async () => {
  for (const key of ['containerUid', 'containerGid']) {
    for (const value of [0, -1, 65536, 1.5, '10001', true]) {
      const run = await dryRun(podman({ [key]: value }));
      assert.notEqual(run.status, 0, `${key}=${JSON.stringify(value)}`);
      assert.match(run.stderr, new RegExp(`runner\\.${key} must be an integer from 1 to 65535`));
    }
  }
});
