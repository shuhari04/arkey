#!/usr/bin/env node
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline/promises";
import { stdin, stdout } from "node:process";
import { HID, devices } from "node-hid";
import {
  codexMicroTargetNames as targetNames,
  deriveCodexMicroMappings,
  resolveCodexMicroTargetName,
} from "./codex-micro-lab-bindings.mjs";

const VID = 0x303a;
const PID = 0x8360;
const USAGE_PAGE = 0xff00;
const REPORT_ID = 0x07;
const MAGIC = 0xa7;
const VERSION = 1;
const REPORT_SIZE = 64;

const Opcode = {
  hello: 0x01,
  mappings: 0x02,
  capture: 0x03,
  set: 0x04,
  clear: 0x05,
  encoder: 0x06,
  reset: 0x07,
  enterDfu: 0x08,
  captured: 0x13,
  ack: 0x7f,
};

const profiles = [
  JSON.parse(readFileSync(new URL("../profiles/keychron-q6-pro-ansi.json", import.meta.url), "utf8")),
  JSON.parse(readFileSync(new URL("../profiles/keychron-v1-max-ansi-knob.json", import.meta.url), "utf8")),
];
let profile = profiles[0];
let controls = new Map(profile.controls.map((control) => [control.id, control]));

function selectProfile(hello) {
  const rows = hello.payload[1];
  const columns = hello.payload[2];
  const match = profiles.find((candidate) => candidate.matrix.rows === rows && candidate.matrix.columns === columns);
  if (!match) throw new Error(`固件返回未知矩阵 ${rows}x${columns}；拒绝猜测键位配置。`);
  profile = match;
  controls = new Map(profile.controls.map((control) => [control.id, control]));
  return profile;
}

function targetIndex(name) {
  const canonicalName = resolveCodexMicroTargetName(name);
  const index = targetNames.indexOf(canonicalName);
  if (index < 0) throw new Error(`未知目标 ${name}；可用值：${targetNames.join(", ")}`);
  return index;
}

function controlForPosition(row, column) {
  return profile.controls.find((control) => control.matrix?.row === row && control.matrix?.column === column);
}

function findDevice() {
  const matches = devices().filter((device) =>
    device.path &&
    device.vendorId === VID &&
    device.productId === PID &&
    device.usagePage === USAGE_PAGE
  );
  if (!matches.length) {
    throw new Error("未找到 Arkey Codex Micro Lab 设备（303A:8360 / usage page FF00）。请确认已刷入实验固件并使用 USB 连接。");
  }
  return matches[0];
}

function openDevice() {
  const descriptor = findDevice();
  return { descriptor, handle: new HID(descriptor.path, { nonExclusive: true }) };
}

let sequence = 0;

function encode(opcode, payload = []) {
  if (payload.length > REPORT_SIZE - 6) {
    throw new Error(`配置 payload 过长：${payload.length} bytes（最大 ${REPORT_SIZE - 6}）`);
  }
  const report = new Uint8Array(REPORT_SIZE);
  report[0] = REPORT_ID;
  report[1] = MAGIC;
  report[2] = VERSION;
  report[3] = opcode;
  report[4] = sequence++ & 0xff;
  report[5] = payload.length;
  report.set(payload, 6);
  return report;
}

function decode(input) {
  let bytes = Uint8Array.from(input);
  if (bytes.length === REPORT_SIZE - 1 && bytes[0] === MAGIC) {
    bytes = Uint8Array.from([REPORT_ID, ...bytes]);
  } else if (bytes.length === REPORT_SIZE && bytes[0] === 0 && bytes[1] === MAGIC) {
    bytes = Uint8Array.from([REPORT_ID, ...bytes.slice(1)]);
  }
  if (bytes.length !== REPORT_SIZE || bytes[0] !== REPORT_ID || bytes[1] !== MAGIC || bytes[2] !== VERSION) return undefined;
  const length = bytes[5];
  if (length > REPORT_SIZE - 6 || 6 + length > bytes.length) return undefined;
  return { opcode: bytes[3], sequence: bytes[4], payload: bytes.slice(6, 6 + length) };
}

function waitFor(handle, predicate, timeoutMs = 2000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const report = decode(handle.readTimeout(Math.min(250, deadline - Date.now())));
    if (report && predicate(report)) return report;
  }
  throw new Error("等待固件响应超时");
}

