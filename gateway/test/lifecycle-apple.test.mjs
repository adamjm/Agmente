// The T-46 lifecycle cases on the Apple container runner (migration step 3, D-079): the same tests as
// lifecycle.test.mjs, with fixtures/fake-container.mjs as the container CLI.
process.env.AGMENTE_LIFECYCLE_RUNNER = 'apple';
await import('./lifecycle.test.mjs');
