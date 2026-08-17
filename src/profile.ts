import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export type TransportMode = "full" | "degraded";

export interface ProfileTransport {
  vendorId: number;
  productIds: number[];
  usagePage: number;
  usage: number;
  mode: TransportMode;
}

export interface ControlRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface KeyboardControl {
  id: string;
  kind: "key" | "knobPress";
  label: string;
  code: string;
  matrix: { row: number; column: number };
  ledIndex: number | null;
  bindable: boolean;
  unit: ControlRect;
  frame: ControlRect;
}

export interface EncoderControl {
  id: string;
  kind: "encoder";
  label: string;
  index: number;
  pressControlId: string;
  bindable: boolean;
  ledIndex: null;
  unit: ControlRect;
  frame: ControlRect;
}

export interface KeyboardProfileDocumentV2 {
  $schema?: string;
  profileId: string;
  version: 2;
  layoutHash: string;
  name: string;
  transports: { usb: ProfileTransport; bluetooth: ProfileTransport };
  matrix: { rows: number; columns: number };
  ledCount: number;
  controls: KeyboardControl[];
  encoder: EncoderControl;
  characterMap: Record<string, number>;
  randomKeys: number[];
}

/**
 * Runtime form. The legacy identity fields remain available so existing
 * integrations do not need to understand profile v2 immediately.
 */
export interface KeyboardProfile extends KeyboardProfileDocumentV2 {
  id: string;
  vendorId: number;
  productIds: number[];
  usagePage: number;
  usage: number;
}

const shifted: Record<string, string> = {
  "~": "`", "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8",
  "(": "9", ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";",
  "\"": "'", "<": ",", ">": ".", "?": "/", "\t": " ",
};

function findProfilesDirectory(): string {
  const here = dirname(fileURLToPath(import.meta.url));
  const candidates = [
    resolve(here, "../../profiles"),
    resolve(here, "../../../profiles"),
    resolve(process.cwd(), "profiles"),
  ];
  const found = candidates.find((path) => existsSync(join(path, "keychron-q6-pro-ansi.json")));
  if (!found) throw new Error("Arkey profiles directory is missing");
  return found;
}

export function validateProfile(value: unknown): KeyboardProfileDocumentV2 {
  if (!value || typeof value !== "object") throw new Error("Keyboard profile must be an object");
  const profile = value as KeyboardProfileDocumentV2;
  if (profile.version !== 2 || !profile.profileId || !profile.name) throw new Error("Keyboard profile v2 identity is invalid");
  if (!/^[a-f0-9]{64}$/.test(profile.layoutHash)) throw new Error("Keyboard profile layoutHash is invalid");
  if (!profile.transports?.usb || !profile.transports.bluetooth) throw new Error("Keyboard profile transports are missing");
  if (!Number.isInteger(profile.matrix?.rows) || !Number.isInteger(profile.matrix?.columns)) throw new Error("Keyboard profile matrix is invalid");
  if (!Number.isInteger(profile.ledCount) || profile.ledCount < 1 || profile.ledCount > 255) throw new Error("Keyboard profile ledCount is invalid");
  if (!Array.isArray(profile.controls) || !profile.controls.length) throw new Error("Keyboard profile controls are missing");
  const ids = new Set<string>();
  const matrices = new Set<string>();
  const leds = new Set<number>();
  for (const control of profile.controls) {
    if (!control.id || ids.has(control.id)) throw new Error(`Duplicate keyboard control ${control.id || "<empty>"}`);
    ids.add(control.id);
    if (!control.matrix || !Number.isInteger(control.matrix.row) || !Number.isInteger(control.matrix.column)) throw new Error(`Invalid matrix for ${control.id}`);
    if (control.matrix.row < 0 || control.matrix.row >= profile.matrix.rows || control.matrix.column < 0 || control.matrix.column >= profile.matrix.columns) throw new Error(`Out-of-range matrix for ${control.id}`);
    const matrix = `${control.matrix.row},${control.matrix.column}`;
    if (matrices.has(matrix)) throw new Error(`Duplicate matrix position ${matrix}`);
    matrices.add(matrix);
    if (control.ledIndex !== null) {
      if (!Number.isInteger(control.ledIndex) || control.ledIndex < 0 || control.ledIndex >= profile.ledCount || leds.has(control.ledIndex)) throw new Error(`Invalid LED index for ${control.id}`);
      leds.add(control.ledIndex);
    }
    for (const rect of [control.unit, control.frame]) {
      if (!rect || ![rect.x, rect.y, rect.width, rect.height].every(Number.isFinite) || rect.width <= 0 || rect.height <= 0) throw new Error(`Invalid geometry for ${control.id}`);
    }
  }
  if (!profile.encoder || profile.encoder.kind !== "encoder" || !ids.has(profile.encoder.pressControlId)) throw new Error("Keyboard profile encoder is invalid");
  if (leds.size !== profile.ledCount) throw new Error(`Keyboard profile exposes ${leds.size} LEDs, expected ${profile.ledCount}`);
  const hashSource = JSON.stringify({ controls: profile.controls, encoder: profile.encoder, ledCount: profile.ledCount, matrix: profile.matrix });
  const expected = createHash("sha256").update(hashSource).digest("hex");
  if (profile.layoutHash !== expected) throw new Error("Keyboard profile layoutHash does not match its layout");
  return profile;
}

export function loadProfile(path: string): KeyboardProfile {
  const raw = validateProfile(JSON.parse(readFileSync(path, "utf8")) as unknown);
  const characterMap = { ...raw.characterMap };
  for (const [character, base] of Object.entries(shifted)) {
    if (characterMap[base] !== undefined) characterMap[character] = characterMap[base];
  }
  for (const letter of "abcdefghijklmnopqrstuvwxyz") {
    if (characterMap[letter] !== undefined) characterMap[letter.toUpperCase()] = characterMap[letter];
  }
  const usb = raw.transports.usb;
  return {
    ...raw,
    characterMap,
    id: raw.profileId,
    vendorId: usb.vendorId,
    productIds: [...usb.productIds],
    usagePage: usb.usagePage,
    usage: usb.usage,
  };
}

export function profileDocument(profile: KeyboardProfile): KeyboardProfileDocumentV2 {
  const { id: _id, vendorId: _vendorId, productIds: _productIds, usagePage: _usagePage, usage: _usage, ...document } = profile;
  const canonicalCharacterMap = Object.fromEntries(Object.entries(document.characterMap).filter(([key]) => {
    if (key.length === 1 && /[A-Z]/.test(key)) return false;
    return shifted[key] === undefined;
  }));
  return { ...document, characterMap: canonicalCharacterMap };
}

export const profileDirectory = findProfilesDirectory();
export const q6ProAnsi = loadProfile(join(profileDirectory, "keychron-q6-pro-ansi.json"));
export const v1MaxAnsiKnob = loadProfile(join(profileDirectory, "keychron-v1-max-ansi-knob.json"));
export const profiles: KeyboardProfile[] = [q6ProAnsi, v1MaxAnsiKnob];

export function mapText(profile: KeyboardProfile, text: string): number[] {
  const fallback = profile.characterMap[" "];
  return [...text].map((character) => profile.characterMap[character] ?? (character.trim() ? fallback : profile.characterMap[" "]));
}

export function controlForMatrix(profile: KeyboardProfile, row: number, column: number): KeyboardControl | undefined {
  return profile.controls.find((control) => control.matrix.row === row && control.matrix.column === column);
}