function request(handle, opcode, payload = [], expectedOpcode = opcode) {
  const report = encode(opcode, payload);
  const requestSequence = report[4];
  handle.write(Array.from(report));
  return waitFor(handle, (candidate) =>
    candidate.opcode === expectedOpcode &&
    (candidate.sequence === requestSequence || expectedOpcode === Opcode.captured)
  );
}

function assertAck(report, expectedOpcode) {
  if (report.opcode !== Opcode.ack || report.payload[0] !== expectedOpcode || report.payload[1] !== 0) {
    throw new Error(`固件拒绝请求：opcode=${expectedOpcode} status=${report.payload[1] ?? "missing"}`);
  }
}

function getMappings(handle) {
  const report = request(handle, Opcode.mappings);
  const count = report.payload[0];
  if (!Number.isInteger(count) || count > targetNames.length || report.payload.length !== 2 + count * 3) {
    throw new Error("固件返回了无效的映射 payload");
  }
  const encoderEnabled = report.payload[1] !== 0;
  const mappings = [];
  for (let index = 0; index < count; index += 1) {
    const offset = 2 + index * 3;
    mappings.push({ target: report.payload[offset], row: report.payload[offset + 1], column: report.payload[offset + 2] });
  }
  return { encoderEnabled, mappings };
}

function printMappings(state) {
  console.log(`旋钮旋转：${state.encoderEnabled ? "已映射到 Codex Micro encoder" : "保持原键盘功能"}`);
  for (const mapping of state.mappings) {
    const target = targetNames[mapping.target] ?? `target-${mapping.target}`;
    if (mapping.row === 0xff || mapping.column === 0xff) {
      console.log(`${target.padEnd(15)} 未分配`);
      continue;
    }
    const control = controlForPosition(mapping.row, mapping.column);
    console.log(`${target.padEnd(15)} ${control?.label ?? control?.id ?? `r${mapping.row}c${mapping.column}`} (${mapping.row},${mapping.column})`);
  }
}

function captureTarget(handle, name, timeoutMs = 30_000) {
  const target = targetIndex(name);
  const ack = request(handle, Opcode.capture, [target], Opcode.ack);
  assertAck(ack, Opcode.capture);
  console.log(`请在 30 秒内按下要映射为 ${name} 的实体键…`);
  const captured = waitFor(handle, (report) => report.opcode === Opcode.captured && report.payload[0] === target, timeoutMs);
  const row = captured.payload[1];
  const column = captured.payload[2];
  const control = controlForPosition(row, column);
  console.log(`已映射：${name} → ${control?.label ?? control?.id ?? `r${row}c${column}`}`);
}

async function configure(handle) {
  const rl = createInterface({ input: stdin, output: stdout });
  try {
    console.log("逐项配置 Codex Micro 虚拟控制。输入 s 跳过，q 结束并保留已完成映射。\n");
    for (const name of targetNames) {
      const answer = (await rl.question(`${name}: 回车后捕获实体键 [s 跳过 / q 结束] `)).trim().toLowerCase();
      if (answer === "q") break;
      if (answer === "s") continue;
      captureTarget(handle, name);
    }
  } finally {
    rl.close();
  }
  printMappings(getMappings(handle));
}

function readJson(path) {
  return JSON.parse(readFileSync(path, "utf8"));
}

function setTarget(handle, assignment) {
  const ack = request(
    handle,
    Opcode.set,
    [assignment.targetIndex, assignment.row, assignment.column],
    Opcode.ack,
  );
  assertAck(ack, Opcode.set);
}

function syncArkey(handle, merge) {
  const runtimeDirectory = process.env.ARKEY_RUNTIME_DIR ?? join(homedir(), ".arkey");
  const bindingsPath = join(runtimeDirectory, "bindings-v1.json");
  const tasksPath = join(runtimeDirectory, "appserver-tasks-v1.json");
  const result = deriveCodexMicroMappings(readJson(bindingsPath), readJson(tasksPath), profile);

  if (!merge) {
    for (let target = 0; target < targetNames.length; target += 1) {
      const ack = request(handle, Opcode.clear, [target], Opcode.ack);
      assertAck(ack, Opcode.clear);
    }
  }
  for (const assignment of result.assignments) setTarget(handle, assignment);

  if (!merge || result.encoderEnabled) {
    const ack = request(handle, Opcode.encoder, [result.encoderEnabled ? 1 : 0], Opcode.ack);
    assertAck(ack, Opcode.encoder);
  }

  console.log(`已从 ${bindingsPath} 同步 ${result.assignments.length} 个自由键位映射。`);
  for (const assignment of result.assignments) {
    const control = controls.get(assignment.controlId);
    console.log(`${assignment.target.padEnd(15)} ← ${control?.label ?? assignment.controlId} (${assignment.actionId})`);
  }
  if (result.skipped.length) {
    console.log(`跳过 ${result.skipped.length} 个无原生对应项：`);
    for (const item of result.skipped) {
      console.log(`- ${item.binding.actionId} / ${item.binding.controlId}: ${item.reason}`);
    }
  }
  printMappings(getMappings(handle));
}

