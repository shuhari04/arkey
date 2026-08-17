import { createHash, randomBytes } from 'node:crypto';
import { createServer } from 'node:http';
import { mkdir, readFile, readdir, rename, rm, stat, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';

const MAX_BODY_BYTES = 256 * 1024;
const MAX_EVENTS = 500;
const RETENTION_DAYS = 30;
const FORBIDDEN_DETAIL_KEY = /(serial|workspace|prompt|keystroke|raw|key)/i;

function hash(value) {
  return createHash('sha256').update(value).digest('hex');
}

function json(res, status, value) {
  const body = Buffer.from(JSON.stringify(value));
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': body.length,
    'cache-control': 'no-store',
  });
  res.end(body);
}

function requestIP(req) {
  const forwarded = req.headers['x-forwarded-for'];
  if (typeof forwarded === 'string' && forwarded.length) return forwarded.split(',')[0].trim();
  return req.socket.remoteAddress ?? 'unknown';
}

function safeString(value, maximum = 500) {
  return typeof value === 'string' ? value.replace(/[\r\n]/g, ' ').slice(0, maximum) : '';
}

function sanitiseDiagnosticPayload(value) {
  if (!value || value.schemaVersion !== 1 || typeof value.installationID !== 'string' || !Array.isArray(value.events)) return false;
  if (value.events.length === 0 || value.events.length > MAX_EVENTS) return false;
  const events = [];
  for (const event of value.events) {
    if (!event || typeof event !== 'object' || !event.id || !event.timestamp || !event.category || !event.name) return false;
    const details = {};
    if (event.details && typeof event.details === 'object' && !Array.isArray(event.details)) {
      for (const [key, detail] of Object.entries(event.details)) {
        if (FORBIDDEN_DETAIL_KEY.test(key)) return false;
        details[safeString(key, 80)] = safeString(detail, 500);
      }
    }
    events.push({
      id: safeString(String(event.id), 80),
      timestamp: safeString(String(event.timestamp), 40),
      sessionID: event.sessionID ? safeString(String(event.sessionID), 80) : null,
      category: safeString(String(event.category), 32),
      severity: safeString(String(event.severity ?? 'info'), 16),
      name: safeString(String(event.name), 160),
      details,
    });
  }
  return {
    schemaVersion: 1,
    installationID: safeString(value.installationID, 64),
    session: value.session ? {
      id: safeString(String(value.session.id ?? ''), 80),
      reason: safeString(String(value.session.reason ?? ''), 160),
      startedAt: safeString(String(value.session.startedAt ?? ''), 40),
      endedAt: value.session.endedAt ? safeString(String(value.session.endedAt), 40) : null,
      uploadState: safeString(String(value.session.uploadState ?? ''), 32),
    } : null,
    events,
  };
}

async function readJSONBody(req) {
  const chunks = [];
  let total = 0;
  for await (const chunk of req) {
    total += chunk.length;
    if (total > MAX_BODY_BYTES) {
      const error = new Error('payload too large');
      error.status = 413;
      throw error;
    }
    chunks.push(chunk);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    const error = new Error('invalid json');
    error.status = 400;
    throw error;
  }
}

async function writeJSONAtomically(path, value, mode = 0o600) {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  const temporary = `${path}.${process.pid}.${randomBytes(5).toString('hex')}.tmp`;
  await writeFile(temporary, JSON.stringify(value), { mode });
  await rename(temporary, path);
}

/**
 * Remove only date-shaped event directories that are older than the retention
 * window. Tokens are intentionally left alone: they contain no diagnostics and
 * let a client retry a failed upload without sending a new installation ID.
 */
export async function cleanupExpiredDiagnostics(storageDir, { now = () => new Date(), retentionDays = RETENTION_DAYS, logger = console } = {}) {
  const eventsDirectory = join(storageDir, 'events');
  let entries;
  try {
    entries = await readdir(eventsDirectory, { withFileTypes: true });
  } catch (error) {
    if (error?.code === 'ENOENT') return 0;
    throw error;
  }
  const cutoff = new Date(now());
  cutoff.setUTCHours(0, 0, 0, 0);
  cutoff.setUTCDate(cutoff.getUTCDate() - retentionDays);
  let removed = 0;
  for (const entry of entries) {
    if (!entry.isDirectory() || !/^\d{4}-\d{2}-\d{2}$/.test(entry.name)) continue;
    const date = new Date(`${entry.name}T00:00:00.000Z`);
    if (Number.isNaN(date.valueOf()) || date >= cutoff) continue;
    const target = join(eventsDirectory, entry.name);
    await rm(target, { recursive: true, force: true });
    removed += 1;
  }
  if (removed) logger.info?.('arkey diagnostics retention cleanup', { removed, retentionDays });
  return removed;
}

