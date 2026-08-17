#!/usr/bin/env node
import { readFile, writeFile } from 'node:fs/promises';

const [payloadPath, signaturePath, outputPath] = process.argv.slice(2);
if (!payloadPath || !signaturePath || !outputPath || process.argv.length !== 5) {
  console.error('usage: seal-release-manifest.mjs <payload> <signature> <output>');
  process.exit(64);
}

const [payload, signature] = await Promise.all([readFile(payloadPath), readFile(signaturePath)]);
const envelope = {
  algorithm: 'ed25519',
  keyID: 'arkey-update-2026-01',
  payload: payload.toString('base64'),
  signature: signature.toString('base64'),
};
await writeFile(outputPath, `${JSON.stringify(envelope)}\n`, { mode: 0o600 });