function usage() {
  console.log(`用法：
  node scripts/codex-micro-lab-config.mjs status
  node scripts/codex-micro-lab-config.mjs configure
  node scripts/codex-micro-lab-config.mjs sync-arkey [--merge]
  node scripts/codex-micro-lab-config.mjs capture <${targetNames.join("|")}>
  node scripts/codex-micro-lab-config.mjs map <target> <profile-control-id>
    target 可使用 voice-ptt 或 ptt，二者均指向原生 ACT10（默认 PTT）
  node scripts/codex-micro-lab-config.mjs clear <target>
  node scripts/codex-micro-lab-config.mjs encoder <on|off>
  node scripts/codex-micro-lab-config.mjs reset
  node scripts/codex-micro-lab-config.mjs enter-dfu --confirm-dfu`);
}

async function main() {
  const command = process.argv[2] ?? "status";
  if (command === "help" || command === "--help" || command === "-h") {
    usage();
    return;
  }

  const { descriptor, handle } = openDevice();
  try {
    const hello = request(handle, Opcode.hello);
    const selectedProfile = selectProfile(hello);
    if (command === "status") {
      console.log(`设备：${descriptor.product ?? "Arkey Codex Micro Lab"}`);
      console.log(`固件能力：${hello.payload[0]} targets / ${hello.payload[1]}x${hello.payload[2]} matrix / ${hello.payload[4]} LEDs / ${selectedProfile.name}`);
      printMappings(getMappings(handle));
    } else if (command === "configure") {
      await configure(handle);
    } else if (command === "sync-arkey") {
      syncArkey(handle, process.argv.includes("--merge"));
    } else if (command === "capture") {
      captureTarget(handle, process.argv[3]);
    } else if (command === "map") {
      const target = targetIndex(process.argv[3]);
      const control = controls.get(process.argv[4]);
      if (!control?.matrix) throw new Error(`control ${process.argv[4]} 没有可用矩阵坐标`);
      const ack = request(handle, Opcode.set, [target, control.matrix.row, control.matrix.column], Opcode.ack);
      assertAck(ack, Opcode.set);
      printMappings(getMappings(handle));
    } else if (command === "clear") {
      const target = targetIndex(process.argv[3]);
      const ack = request(handle, Opcode.clear, [target], Opcode.ack);
      assertAck(ack, Opcode.clear);
      printMappings(getMappings(handle));
    } else if (command === "encoder") {
      const enabled = process.argv[3] === "on";
      if (!enabled && process.argv[3] !== "off") throw new Error("encoder 参数必须为 on 或 off");
      const ack = request(handle, Opcode.encoder, [enabled ? 1 : 0], Opcode.ack);
      assertAck(ack, Opcode.encoder);
      printMappings(getMappings(handle));
    } else if (command === "reset") {
      const ack = request(handle, Opcode.reset, [], Opcode.ack);
      assertAck(ack, Opcode.reset);
      printMappings(getMappings(handle));
    } else if (command === "enter-dfu") {
      if (!process.argv.includes("--confirm-dfu")) throw new Error("软件进入 DFU 会断开键盘；请追加 --confirm-dfu。它不会自动刷写固件。");
      const ack = request(handle, Opcode.enterDfu, [0x44, 0x46, 0x55, 0x21], Opcode.ack);
      assertAck(ack, Opcode.enterDfu);
      console.log("键盘已确认 DFU 请求；请重新检测 0483:DF11，再手动选择固件写入。");
    } else {
      usage();
      process.exitCode = 2;
    }
  } finally {
    handle.close();
  }
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
});
