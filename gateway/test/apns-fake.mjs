// A fake APNs server for the push tests (PLAN 3.11, D-053, D-055). It speaks HTTP/2 over TLS, as
// api.push.apple.com does, with a throwaway certificate and a throwaway ES256 key made at run time
// with openssl. Nothing here is a real Apple credential, and nothing is sent to Apple.
import { execFileSync } from 'node:child_process';
import { chmodSync, readFileSync, writeFileSync } from 'node:fs';
import { mkdtemp, rm } from 'node:fs/promises';
import { createPublicKey, createVerify, generateKeyPairSync } from 'node:crypto';
import http2 from 'node:http2';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

export const KEY_ID = 'TESTKEY123';
export const TEAM_ID = 'TEAM123456';
export const TOPIC = 'com.example.agmente.test';

/**
 * Make a throwaway key (PKCS#8, the .p8 format), its public half, and a self-signed certificate for
 * 127.0.0.1 and localhost. The certificate is the test-only CA the gateway trusts (push.caFile).
 */
export async function makeMaterial() {
  const dir = await mkdtemp(join(tmpdir(), 'agmente-apns-'));
  const keyFile = join(dir, `AuthKey_${KEY_ID}.p8`);
  const pubFile = join(dir, 'public.pem');
  const certFile = join(dir, 'ca.pem');
  const certKey = join(dir, 'ca-key.pem');
  // The key comes from Node's OpenSSL, which writes a standard PKCS#8 PEM. (LibreSSL's EC PKCS#8
  // output does not parse in Go: "unknown elliptic curve".)
  const pair = generateKeyPairSync('ec', { namedCurve: 'P-256' });
  writeFileSync(keyFile, pair.privateKey.export({ type: 'pkcs8', format: 'pem' }), { mode: 0o600 });
  chmodSync(keyFile, 0o600);
  writeFileSync(pubFile, pair.publicKey.export({ type: 'spki', format: 'pem' }));
  // The certificate's key also comes from Node: LibreSSL's EC certificates use explicit curve
  // parameters, which Go refuses ("invalid ECDSA parameters").
  const certPair = generateKeyPairSync('ec', { namedCurve: 'P-256' });
  writeFileSync(certKey, certPair.privateKey.export({ type: 'pkcs8', format: 'pem' }), { mode: 0o600 });
  execFileSync('openssl', [
    'req', '-x509', '-new', '-key', certKey, '-sha256', '-out', certFile, '-days', '1', '-subj', '/CN=localhost',
    '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1',
    '-addext', 'basicConstraints=critical,CA:TRUE',
    '-addext', 'keyUsage=critical,digitalSignature',
    '-addext', 'extendedKeyUsage=serverAuth',
  ], { stdio: 'ignore' });
  return {
    dir,
    keyFile,
    publicPem: readFileSync(pubFile, 'utf8'),
    certFile,
    certKey,
    cleanup: () => rm(dir, { recursive: true, force: true }),
  };
}

/**
 * Check an ES256 provider token the way Apple does: the header and claims, and the signature
 * against the public key. Returns { ok, header, claims }.
 */
export function verifyProviderToken(jwt, publicPem) {
  const [h, c, s] = String(jwt).split('.');
  const verifier = createVerify('SHA256');
  verifier.update(`${h}.${c}`);
  verifier.end();
  const ok = verifier.verify({ key: createPublicKey(publicPem), dsaEncoding: 'ieee-p1363' }, Buffer.from(s ?? '', 'base64url'));
  return {
    ok: ok && Buffer.from(s, 'base64url').length === 64,
    header: JSON.parse(Buffer.from(h, 'base64url').toString('utf8')),
    claims: JSON.parse(Buffer.from(c, 'base64url').toString('utf8')),
  };
}

/**
 * Start a fake APNs server on 127.0.0.1. Each request is recorded. `answers` is a queue of
 * { status, reason } consumed first; when it is empty, `fallback` answers (200 by default).
 */
export function startFakeApns(material) {
  const server = http2.createSecureServer({
    key: readFileSync(material.certKey),
    cert: readFileSync(material.certFile),
    allowHTTP1: false,
  });
  const fake = {
    requests: [],
    answers: [],
    fallback: { status: 200 },
    url: '',
    port: 0,
    // server.close waits for open HTTP/2 sessions, and the gateway keeps its own open: drop them first.
    close: () => new Promise((r) => {
      for (const session of sessions) session.destroy();
      server.close(() => r());
    }),
  };
  const sessions = new Set();
  server.on('session', (session) => {
    sessions.add(session);
    session.on('close', () => sessions.delete(session));
  });
  server.on('stream', (stream, headers) => {
    const chunks = [];
    stream.on('data', (d) => chunks.push(d));
    stream.on('end', () => {
      fake.requests.push({
        method: headers[':method'],
        path: headers[':path'],
        headers: { ...headers },
        body: Buffer.concat(chunks).toString('utf8'),
        httpVersion: '2.0',
      });
      const answer = fake.answers.shift() ?? fake.fallback;
      stream.respond({ ':status': answer.status, 'content-type': 'application/json' });
      stream.end(answer.reason ? JSON.stringify({ reason: answer.reason }) : undefined);
    });
  });
  return new Promise((resolveStart, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      fake.port = server.address().port;
      fake.url = `https://127.0.0.1:${fake.port}`;
      resolveStart(fake);
    });
  });
}

/** The push block of the gateway config, pointing at a fake server for both environments. */
export function pushConfig(material, sandboxURL, productionURL = sandboxURL) {
  return {
    keyFile: material.keyFile,
    keyId: KEY_ID,
    teamId: TEAM_ID,
    topic: TOPIC,
    sandboxURL,
    productionURL,
    caFile: material.certFile,
  };
}
