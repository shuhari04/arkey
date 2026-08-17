#!/usr/bin/env node
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";

const [, , keyboardJsonPath, outputPath] = process.argv;
if (!keyboardJsonPath || !outputPath) {
  throw new Error("Usage: node scripts/generate-v1-max-profile.mjs <keyboard.json> <output.json>");
}

const layout = JSON.parse(readFileSync(keyboardJsonPath, "utf8")).layouts.LAYOUT_ansi_82.layout;
const labels = [
  { 0: "Esc", 1: "F1", 2: "F2", 3: "F3", 4: "F4", 5: "F5", 6: "F6", 7: "F7", 8: "F8", 9: "F9", 10: "F10", 11: "F11", 12: "F12", 13: "Del", 15: "Knob" },
  { 0: "`", 1: "1", 2: "2", 3: "3", 4: "4", 5: "5", 6: "6", 7: "7", 8: "8", 9: "9", 10: "0", 11: "-", 12: "=", 13: "Backspace", 15: "PgUp" },
  { 0: "Tab", 1: "Q", 2: "W", 3: "E", 4: "R", 5: "T", 6: "Y", 7: "U", 8: "I", 9: "O", 10: "P", 11: "[", 12: "]", 13: "\\", 15: "PgDn" },
  { 0: "Caps", 1: "A", 2: "S", 3: "D", 4: "F", 5: "G", 6: "H", 7: "J", 8: "K", 9: "L", 10: ";", 11: "'", 13: "Enter", 15: "Home" },
  { 0: "Shift", 2: "Z", 3: "X", 4: "C", 5: "V", 6: "B", 7: "N", 8: "M", 9: ",", 10: ".", 11: "/", 12: "Shift", 14: "Up" },
  { 0: "Ctrl", 1: "Option", 2: "Command", 6: "Space", 10: "Command", 11: "Fn", 12: "Ctrl", 13: "Left", 14: "Down", 15: "Right" },
];
const codeFor = (label) => {
  if (/^[A-Z]$/.test(label)) return `KC_${label}`;
  if (/^[0-9]$/.test(label)) return `KC_${label}`;
  return { "`": "KC_GRV", "-": "KC_MINS", "=": "KC_EQL", "[": "KC_LBRC", "]": "KC_RBRC", "\\": "KC_BSLS", ";": "KC_SCLN", "'": "KC_QUOT", ",": "KC_COMM", ".": "KC_DOT", "/": "KC_SLSH", Space: "KC_SPC", Enter: "KC_ENT", Backspace: "KC_BSPC", Esc: "KC_ESC", Tab: "KC_TAB", Caps: "KC_CAPS", Shift: "KC_LSFT", Ctrl: "KC_LCTL", Option: "KC_LOPTN", Command: "KC_LCMMD", Fn: "MO(1)", Del: "KC_DEL", PgUp: "KC_PGUP", PgDn: "KC_PGDN", Home: "KC_HOME", Up: "KC_UP", Left: "KC_LEFT", Down: "KC_DOWN", Right: "KC_RGHT", Knob: "KC_MUTE" }[label] ?? "KC_NO";
};
const maxX = Math.max(...layout.map((key) => key.x + (key.w ?? 1)));
const maxY = Math.max(...layout.map((key) => key.y + (key.h ?? 1)));
let led = 0;
const controls = layout.map((key) => {
  const [row, column] = key.matrix;
  const label = (labels[row] ?? {})[column] ?? `r${row}c${column}`;
  const isKnob = row === 0 && column === 15;
  const unit = { x: key.x, y: key.y, width: key.w ?? 1, height: key.h ?? 1 };
  return {
    id: `r${row}c${column}`,
    kind: "key",
    label,
    code: codeFor(label),
    matrix: { row, column },
    ledIndex: isKnob ? null : led++,
    bindable: true,
    unit,
    frame: { x: unit.x / maxX, y: unit.y / maxY, width: unit.width / maxX, height: unit.height / maxY },
  };
});
const characterMap = Object.fromEntries(controls.filter((key) => key.label.length === 1).map((key) => [key.label.toLowerCase(), key.ledIndex]).filter(([, ledIndex]) => ledIndex !== null));
characterMap[" "] = controls.find((key) => key.label === "Space").ledIndex;
const encoder = { id: "encoder-0", kind: "encoder", label: "Knob", index: 0, pressControlId: "r0c15", bindable: true, ledIndex: null };
const profile = {
  $schema: "./schema.json",
  profileId: "keychron-v1-max-ansi-knob",
  version: 2,
  layoutHash: "",
  name: "Keychron V1 Max ANSI Knob",
  transports: {
    // V1 Max uses QMK's default Raw HID descriptor.  Q6 Pro overrides this
    // to FF00, but V1 Max is FF60; matching FF00 makes macOS miss the device.
    usb: { vendorId: 0x3434, productIds: [0x0913], usagePage: 0xff60, usage: 0x61, mode: "full" },
    bluetooth: { vendorId: 0x3434, productIds: [0x0913], usagePage: 1, usage: 6, mode: "degraded" },
  },
  matrix: { rows: 6, columns: 16 },
  ledCount: led,
  controls,
  encoder,
  characterMap,
  randomKeys: controls.filter((key) => key.ledIndex !== null).slice(0, 12).map((key) => key.ledIndex),
};
profile.layoutHash = createHash("sha256").update(JSON.stringify({ controls: profile.controls, encoder: profile.encoder, ledCount: profile.ledCount, matrix: profile.matrix })).digest("hex");
writeFileSync(outputPath, `${JSON.stringify(profile, null, 2)}\n`);
process.stdout.write(`Generated ${outputPath} (${profile.ledCount} LEDs; ${profile.layoutHash.slice(0, 8)})\n`);
