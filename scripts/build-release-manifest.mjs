#!/usr/bin/env node
import { existsSync } from 'node:fs';
import { readFile, writeFile } from 'node:fs/promises';

function usage() {
  console.error('usage: build-release-manifest.mjs --version <version> --dmg-url <https-url> --sha256 <hash> --size <bytes> --payload-out <file> [--existing <signed-manifest>] [--note <text>] [--firmware <name[,name]>] [--signature <file> --output <manifest>]');
  process.exit(64);
}

const options = new Map();
const notes = [];
for (let index = 2; index < process.argv.length; index += 1) {
  const key = process.argv[index];
  if (!key.startsWith('--')) usage();
  const value = process.argv[index + 1];
  if (!value || value.startsWith('--')) usage();
  if (key === '--note') notes.push(value);
  else options.set(key, value);
  index += 1;
}
for (const key of ['--version', '--dmg-url', '--sha256', '--size', '--payload-out']) if (!options.has(key)) usage();

const version = options.get('--version');
const sha256 = options.get('--sha256').toLowerCase();
const size = Number(options.get('--size'));
if (!/^[0-9A-Za-z._-]{1,80}$/.test(version) || !/^[a-f0-9]{64}$/.test(sha256) || !Number.isSafeInteger(size) || size <= 0) usage();
const url = new URL(options.get('--dmg-url'));
if (url.protocol !== 'https:') usage();

function canonicalTimestamp(value = Date.now()) {
  const date = new Date(value);
  if (Number.isNaN(date.valueOf())) throw new Error('release catalog contains an invalid timestamp');
  // Foundation's stock `.iso8601` strategy accepts the Internet date form but
  // not fractional seconds on supported client builds. Keep the published
  // protocol conservative while the client also accepts both variants.
  return date.toISOString().replace(/\.\d{3}Z$/, 'Z');
}

let catalog = { schemaVersion: 1, generatedAt: canonicalTimestamp(), releases: [] };
const existing = options.get('--existing');
if (existing && existsSync(existing)) {
  const envelope = JSON.parse(await readFile(existing, 'utf8'));
  if (envelope.algorithm !== 'ed25519' || typeof envelope.payload !== 'string') throw new Error('existing manifest is not a signed Ed25519 envelope');
  catalog = JSON.parse(Buffer.from(envelope.payload, 'base64').toString('utf8'));
  if (catalog.schemaVersion !== 1 || !Array.isArray(catalog.releases)) throw new Error('existing catalog schema is unsupported');
  catalog.releases = catalog.releases.map((item) => ({ ...item, publishedAt: canonicalTimestamp(item.publishedAt) }));
}

const release = {
  id: version,
  version,
  publishedAt: canonicalTimestamp(),
  dmgURL: url.href,
  sha256,
  size,
  notes: notes.map((item) => item.slice(0, 500)),
  firmware: (options.get('--firmware') ?? '').split(',').map((item) => item.trim()).filter(Boolean).map((item) => item.slice(0, 160)),
};
catalog = {
  schemaVersion: 1,
  generatedAt: canonicalTimestamp(),
  releases: [...catalog.releases.filter((item) => item.id !== release.id), release],
};
const payload = Buffer.from(JSON.stringify(catalog));
await writeFile(options.get('--payload-out'), payload, { mode: 0o600 });

if (options.has('--signature') || options.has('--output')) {
  if (!options.has('--signature') || !options.has('--output')) usage();
  const signature = await readFile(options.get('--signature'));
  const envelope = {
    algorithm: 'ed25519',
    keyID: 'arkey-update-2026-01',
    payload: payload.toString('base64'),
    signature: signature.toString('base64'),
  };
  await writeFile(options.get('--output'), `${JSON.stringify(envelope)}\n`, { mode: 0o600 });
}
