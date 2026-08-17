import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const firmware = readFileSync(new URL("../../firmware/qmk/codex_micro_lab.c", import.meta.url), "utf8");
const header = readFileSync(new URL("../../firmware/qmk/codex_micro_lab.h", import.meta.url), "utf8");
const keyboardPatch = readFileSync(new URL("../../firmware/codex-micro-lab-q6-pro.patch", import.meta.url), "utf8");
const hidPatch = readFileSync(new URL("../../firmware/codex-micro-lab-qmk-hid.patch", import.meta.url), "utf8");
const encoderPatch = readFileSync(new URL("../../firmware/codex-micro-lab-qmk-encoder.patch", import.meta.url), "utf8");
const v1Patch = readFileSync(new URL("../../firmware/codex-micro-lab-v1-max.patch", import.meta.url), "utf8");
const v1HidPatch = readFileSync(new URL("../../firmware/codex-micro-lab-v1-max-hid.patch", import.meta.url), "utf8");
const configurator = readFileSync(new URL("../../scripts/codex-micro-lab-config.mjs", import.meta.url), "utf8");
const bindingMapper = readFileSync(new URL("../../scripts/codex-micro-lab-bindings.mjs", import.meta.url), "utf8");
const builder = readFileSync(new URL("../../scripts/build-codex-micro-lab-q6-pro.sh", import.meta.url), "utf8");
const v1Builder = readFileSync(new URL("../../scripts/build-codex-micro-lab-v1-max.sh", import.meta.url), "utf8");
const labDocumentation = readFileSync(new URL("../../docs/CODEX_MICRO_LAB.md", import.meta.url), "utf8");

