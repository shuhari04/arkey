import assert from "node:assert/strict";
import test from "node:test";
import { mapText, profileDocument, q6ProAnsi, validateProfile, v1MaxAnsiKnob } from "../src/profile.js";
import { effectCatalog, semanticEffect } from "../src/effects.js";
import { EffectPrimitive } from "../src/protocol.js";

test("maps lower, upper and shifted characters to the same physical keys", () => {
  assert.deepEqual(mapText(q6ProAnsi, "aA!"), [63, 63, 21]);
});

test("maps code punctuation and whitespace", () => {
  assert.deepEqual(mapText(q6ProAnsi, "{}\n "), [52, 53, 74, 98]);
});

test("unknown unicode uses a visible fallback without retaining text", () => {
  assert.deepEqual(mapText(q6ProAnsi, "中"), [98]);
});

test("Q6 profile is the canonical 109-control ANSI knob layout", () => {
  assert.equal(q6ProAnsi.profileId, "keychron-q6-pro-ansi-knob");
  assert.equal(q6ProAnsi.version, 2);
  assert.equal(q6ProAnsi.controls.length, 109);
  assert.equal(q6ProAnsi.ledCount, 108);
  assert.equal(q6ProAnsi.layoutHash, "de355358987dddc4f73a610892192e63e36facecc2417aa4b4e0ac4a40a63346");
  assert.deepEqual(q6ProAnsi.controls.filter((control) => control.ledIndex === null).map((control) => control.id), ["r0c13"]);
  assert.equal(new Set(q6ProAnsi.controls.flatMap((control) => control.ledIndex === null ? [] : [control.ledIndex])).size, 108);
  assert.equal(q6ProAnsi.encoder.pressControlId, "r0c13");
  assert.ok(q6ProAnsi.controls.every((control) => control.frame.x >= 0 && control.frame.x <= 1 && control.frame.y >= 0 && control.frame.y <= 1));
});

test("V1 Max profile is a separate ANSI knob layout with its own transport identity", () => {
  assert.equal(v1MaxAnsiKnob.profileId, "keychron-v1-max-ansi-knob");
  assert.equal(v1MaxAnsiKnob.version, 2);
  assert.equal(v1MaxAnsiKnob.matrix.rows, 6);
  assert.equal(v1MaxAnsiKnob.matrix.columns, 16);
  assert.equal(v1MaxAnsiKnob.ledCount, 81);
  assert.equal(v1MaxAnsiKnob.transports.usb.vendorId, 0x3434);
  assert.ok(v1MaxAnsiKnob.transports.usb.productIds.includes(0x0913));
  assert.equal(v1MaxAnsiKnob.encoder.pressControlId, "r0c15");
  assert.equal(validateProfile(profileDocument(v1MaxAnsiKnob)).layoutHash, v1MaxAnsiKnob.layoutHash);
});

test("profile document validates its hash and excludes runtime compatibility aliases", () => {
  const document = profileDocument(q6ProAnsi);
  assert.equal(validateProfile(document).layoutHash, q6ProAnsi.layoutHash);
  assert.equal("vendorId" in document, false);
  assert.throws(() => validateProfile({ ...document, layoutHash: "0".repeat(64) }), /layoutHash/);
});

test("canonical effect catalog locks AgentGlow colors and 12 percent atmosphere mixing", () => {
  assert.equal(effectCatalog.atmosphereMix, 0.12);
  assert.equal(effectCatalog.semantics.working.hex, "#304FFE");
  assert.equal(effectCatalog.semantics.completeUnread.hex, "#00FF4C");
  assert.equal(effectCatalog.semantics.requiresInput.hex, "#FF6D00");
  assert.equal(effectCatalog.semantics.error.hex, "#FF0033");
  assert.equal(semanticEffect(7, "completeUnread", true).effect, EffectPrimitive.Breath);
  assert.equal(semanticEffect(7, "unassigned", true).value, 0);
});