export function createDiagnosticsServer({ storageDir, now = () => new Date(), logger = console } = {}) {
  if (!storageDir) throw new Error('storageDir is required');
  const rateWindows = new Map();

  function allowed(req, limit, windowMilliseconds) {
    const ip = requestIP(req);
    const key = `${limit}:${ip}`;
    const timestamp = now().getTime();
    const values = (rateWindows.get(key) ?? []).filter((item) => timestamp - item < windowMilliseconds);
    if (values.length >= limit) return false;
    values.push(timestamp);
    rateWindows.set(key, values);
    return true;
  }

  return createServer(async (req, res) => {
    try {
      const url = new URL(req.url ?? '/', 'http://localhost');
      if (req.method === 'GET' && url.pathname === '/healthz') {
        return json(res, 200, { ok: true, service: 'arkey-diagnostics', timestamp: now().toISOString() });
      }
      if (req.method === 'POST' && url.pathname === '/v1/installations') {
        if (!allowed(req, 12, 60 * 60 * 1000)) return json(res, 429, { error: 'rate_limited' });
        const body = await readJSONBody(req);
        if (body?.schemaVersion !== 1 || !/^[a-f0-9-]{16,64}$/i.test(body.installationID ?? '')) {
          return json(res, 400, { error: 'invalid_installation' });
        }
        const token = randomBytes(32).toString('base64url');
        const tokenHash = hash(token);
        await writeJSONAtomically(join(storageDir, 'tokens', `${tokenHash}.json`), {
          createdAt: now().toISOString(),
          installationHash: hash(body.installationID),
          appVersion: safeString(body.appVersion, 64),
        });
        return json(res, 201, { token });
      }
      if (req.method === 'POST' && url.pathname === '/v1/diagnostics') {
        if (!allowed(req, 30, 60 * 60 * 1000)) return json(res, 429, { error: 'rate_limited' });
        const bearer = req.headers.authorization?.match(/^Bearer ([A-Za-z0-9_-]{32,})$/)?.[1];
        if (!bearer) return json(res, 401, { error: 'missing_token' });
        const tokenPath = join(storageDir, 'tokens', `${hash(bearer)}.json`);
        try {
          const token = JSON.parse(await readFile(tokenPath, 'utf8'));
          if (!token?.installationHash) throw new Error('invalid token');
        } catch {
          return json(res, 401, { error: 'invalid_token' });
        }
        const body = sanitiseDiagnosticPayload(await readJSONBody(req));
        if (!body) return json(res, 400, { error: 'invalid_diagnostic_payload' });
        const date = now().toISOString().slice(0, 10);
        const sessionID = safeString(body.session?.id, 80).replace(/[^A-Za-z0-9_-]/g, '_') || 'unspecified';
        const filename = `${now().getTime()}-${sessionID}-${randomBytes(6).toString('hex')}.json`;
        await writeJSONAtomically(join(storageDir, 'events', date, filename), {
          receivedAt: now().toISOString(),
          installationHash: hash(body.installationID),
          session: body.session ?? null,
          events: body.events,
        });
        return json(res, 202, { accepted: true });
      }
      return json(res, 404, { error: 'not_found' });
    } catch (error) {
      const status = Number.isInteger(error?.status) ? error.status : 500;
      logger.error?.('arkey diagnostics request failed', { status, message: error?.message });
      return json(res, status, { error: status === 500 ? 'internal_error' : error.message });
    }
  });
}

export async function startDiagnosticsServer({ storageDir = process.env.ARKEY_DIAGNOSTICS_DIR ?? '/var/lib/arkey-diagnostics', port = Number(process.env.ARKEY_DIAGNOSTICS_PORT ?? 18220), now = () => new Date(), retentionDays = RETENTION_DAYS, logger = console } = {}) {
  await mkdir(storageDir, { recursive: true, mode: 0o700 });
  await cleanupExpiredDiagnostics(storageDir, { now, retentionDays, logger });
  const cleanupTimer = setInterval(() => {
    void cleanupExpiredDiagnostics(storageDir, { now, retentionDays, logger }).catch((error) => logger.error?.('arkey diagnostics retention cleanup failed', { message: error?.message }));
  }, 24 * 60 * 60 * 1000);
  cleanupTimer.unref?.();
  const server = createDiagnosticsServer({ storageDir, now, logger });
  server.once('close', () => clearInterval(cleanupTimer));
  await new Promise((resolve) => server.listen(port, '127.0.0.1', resolve));
  console.log(`ARkey diagnostics API listening on 127.0.0.1:${port}`);
  return server;
}

if (process.env.ARKEY_DIAGNOSTICS_LISTEN === '1') {
  const server = await startDiagnosticsServer();
  for (const signal of ['SIGINT', 'SIGTERM']) {
    process.on(signal, () => server.close(() => process.exit(0)));
  }
}