test("Codex Micro lab uses the observed USB identity and isolated 64-byte report framing", () => {
  assert.match(keyboardPatch, /"vid": "0x303A"/);
  assert.match(keyboardPatch, /"pid": "0x8360"/);
  assert.match(keyboardPatch, /"manufacturer": "Work Louder"/);
  assert.match(keyboardPatch, /"device_version": "1\.0\.0"/);
  assert.match(hidPatch, /RAW_USAGE_PAGE 0xFF00/);
  assert.match(hidPatch, /RAW_EPSIZE 64/);
  assert.match(hidPatch, /HID_RI_REPORT_ID\(8, 0x06\)/);
  assert.match(hidPatch, /HID_RI_REPORT_ID\(8, 0x07\)/);
  assert.match(header, /#define CM_REPORT_SIZE 64/);
});

test("all virtual Codex controls are mapped by matrix position instead of fixed F-keys", () => {
  assert.match(header, /#define CM_TARGET_COUNT 17/);
  assert.match(firmware, /cm_mapping_t mappings\[CM_TARGET_COUNT\]/);
  assert.match(firmware, /target_for_position/);
  assert.match(firmware, /assign_mapping\(capture_target, row, col\)/);
  assert.match(firmware, /eeconfig_update_user_datablock/);
  assert.doesNotMatch(firmware, /KC_F(?:[1-9]|1[0-2])/);
  for (const target of [
    "agent-1", "agent-6", "command-1", "command-6", "encoder-press",
    "joystick-up", "joystick-right", "joystick-down", "joystick-left",
  ]) assert.match(bindingMapper, new RegExp(`"${target}"`));
  assert.match(configurator, /sync-arkey/);
});

test("Arkey configuration framing rejects oversized and malformed payloads", () => {
  assert.match(configurator, /payload\.length > REPORT_SIZE - 6/);
  assert.match(configurator, /bytes\.length !== REPORT_SIZE/);
  assert.match(configurator, /length > REPORT_SIZE - 6 \|\| 6 \+ length > bytes\.length/);
  assert.match(configurator, /count > targetNames\.length \|\| report\.payload\.length !== 2 \+ count \* 3/);
  assert.match(firmware, /payload_length > CM_REPORT_SIZE - 6/);
});

test("fresh installs and resets use the complete Q6 Pro native Micro mapping", () => {
  const defaults = firmware.match(/static const cm_mapping_t default_mappings\[CM_TARGET_COUNT\] = \{([\s\S]*?)\n\};/)?.[1] ?? "";
  const expected = [
    [0, 4, 17], [1, 4, 18], [2, 4, 19],
    [3, 3, 17], [4, 3, 18], [5, 3, 19],
    [6, 2, 20], [7, 0, 17], [8, 0, 20],
    [9, 0, 18], [10, 5, 18], [11, 4, 20],
    [12, 0, 13],
  ];
  for (const [target, row, column] of expected) {
    assert.match(defaults, new RegExp(`\\[${target}\\] = \\{${row}, ${column}\\}`));
  }
  for (const target of [13, 14, 15, 16]) {
    assert.match(defaults, new RegExp(`\\[${target}\\] = \\{CM_MAPPING_UNASSIGNED, CM_MAPPING_UNASSIGNED\\}`));
  }
  assert.match(firmware, /config_defaults\(void\)[\s\S]*memcpy\(config\.mappings, default_mappings, sizeof\(config\.mappings\)\)/);
  assert.match(firmware, /case CM_CONFIG_RESET:[\s\S]*config_defaults\(\);[\s\S]*save_config\(\);/);
});

test("V1 Max Lab has a separate safe default map and full report-ID configuration path", () => {
  const defaults = firmware.match(/static const cm_mapping_t v1_default_mappings\[CM_TARGET_COUNT\] = \{([\s\S]*?)\n\};/)?.[1] ?? "";
  for (const [target, row, column] of [[0, 1, 15], [1, 2, 15], [10, 3, 15], [12, 0, 15]]) {
    assert.match(defaults, new RegExp(`\\[${target}\\] = \\{${row}, ${column}\\}`));
  }
  assert.match(firmware, /#\s*define CM_LAB_BUILD_VERSION "0\.1\.9-v1max"/);
  assert.match(firmware, /#define CM_CONFIG_ENTER_DFU 0x08/);
  assert.match(firmware, /payload\[0\] != 'D'[\s\S]*payload\[3\] != '!'/);
  assert.match(firmware, /dfu_pending = true;[\s\S]*dfu_pending_at = timer_read32\(\)/);
  assert.match(firmware, /timer_elapsed32\(dfu_pending_at\) >= 350[\s\S]*reset_keyboard\(\)/);
  assert.match(firmware, /Normalize[\s\S]*canonical 07\+A7[\s\S]*observed A7/);
  assert.match(v1Patch, /CODEX_MICRO_V1_MAX/);
  assert.match(v1HidPatch, /RAW_EPSIZE 64/);
  assert.match(v1Builder, /EXPECTED_QMK_COMMIT=bc1bdeb85f39cccd5e503f4d8f472078a8c1472a/);
  assert.match(v1Builder, /--acknowledge-device-identity-test/);
  assert.doesNotMatch(v1Builder, /dfu-util\s+-D|qmk\s+flash/);
});

test("storage v2 is invalidated so Q6 and V1 installs receive their current defaults", () => {
  assert.match(firmware, /#define CM_CONFIG_STORAGE_VERSION 3/);
  assert.match(
    firmware,
    /config\.version != CM_CONFIG_STORAGE_VERSION[\s\S]*config_defaults\(\);[\s\S]*save_config\(\);/,
  );
});

test("mapped task lights follow their assigned physical LEDs", () => {
  assert.match(firmware, /g_led_config\.matrix_co\[mapping\.row\]\[mapping\.col\]/);
  assert.match(firmware, /set_mapped_color\(slot, &slots\[slot\]/);
  assert.match(firmware, /CM_TARGET_COMMAND_FIRST; target <= CM_TARGET_ENCODER_PRESS/);
});

test("Micro lighting retains current vendor fields and recognizes the complete effect vocabulary", () => {
  for (const [name, value] of [
    ["OFF", 0], ["SOLID", 1], ["SNAKE", 2], ["RAINBOW", 3],
    ["BREATH", 4], ["GRADIENT", 5], ["SHALLOW_BREATH", 6],
  ] as const) assert.match(firmware, new RegExp(`#define CM_EFFECT_${name} ${value}`));

  for (const field of ["color", "brightness", "effect", "speed", "magic", "sync_keys", "sync_ambient", "started_at"]) {
    assert.match(firmware, new RegExp(`\\b${field};`));
  }
  for (const key of ["c", "b", "e", "s", "m", "sk", "sa"]) {
    assert.ok(firmware.includes(String.raw`find_bounded(start, end, "\"${key}\":")`));
  }
  assert.match(firmware, /effect <= CM_EFFECT_LAST \? \(uint8_t\)effect : CM_EFFECT_OFF/);
});

test("Micro renderer keeps transmitted brightness and animation speed semantics", () => {
  assert.match(firmware, /next\.magic = parse_unit_after\(find_bounded\(start, end, "\\\"m\\\":"\)/);
  assert.match(firmware, /if \(light->speed == 0\) return 0/);
  assert.match(firmware, /ticks \* light->speed >> 8/);
  assert.match(firmware, /next\.started_at = timer_read32\(\)/);
  assert.match(firmware, /if \(led_min == 0 \|\| render_time == 0\) render_time = timer_read32\(\)/);
  assert.match(firmware, /CM_EFFECT_RAINBOW[\s\S]*hsv_to_rgb\(hsv\)/);
  assert.match(firmware, /CM_EFFECT_GRADIENT[\s\S]*triangle/);
  assert.match(firmware, /CM_EFFECT_SHALLOW_BREATH\) wave = \(uint8_t\)\(128 \+ wave \/ 2\)/);
  assert.doesNotMatch(firmware, /value = \(uint8_t\)\(\(uint16_t\)value \* 52 \/ 255\)/);
  assert.doesNotMatch(firmware, /uint8_t floor = .*\? 128 : 24/);
});

test("Q6 lighting math covers normalized input, exact RGB, breath floors, and stopped speed", () => {
  assert.match(firmware, /phase < 128 \? \(uint8_t\)\(phase \* 2\) : \(uint8_t\)\(255 - \(phase - 128\) \* 2\)/);
  assert.match(firmware, /ramp \* ramp \* \(765 - 2 \* ramp\) \/ 65025/);
  assert.match(firmware, /\(uint16_t\)red \* value \/ 255/);

  const unitByte = (value: number): number => Math.min(255, Math.floor(value * 255));
  assert.deepEqual([0, 0.1, 0.4, 0.5, 1].map(unitByte), [0, 25, 102, 127, 255]);

  const phaseAt = (elapsedMs: number, speed: number): number => speed === 0
    ? 0
    : (Math.floor(elapsedMs / 8) * speed >> 8) & 0xFF;
  assert.equal(phaseAt(0, unitByte(0.4)), 0);
  assert.equal(phaseAt(60_000, 0), 0);
  assert.notEqual(phaseAt(1_280, unitByte(0.4)), phaseAt(0, unitByte(0.4)));

  const triangle = (phase: number): number => phase < 128 ? phase * 2 : 255 - (phase - 128) * 2;
  const breath = (phase: number): number => {
    const ramp = triangle((phase * 2) & 0xFF);
    return Math.floor(ramp * ramp * (765 - 2 * ramp) / 65025);
  };
  assert.equal(breath(0), 0);
  assert.equal(breath(64), 255);
  assert.equal(128 + Math.floor(breath(0) / 2), 128);
  assert.equal(128 + Math.floor(breath(64) / 2), 255);

  const scalePackedRgb = (color: number, value: number): [number, number, number] => [
    Math.floor(((color >> 16) & 0xFF) * value / 255),
    Math.floor(((color >> 8) & 0xFF) * value / 255),
    Math.floor((color & 0xFF) * value / 255),
  ];
  assert.deepEqual(scalePackedRgb(0x304FFE, 255), [0x30, 0x4F, 0xFE]);
  assert.deepEqual(scalePackedRgb(0x00FF4C, 0), [0, 0, 0]);
});

test("the documented current Desktop baseline uses native colors instead of the App Server catalog", () => {
  for (const [status, color] of [
    ["Working", "#304FFE"], ["Unread", "#00FF4C"], ["Idle", "#FFFFFF"],
    ["Awaiting approval/response", "#FF6D00"], ["Error", "#FF0033"], ["Off", "#000000"],
  ]) {
    assert.ok(labDocumentation.includes(`| ${status} | \`${color}\` |`));
  }
  assert.match(labDocumentation, /selected\/pulsing 槽 breath，speed `0\.4`/);
  assert.match(labDocumentation, /recording 为 `#2E8B57` snake/);
  assert.match(labDocumentation, /不经过 App Server 模式的 `profiles\/effects-v1\.json`/);
});

test("physical controls without RGB LEDs remain bindable", () => {
  assert.match(firmware, /static bool valid_position\(uint8_t row, uint8_t col\) \{\s*\/\/ Some physical controls[\s\S]*?return row < MATRIX_ROWS && col < MATRIX_COLS;/);
  assert.match(firmware, /if \(led == NO_LED \|\| led < led_min \|\| led >= led_max\) return;/);
});

test("firmware expires capture on-device before a later unrelated keypress", () => {
  assert.match(firmware, /#define CM_CAPTURE_TIMEOUT_MS 30000/);
  assert.match(firmware, /capture_started_at = timer_read32\(\)/);
  assert.match(
    firmware,
    /expire_capture_if_needed\(void\)[\s\S]*timer_elapsed32\(capture_started_at\) >= CM_CAPTURE_TIMEOUT_MS[\s\S]*capture_active = false/,
  );
  assert.match(firmware, /handle_matrix_record\(keyrecord_t \*record\)[\s\S]*expire_capture_if_needed\(\)/);
  assert.match(firmware, /codex_micro_lab_task\(void\)[\s\S]*expire_capture_if_needed\(\);[\s\S]*drain_event\(\)/);
});

test("lab build is explicit, reversible, and does not flash automatically", () => {
  assert.match(builder, /--acknowledge-device-identity-test/);
  assert.match(builder, /trap restore_qmk EXIT INT TERM/);
  assert.match(builder, /diff --quiet HEAD --/);
  assert.match(builder, /quantum\/encoder\.h/);
  assert.match(builder, /codex-micro-lab-qmk-encoder\.patch/);
  assert.match(builder, /Refusing to overwrite existing QMK file/);
  assert.match(builder, /This script did not flash the keyboard/);
  assert.doesNotMatch(builder, /dfu-util\s+-D|qmk\s+flash/);
});

test("encoder interception happens before QMK emits the VIA volume mapping", () => {
  assert.match(header, /codex_micro_lab_encoder_preprocess/);
  assert.match(firmware, /bool codex_micro_lab_encoder_preprocess\(uint8_t index, bool clockwise\)/);
  assert.match(firmware, /codex_micro_lab_encoder_preprocess[\s\S]*if \(!using_usb\(\) \|\| !config\.encoder_enabled\) return true/);
  const preprocess = firmware.match(/bool codex_micro_lab_encoder_preprocess[\s\S]*?\n}/)?.[0] ?? "";
  assert.match(preprocess, /config\.encoder_enabled/);
  assert.match(preprocess, /enqueue_event\(CM_EVENT_HID[\s\S]*return false;/);
  assert.match(firmware, /Q6 Pro's[\s\S]*?opposite to the Codex Micro protocol direction/);
  assert.match(firmware, /enqueue_event\(CM_EVENT_HID, CM_TARGET_ENCODER_PRESS, 2, clockwise \? 1 : 0, index\)/);
  assert.doesNotMatch(firmware, /KEYLOC_ENCODER_CW|KEYLOC_ENCODER_CCW/);
  assert.match(keyboardPatch, /encoder_preprocess_kb\(uint8_t index, bool clockwise\)/);
  assert.match(encoderPatch, /encoder_preprocess_kb\(index, ENCODER_COUNTER_CLOCKWISE\)/);
  assert.match(encoderPatch, /encoder_preprocess_kb\(index, ENCODER_CLOCKWISE\)/);
});

test("Q6 keeps encoder rotation while V1 can opt out through the shared protocol", () => {
  const handler = firmware.match(/case CM_CONFIG_ENCODER:[\s\S]*?break;/)?.[0] ?? "";
  assert.match(handler, /#if defined\(CODEX_MICRO_Q6_PRO\)/);
  assert.match(handler, /config\.encoder_enabled = 1/);
  assert.match(handler, /if \(config\.encoder_enabled != 1\)[\s\S]*save_config\(\)/);
  assert.match(handler, /#else[\s\S]*config\.encoder_enabled = payload\[0\] != 0/);
  assert.match(firmware, /#if defined\(CODEX_MICRO_Q6_PRO\)[\s\S]*config\.encoder_enabled != 1[\s\S]*config\.encoder_enabled = 1/);
  assert.match(configurator, /encoder <on\|off>/);
  assert.match(bindingMapper, /let encoderEnabled = false/);
});

test("native Micro PTT uses ACT10 with physical press and release semantics", () => {
  assert.match(firmware, /"ACT06", "ACT07", "ACT08", "ACT09", "ACT10", "ACT12"/);
  assert.match(firmware, /enqueue_event\(CM_EVENT_HID, \(uint8_t\)target, pressed \? 1 : 0, row, col\)/);
  assert.match(firmware, /v\.oai\.rgbcfg/);
  assert.match(firmware, /CM_EFFECT_SNAKE/);
});
