import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { cleanupExpiredDiagnostics, createDiagnosticsServer } from '../server/arkey-diagnostics-api.mjs';

async function withServer(run) {
  const root = await mkdtemp(join(tmpdir(), 'arkey-diagnostics-test-'));
  const server = createDiagnosticsServer({ storageDir: root, logger: { error() {} } });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  try {
    await run(`http://127.0.0.1:${port}`, root);
  } finally {
    await new Promise((resolve) => server.close(resolve));
    await rm(root, { recursive: true, force: true });
  }
}

test('diagnostics API registers an anonymous installation and accepts redacted events', async () => {
  await withServer(async (base) => {
    const installation = await fetch(`${base}/v1/installations`, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ schemaVersion: 1, installationID: 'f5f8d330-4a84-4df1-a42b-23f1da3b6ae9', appVersion: '3.0.0' }),
    });
    assert.equal(installation.status, 201);
    const { token } = await installation.json();
    assert.match(token, /^[A-Za-z0-9_-]{32,}$/);

    const upload = await fetch(`${base}/v1/diagnostics`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${token}` },
      body: JSON.stringify({
        schemaVersion: 1,
        installationID: 'f5f8d330-4a84-4df1-a42b-23f1da3b6ae9',
        session: { id: 'ARK-test' },
        events: [{ id: 'event-1', timestamp: '2026-08-16T00:00:00Z', category: 'hid', name: 'configuration.timeout', details: { reportID: '07' } }],
      }),
    });
    assert.equal(upload.status, 202);
  });
});

test('diagnostics API rejects forbidden sensitive fields', async () => {
  await withServer(async (base) => {
    const installation = await fetch(`${base}/v1/installations`, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ schemaVersion: 1, installationID: 'f5f8d330-4a84-4df1-a42b-23f1da3b6ae9', appVersion: '3.0.0' }),
    });
    const { token } = await installation.json();
    const upload = await fetch(`${base}/v1/diagnostics`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${token}` },
      body: JSON.stringify({ schemaVersion: 1, installationID: 'f5f8d330-4a84-4df1-a42b-23f1da3b6ae9', events: [{ id: 'event-1', timestamp: 'now', category: 'hid', name: 'bad', details: { serialNumber: 'must not pass' } }] }),
    });
    assert.equal(upload.status, 400);
  });
});

test('diagnostics API bounds a permitted diagnostic value before storage', async () => {
  await withServer(async (base, root) => {
    const installation = await fetch(`${base}/v1/installations`, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ schemaVersion: 1, installationID: 'f5f8d330-4a84-4df1-a42b-23f1da3b6ae9', appVersion: '3.0.0' }),
    });
    const { token } = await installation.json();
    const upload = await fetch(`${base}/v1/diagnostics`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${token}` },
      body: JSON.stringify({ schemaVersion: 1, installationID: 'f5f8d330-4a84-4df1-a42b-23f1da3b6ae9', events: [{ id: 'event-1', timestamp: 'now', category: 'hid', name: 'bounded', details: { error: 'x'.repeat(700) } }] }),
    });
    assert.equal(upload.status, 202);
    const { readdir, readFile } = await import('node:fs/promises');
    const date = new Date().toISOString().slice(0, 10);
    const [file] = await readdir(join(root, 'events', date));
    const stored = JSON.parse(await readFile(join(root, 'events', date, file), 'utf8'));
    assert.equal(stored.events[0].details.error.length, 500);
  });
});

test('diagnostics retention deletes only dated event folders older than 30 days', async () => {
  const root = await mkdtemp(join(tmpdir(), 'arkey-diagnostics-retention-'));
  try {
    await mkdir(join(root, 'events', '2026-07-16'), { recursive: true });
    await mkdir(join(root, 'events', '2026-07-17'), { recursive: true });
    await mkdir(join(root, 'events', 'not-a-date'), { recursive: true });
    const removed = await cleanupExpiredDiagnostics(root, {
      now: () => new Date('2026-08-16T12:00:00.000Z'),
      logger: { info() {} },
    });
    assert.equal(removed, 1);
    assert.deepEqual((await readdir(join(root, 'events'))).sort(), ['2026-07-17', 'not-a-date']);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
