// Audit log: one JSON line per event (FR-9).
// Callers pass only the fields below. Never pass prompt text, tool output or tokens.

const ALLOWED_FIELDS = new Set([
  'identity', 'device', 'client', 'conn', 'status', 'reason', 'method', 'dir', 'code', 'pid', 'exitCode', 'signal',
]);

/** Create an audit writer. `sink` is a function that takes one line (default: stderr). */
export function createAudit(sink = (line) => process.stderr.write(`${line}\n`)) {
  return function audit(event, fields = {}) {
    const record = { ts: new Date().toISOString(), event };
    for (const [key, value] of Object.entries(fields)) {
      if (ALLOWED_FIELDS.has(key) && value !== undefined) record[key] = value;
    }
    sink(JSON.stringify(record));
  };
}
