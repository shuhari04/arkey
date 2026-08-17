import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { AckStatus, AgentState, ControlEventKind, decodeBindingMask, decodeSetKeyEffects, EffectPrimitive, encodeAck, Opcode } from "../src/protocol.js";
import { q6ProAnsi, v1MaxAnsiKnob } from "../src/profile.js";
import { ArkeyDaemon, defaultQ6Bindings, defaultV1MaxBindings, mergeStates } from "../src/runtime.js";

test("active agents outrank completion while errors remain visible", () => {
  assert.equal(mergeStates([AgentState.Complete, AgentState.Thinking]), AgentState.Thinking);
  assert.equal(mergeStates([AgentState.Streaming, AgentState.Tool]), AgentState.Tool);
  assert.equal(mergeStates([AgentState.Thinking, AgentState.Error]), AgentState.Error);
});

test("empty state set is idle", () => assert.equal(mergeStates([]), AgentState.Idle));

test("test mode starts a sustained thinking animation", () => {
  const sent: Opcode[] = [];
  const transport = {
    connection: { profile: q6ProAnsi, support: "arkey", product: "Q6 Pro" },
    send(opcode: Opcode) { sent.push(opcode); return true; },
  };
  const daemon = new ArkeyDaemon(transport as never);
  daemon.handle({ type: "test" });
  assert.equal(sent[0], Opcode.SetState);
  assert.ok(sent.includes(Opcode.KeyEvents) === false);
  daemon.handle({ type: "restore" });
});

test("manual preview starts the selected firmware state", () => {
  const sent: Opcode[] = [];
  const transport = {
    connection: { profile: q6ProAnsi, support: "arkey", product: "Q6 Pro" },
    send(opcode: Opcode) { sent.push(opcode); return true; },
  };
  const daemon = new ArkeyDaemon(transport as never);
  daemon.handle({ type: "preview", state: AgentState.Error, durationMs: 250 });
  assert.equal(sent[0], Opcode.SetState);
  daemon.handle({ type: "restore" });
});

test("status retries HID connection after startup races USB enumeration", () => {
  let attempts = 0;
  const transport = {
    connection: undefined as undefined | { profile: typeof q6ProAnsi; support: "arkey"; product: string },
    connect() {
      attempts += 1;
      this.connection = { profile: q6ProAnsi, support: "arkey", product: "Q6 Pro" };
      return this.connection;
    },
    send() { return true; },
  };
  const writes: string[] = [];
  const socket = { write(value: string) { writes.push(value); } };
  const daemon = new ArkeyDaemon(transport as never);
  daemon.handle({ type: "status" }, socket as never);
  assert.equal(attempts, 1);
  assert.match(writes[0], /"support":"arkey"/);
});

class V2Transport extends EventEmitter {
  connection = {
    profile: q6ProAnsi, support: "arkey" as const, product: "Q6 Pro",
    extensionVersion: 2, layoutMatches: true, fullControl: true,
  };
  sent: Array<{ opcode: Opcode; payload: Uint8Array }> = [];
  connect() { return this.connection; }
  send(opcode: Opcode, payload = new Uint8Array()) {
    this.sent.push({ opcode, payload: Uint8Array.from(payload) });
    if (opcode === Opcode.SetBindingMask) {
      const revision = decodeBindingMask(payload).revision;
      queueMicrotask(() => this.emit("packet", {
        opcode: Opcode.Ack, sequence: 1,
        payload: encodeAck({ opcode: Opcode.SetBindingMask, status: 0, revision, epoch: 0, deviceTick: 1 }),
      }));
    }
    return true;
  }
  close() {}
}

class FakeAppServer extends EventEmitter {
  requests: Array<{ method: string; params: unknown }> = [];
  responses: Array<{ id: string | number; result: unknown }> = [];
  account: Record<string, unknown> = { account: { type: "chatgpt" }, requiresOpenaiAuth: true };
  models = [{
    model: "test-model", displayName: "Test Model", isDefault: true,
    supportedReasoningEfforts: [{ reasoningEffort: "low" }, { reasoningEffort: "medium" }],
    serviceTiers: [{ id: "standard" }, { id: "priority" }],
  }];
  failPlanProbe = false;
  async start() { return { initialize: {}, account: {}, models: [] }; }
  async stop() {}
  async request(method: string, params: unknown) {
    this.requests.push({ method, params });
    if (method === "thread/start") return { thread: { id: "thread-1" } };
    if (method === "turn/start") return { turn: { id: "turn-1" } };
    if (method === "thread/fork") return { thread: { id: "thread-2" } };
    if (method === "account/login/start") return { type: "chatgptDeviceCode", loginId: "login-1", verificationUrl: "https://example.test/device", userCode: "ABCD-1234" };
    if (method === "account/read") return this.account;
    if (method === "collaborationMode/list") {
      if (this.failPlanProbe) throw new Error("Method not found");
      return { data: [{ name: "Plan", mode: "plan", model: "test-model", reasoning_effort: "high" }] };
    }
    if (method === "review/start") return { turn: { id: "review-turn" } };
    if (method === "thread/list") return { data: [{ id: "external-thread", name: "External" }] };
    if (method === "thread/resume") return { thread: { id: "external-thread", name: "External" } };
    return {};
  }
  respond(id: string | number, result: unknown) { this.responses.push({ id, result }); }
  respondError() {}
  fastTier() { return "priority"; }
  reasoningEfforts() { return ["low", "medium", "high"]; }
  defaultEffort() { return "medium"; }
}

test("fresh runtime seeds the original numpad-first Q6 layout with local task IDs", async () => {
  const directory = mkdtempSync(join(tmpdir(), "arkey-default-layout-"));
  const daemon = new ArkeyDaemon(new V2Transport() as never, {
    runtimeDirectory: directory,
    appServer: new FakeAppServer() as never,
    now: () => new Date("2026-07-17T00:00:00.000Z"),
  });
  try {
    await daemon.start();
    const stored = JSON.parse(readFileSync(join(directory, "bindings-v1.json"), "utf8")) as {
      revision: number;
      bindings: Array<{ controlId: string; instanceId: string; actionId: string; taskId?: string }>;
    };
    const tasks = JSON.parse(readFileSync(join(directory, "appserver-tasks-v1.json"), "utf8")) as {
      tasks: Array<{ taskId: string; slotIndex: number }>;
    };
    assert.equal(stored.revision, 1);
    assert.deepEqual(
      stored.bindings.map(({ controlId, instanceId, actionId }) => ({ controlId, instanceId, actionId })),
      defaultQ6Bindings.map(({ controlId, instanceId, actionId }) => ({ controlId, instanceId, actionId })),
    );
    assert.equal(stored.bindings.length, 15);
    for (let slotIndex = 0; slotIndex < 6; slotIndex += 1) {
      const task = tasks.tasks.find((candidate) => candidate.slotIndex === slotIndex);
      const binding = stored.bindings.find((candidate) => candidate.instanceId === `task-agent-${slotIndex + 1}`);
      assert.equal(binding?.taskId, task?.taskId, `Agent ${slotIndex + 1} must use the fresh runtime task ID`);
    }
  } finally {
    await daemon.stop();
    rmSync(directory, { recursive: true, force: true });
  }
});

test("fresh V1 Max runtime seeds its dedicated Micro defaults and V1 binding mask", async () => {
  const directory = mkdtempSync(join(tmpdir(), "arkey-v1-default-layout-"));
  const transport = new V2Transport() as unknown as V2Transport & {
    connection: { profile: typeof v1MaxAnsiKnob; support: "arkey"; product: string; extensionVersion: number; layoutMatches: boolean; fullControl: boolean };
  };
  transport.connection = {
    profile: v1MaxAnsiKnob, support: "arkey", product: "Keychron V1 Max", extensionVersion: 2, layoutMatches: true, fullControl: true,
  };
  const daemon = new ArkeyDaemon(transport as never, {
    runtimeDirectory: directory,
    appServer: new FakeAppServer() as never,
    now: () => new Date("2026-08-17T00:00:00.000Z"),
  });
  try {
    await daemon.start();
    const stored = JSON.parse(readFileSync(join(directory, "bindings-v1.json"), "utf8")) as {
      revision: number;
      bindings: Array<{ controlId: string; instanceId: string; actionId: string; profileId: string; layoutHash: string }>;
    };
    assert.deepEqual(
      stored.bindings.map(({ controlId, instanceId, actionId }) => ({ controlId, instanceId, actionId })),
      defaultV1MaxBindings.map(({ controlId, instanceId, actionId }) => ({ controlId, instanceId, actionId })),
    );
    assert.ok(stored.bindings.every((binding) => binding.profileId === v1MaxAnsiKnob.profileId && binding.layoutHash === v1MaxAnsiKnob.layoutHash));
    await daemon.rpc("binding.set", { controlId: v1MaxAnsiKnob.encoder.pressControlId, actionId: "reasoning", replace: true });
    const mask = transport.sent.find((packet) => packet.opcode === Opcode.SetBindingMask);
    assert.ok(mask);
    // The shared v2 protocol always carries a 16-byte matrix mask; V1 uses its
    // 6×16 prefix and leaves the remaining bytes padded for wire compatibility.
    assert.equal(decodeBindingMask(mask.payload).matrixBits.length, 16);
  } finally {
    await daemon.stop();
    rmSync(directory, { recursive: true, force: true });
  }
});

test("runtime preserves an initialized custom binding store", async () => {
  const directory = mkdtempSync(join(tmpdir(), "arkey-existing-layout-"));
  const existing = {
    version: 1,
    revision: 7,
    bindings: [{
      controlId: "r1c1",
      instanceId: "custom-send",
      actionId: "send",
      profileId: q6ProAnsi.profileId,
      layoutHash: q6ProAnsi.layoutHash,
      createdAt: "2026-07-16T00:00:00.000Z",
      updatedAt: "2026-07-16T00:00:00.000Z",
    }],
  };
  writeFileSync(join(directory, "bindings-v1.json"), `${JSON.stringify(existing)}\n`, { mode: 0o600 });
  const daemon = new ArkeyDaemon(new V2Transport() as never, {
    runtimeDirectory: directory,
    appServer: new FakeAppServer() as never,
  });
  try {
    await daemon.start();
    const stored = JSON.parse(readFileSync(join(directory, "bindings-v1.json"), "utf8"));
    assert.deepEqual(stored, existing);
  } finally {
    await daemon.stop();
    rmSync(directory, { recursive: true, force: true });
  }
});

test("runtime preserves a user-cleared binding store", async () => {
  const directory = mkdtempSync(join(tmpdir(), "arkey-cleared-layout-"));
  const cleared = { version: 1, revision: 8, bindings: [] };
  writeFileSync(join(directory, "bindings-v1.json"), `${JSON.stringify(cleared)}\n`, { mode: 0o600 });
  const daemon = new ArkeyDaemon(new V2Transport() as never, {
    runtimeDirectory: directory,
    appServer: new FakeAppServer() as never,
  });
  try {
    await daemon.start();
    const stored = JSON.parse(readFileSync(join(directory, "bindings-v1.json"), "utf8"));
    assert.deepEqual(stored, cleared);
  } finally {
    await daemon.stop();
    rmSync(directory, { recursive: true, force: true });
  }
});

test("v2 knob binding covers rotation plus canonical matrix press, including short and long press", async () => {
  const directory = mkdtempSync(join(tmpdir(), "arkey-runtime-"));
  const transport = new V2Transport();
  const appServer = new FakeAppServer();
  const daemon = new ArkeyDaemon(transport as never, { runtimeDirectory: directory, appServer: appServer as never });
  try {
    const bound = await daemon.rpc("binding.set", { controlId: q6ProAnsi.encoder.pressControlId, actionId: "reasoning", instanceId: "reasoning-1" }) as {
      binding: { controlId: string };
      hardwareSynchronized: boolean;
    };
    assert.equal(bound.hardwareSynchronized, true);
    assert.equal(bound.binding.controlId, q6ProAnsi.encoder.id);
    const maskPacket = transport.sent.find((item) => item.opcode === Opcode.SetBindingMask);
    assert.ok(maskPacket);
    const knobMask = decodeBindingMask(maskPacket.payload);
    assert.equal(knobMask.encoderMask, 0x03);
    const pressBit = q6ProAnsi.controls.find((control) => control.id === q6ProAnsi.encoder.pressControlId)?.matrix.column;
    assert.equal(pressBit, 13);
    assert.notEqual(knobMask.matrixBits[1] & 0x20, 0, "r0c13 knob press must be captured with both rotation directions");
    const knobFeedback = transport.sent
      .filter((packet) => packet.opcode === Opcode.SetKeyEffects)
      .flatMap((packet) => decodeSetKeyEffects(packet.payload).effects);
    assert.equal(knobFeedback.some((effect) => effect.effect === EffectPrimitive.PressFlash), true, "the LED-less knob must flash a nearby lit key");

    let changes = 0;
    daemon.on("runtime", (event) => { if (event.event === "task.effort.changed") changes += 1; });
    const event = { kind: ControlEventKind.EncoderClockwise, row: 0, column: 0, pressed: true, eventSequence: 1, deviceTick: 1, token: 0, flags: 0 };
    transport.emit("control", event);
    transport.emit("control", { ...event, pressed: false, eventSequence: 2 });
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(changes, 1);

    let effortConfirmations = 0;
    let longPressForegroundRequests = 0;
    daemon.on("runtime", (runtimeEvent) => {
      if (runtimeEvent.event === "task.effort.confirmed") effortConfirmations += 1;
      if (runtimeEvent.event === "app.foreground.requested" &&
          (runtimeEvent.data as { reason?: string }).reason === "reasoning-long-press") {
        longPressForegroundRequests += 1;
      }
    });
    const knobPress = {
      kind: ControlEventKind.Key,
      row: 0,
      column: 13,
      pressed: true,
      eventSequence: 3,
      deviceTick: 100,
      token: 0,
      flags: 0,
    };
    transport.emit("control", knobPress);
    transport.emit("control", { ...knobPress, pressed: false, eventSequence: 4, deviceTick: 350 });
    assert.equal(effortConfirmations, 1);
    assert.equal(longPressForegroundRequests, 0);

    transport.emit("control", { ...knobPress, eventSequence: 5, deviceTick: 1000 });
    await new Promise((resolve) => setTimeout(resolve, 520));
    assert.equal(longPressForegroundRequests, 1, "the host must fire while the knob remains held for 500 ms");
    transport.emit("control", { ...knobPress, pressed: false, eventSequence: 6, deviceTick: 1520 });
    assert.equal(effortConfirmations, 1, "long press must not also confirm effort");
    assert.equal(longPressForegroundRequests, 1, "release must not duplicate the long-press action");

    await daemon.rpc("binding.set", { controlId: "r0c1", actionId: "ptt", instanceId: "ptt-1" });
    const voicePhases: string[] = [];
    daemon.on("runtime", (runtimeEvent) => {
      if (runtimeEvent.event === "voice.control") voicePhases.push((runtimeEvent.data as { phase: string }).phase);
    });
    const ptt = { kind: ControlEventKind.Key, row: 0, column: 1, pressed: true, eventSequence: 7, deviceTick: 1600, token: 0, flags: 0 };
    transport.emit("control", ptt);
    transport.emit("control", { ...ptt, pressed: false, eventSequence: 8, deviceTick: 1610 });
    assert.deepEqual(voicePhases, ["press", "release"]);

    const taskId = (await daemon.rpc("task.list") as Array<{ taskId: string }>)[0].taskId;
    await daemon.rpc("binding.set", { controlId: "r0c2", actionId: "task_agent", taskId, instanceId: "agent-key-1" });
    let foregroundRequests = 0;
    daemon.on("runtime", (runtimeEvent) => { if (runtimeEvent.event === "app.foreground.requested") foregroundRequests += 1; });
    const agentKey = { kind: ControlEventKind.Key, row: 0, column: 2, pressed: true, eventSequence: 9, deviceTick: 1700, token: 0, flags: 0 };
    transport.emit("control", agentKey);
    transport.emit("control", { ...agentKey, pressed: false, eventSequence: 10 });
    transport.emit("control", { ...agentKey, eventSequence: 11, deviceTick: 1710 });
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(foregroundRequests, 1);
  } finally {
    await daemon.stop();
    rmSync(directory, { recursive: true, force: true });
  }
});

test("heartbeat NotArmed re-sends the binding mask before restoring overlays, while Bluetooth stays fail-open", async () => {
  const directory = mkdtempSync(join(tmpdir(), "arkey-rearm-"));
  const transport = new V2Transport();
  const daemon = new ArkeyDaemon(transport as never, {
    runtimeDirectory: directory,
    appServer: new FakeAppServer() as never,
  });
  try {
    await daemon.rpc("binding.set", { controlId: "r0c2", actionId: "send", instanceId: "send-1" });
    transport.sent.length = 0;
    const runtimeEvents: string[] = [];
    daemon.on("runtime", (event) => runtimeEvents.push(event.event));

    transport.emit("packet", {
      opcode: Opcode.Ack,
      sequence: 20,
      payload: encodeAck({
        opcode: Opcode.Heartbeat,
        status: AckStatus.NotArmed,
        revision: 0,
        epoch: 0,
        deviceTick: 4000,
      }),
    });
    await new Promise((resolve) => setImmediate(resolve));
    await new Promise((resolve) => setImmediate(resolve));
    const rearmMask = transport.sent.find((item) => item.opcode === Opcode.SetBindingMask);
    assert.ok(rearmMask, "watchdog restore must cause the host to resend SetBindingMask");
    const maskIndex = transport.sent.indexOf(rearmMask);
    const atmosphereIndex = transport.sent.findIndex((item) => item.opcode === Opcode.SetState);
    const overlayIndex = transport.sent.findIndex((item) => item.opcode === Opcode.SetKeyEffects);
    assert.ok(atmosphereIndex > maskIndex, "global atmosphere must only be restored after the binding ACK");
    assert.ok(overlayIndex > maskIndex, "steady overlays must only be restored after the binding ACK");
    assert.ok(runtimeEvents.includes("device.control.rearmed"));

    transport.sent.length = 0;
    transport.emit("packet", {
      opcode: Opcode.Ack,
      sequence: 21,
      payload: encodeAck({
        opcode: Opcode.Heartbeat,
        status: AckStatus.NotUsb,
        revision: 0,
        epoch: 0,
        deviceTick: 5000,
      }),
    });
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(transport.sent.some((item) => item.opcode === Opcode.SetBindingMask), false, "Bluetooth must remain fail-open");
  } finally {
    await daemon.stop();
    rmSync(directory, { recursive: true, force: true });
  }
});

test("bindings stay pending until the current revision is ACKed by a USB v2 connection", async () => {
  const directory = mkdtempSync(join(tmpdir(), "arkey-binding-ack-"));
  const transport = new V2Transport();
  transport.connection.fullControl = false;
  const daemon = new ArkeyDaemon(transport as never, {
    runtimeDirectory: directory,
    appServer: new FakeAppServer() as never,
  });
  try {
    const events: string[] = [];
    daemon.on("runtime", (event) => events.push(event.event));
    const result = await daemon.rpc("binding.set", {
      controlId: "r0c2", actionId: "send", instanceId: "pending-send",
    }) as { binding: { active: boolean; pending: boolean }; hardwareAck: boolean };
    assert.deepEqual({ active: result.binding.active, pending: result.binding.pending, hardwareAck: result.hardwareAck }, {
      active: false, pending: true, hardwareAck: false,
    });
    const pending = await daemon.rpc("binding.list") as {
      hardwareAck: boolean;
      bindings: Array<{ active: boolean; pending: boolean }>;
    };
    assert.equal(pending.hardwareAck, false);
    assert.deepEqual(pending.bindings.map((binding) => [binding.active, binding.pending]), [[false, true]]);

    transport.connection.fullControl = true;
    transport.emit("packet", {
      opcode: Opcode.Ack,
      sequence: 60,
      payload: encodeAck({
        opcode: Opcode.Heartbeat,
        status: AckStatus.NotArmed,
        revision: 0,
        epoch: 0,
        deviceTick: 6000,
      }),
    });
    await new Promise((resolve) => setImmediate(resolve));
    await new Promise((resolve) => setImmediate(resolve));
    const active = await daemon.rpc("binding.list") as {
      hardwareAck: boolean;
      bindings: Array<{ active: boolean; pending: boolean }>;
    };
    assert.equal(active.hardwareAck, true);
    assert.deepEqual(active.bindings.map((binding) => [binding.active, binding.pending]), [[true, false]]);
    const snapshot = (daemon as unknown as { snapshot(): { bindings: typeof active } }).snapshot();
    assert.deepEqual(snapshot.bindings, active, "snapshot and binding.list must expose the same enriched view");
    assert.ok(events.includes("binding.activated"));
  } finally {
    await daemon.stop();
    rmSync(directory, { recursive: true, force: true });
  }
});

test("Plan is capability-gated and applies the discovered preset to the next idle turn", async () => {
  const directory = mkdtempSync(join(tmpdir(), "arkey-plan-"));
  const transport = new V2Transport();
  const appServer = new FakeAppServer();
  const daemon = new ArkeyDaemon(transport as never, { runtimeDirectory: directory, appServer: appServer as never });
  try {
    const task = (await daemon.rpc("task.list") as Array<{ taskId: string }>)[0];
    await assert.rejects(() => daemon.rpc("action.trigger", { actionId: "plan", taskId: task.taskId }), /disabled/);
    appServer.emit("state", { state: "ready" });
    appServer.emit("ready", { account: appServer.account, models: appServer.models });
    await new Promise((resolve) => setImmediate(resolve));
    const actions = await daemon.rpc("actions.list") as Array<{ actionId: string; enabled: boolean }>;
    assert.equal(actions.find((action) => action.actionId === "plan")?.enabled, true);
    await daemon.rpc("binding.set", { controlId: "r0c6", actionId: "plan", instanceId: "plan-key" });
    await daemon.rpc("action.trigger", { actionId: "plan", taskId: task.taskId });
    await daemon.rpc("composer.send", { taskId: task.taskId, text: "design first" });
    const turn = appServer.requests.filter((request) => request.method === "turn/start").at(-1);
    assert.deepEqual((turn?.params as { collaborationMode: unknown }).collaborationMode, {
      mode: "plan",
      settings: { model: "test-model", reasoning_effort: "high", developer_instructions: null },
    });

    appServer.emit("state", { state: "restarting" });
    await assert.rejects(() => daemon.rpc("action.trigger", { actionId: "plan", taskId: task.taskId }), /disabled/);
    appServer.failPlanProbe = true;
    appServer.emit("state", { state: "ready" });
    appServer.emit("ready", { account: appServer.account, models: appServer.models });
    await new Promise((resolve) => setImmediate(resolve));
    const unavailable = await daemon.rpc("actions.list") as Array<{ actionId: string; enabled: boolean }>;
    assert.equal(unavailable.find((action) => action.actionId === "plan")?.enabled, false, "a missing experimental method must not make ready fail");
  } finally {
    await daemon.stop();
    rmSync(directory, { recursive: true, force: true });
  }
});

test("App Server task slice stores no prompt and never blind-approves structured requests", async () => {
  const directory = mkdtempSync(join(tmpdir(), "arkey-appserver-"));
  const transport = new V2Transport();
  transport.connection.fullControl = false;
  const appServer = new FakeAppServer();
  const daemon = new ArkeyDaemon(transport as never, { runtimeDirectory: directory, appServer: appServer as never });
  try {
    const observedEvents: string[] = [];
    const approvalRequests: Array<{ requestId: string | number; params: Record<string, unknown> }> = [];
    daemon.on("runtime", (event) => {
      observedEvents.push(event.event);
      if (event.event === "approval.requested") approvalRequests.push(event.data as { requestId: string | number; params: Record<string, unknown> });
    });
    const tasks = await daemon.rpc("task.list") as Array<{ taskId: string; slotIndex: number }>;
    assert.deepEqual([...tasks].sort((a, b) => a.slotIndex - b.slotIndex).map((task) => task.slotIndex), [0, 1, 2, 3, 4, 5]);
    const taskId = tasks[0].taskId;
    const created = await daemon.rpc("task.create", { title: "Stable seventh slot" }) as { taskId: string; slotIndex: number };
    assert.equal(created.slotIndex, 6);
    const pinned = await daemon.rpc("task.update", { taskId: created.taskId, pinned: true }) as { pinned: boolean };
    assert.equal(pinned.pinned, true);
    await daemon.rpc("settings.update", { taskSort: "custom" });
    const customOrder = (await daemon.rpc("task.list") as Array<{ taskId: string }>).map((task) => task.taskId).reverse();
    await daemon.rpc("task.reorder", { taskIds: customOrder });
    assert.deepEqual((await daemon.rpc("task.list") as Array<{ taskId: string }>).map((task) => task.taskId), customOrder);
    await assert.rejects(() => daemon.rpc("task.reorder", { taskIds: [...customOrder.slice(1), customOrder[1]] }), /unique complete/);
    await assert.rejects(() => daemon.rpc("binding.set", { controlId: "r0c4", actionId: "task_agent", taskId: "client-invented", instanceId: "bad" }), /Unknown Arkey task/);
    await daemon.rpc("task.select", { taskId });
    await daemon.rpc("composer.send", { taskId, text: "private prompt that must not persist" });
    appServer.emit("serverRequest", { id: 81, method: "item/commandExecution/requestApproval", params: { threadId: "thread-1", command: "npm test" } });
    assert.deepEqual(await daemon.rpc("action.trigger", { actionId: "approve", taskId }), { requestId: 81, decision: "accept", pendingResolution: true });
    assert.deepEqual(appServer.responses, [{ id: 81, result: { decision: "accept" } }]);

    appServer.emit("notification", { method: "serverRequest/resolved", params: { threadId: "thread-1", requestId: 81 } });
    appServer.emit("serverRequest", { id: 82, method: "item/permissions/requestApproval", params: { threadId: "thread-1" } });
    assert.deepEqual(await daemon.rpc("action.trigger", { actionId: "approve", taskId }), { focused: true, structured: true, requestId: 82 });
    assert.equal(appServer.responses.length, 1);
    assert.ok(observedEvents.includes("approval.ui.required"));
    assert.ok(observedEvents.includes("task.changed"));
    assert.equal(approvalRequests.find((request) => request.requestId === 82)?.params.threadId, "thread-1");
    await daemon.rpc("approval.respond", { requestId: 82, result: { permissions: {}, scope: "turn" } });
    appServer.emit("notification", { method: "serverRequest/resolved", params: { threadId: "thread-1", requestId: 82 } });

    appServer.emit("serverRequest", { id: 85, method: "item/permissions/requestApproval", params: { threadId: "thread-1", permissions: { fileSystem: ["read"] } } });
    appServer.emit("serverRequest", { id: 86, method: "item/tool/requestUserInput", params: { threadId: "thread-1", questions: [{ id: "choice" }] } });
    assert.equal(approvalRequests.some((request) => request.requestId === 85), true);
    assert.equal(approvalRequests.some((request) => request.requestId === 86), false, "queued structured requests must not overwrite the FIFO head");
    await daemon.rpc("approval.respond", { requestId: 85, result: { permissions: {}, scope: "turn" } });
    appServer.emit("notification", { method: "serverRequest/resolved", params: { threadId: "thread-1", requestId: 85 } });
    assert.equal(approvalRequests.some((request) => request.requestId === 86), true, "resolving the head must publish the next structured request");
    await daemon.rpc("approval.respond", { requestId: 86, result: { answers: { choice: "yes" } } });
    appServer.emit("notification", { method: "serverRequest/resolved", params: { threadId: "thread-1", requestId: 86 } });

    appServer.emit("serverRequest", { id: 83, method: "item/fileChange/requestApproval", params: { threadId: "thread-1" } });
    appServer.emit("serverRequest", { id: 84, method: "item/commandExecution/requestApproval", params: { threadId: "thread-1" } });
    await daemon.rpc("action.trigger", { actionId: "approve", taskId });
    await assert.rejects(() => daemon.rpc("action.trigger", { actionId: "approve", taskId }), /awaiting serverRequest\/resolved/);
    assert.equal(appServer.responses.some((response) => response.id === 84), false, "FIFO must not skip a responded unresolved head");
    appServer.emit("notification", { method: "serverRequest/resolved", params: { threadId: "thread-1", requestId: 83 } });
    await daemon.rpc("action.trigger", { actionId: "decline", taskId });
    assert.deepEqual(appServer.responses.at(-1), { id: 84, result: { decision: "decline" } });
    appServer.emit("state", { state: "offline", error: "restart" });
    await assert.rejects(() => daemon.rpc("action.trigger", { actionId: "approve", taskId }), /no pending approval/);
    assert.ok(observedEvents.includes("approval.invalidated"));
    const stored = readFileSync(join(directory, "appserver-tasks-v1.json"), "utf8");
    assert.doesNotMatch(stored, /private prompt|npm test/);

    assert.deepEqual(await daemon.rpc("account.login.start"), {
      type: "chatgptDeviceCode",
      loginId: "login-1",
      verificationUrl: "https://example.test/device",
      userCode: "ABCD-1234",
    });
    assert.deepEqual(appServer.requests.find((request) => request.method === "account/login/start")?.params, { type: "chatgptDeviceCode" });
    const candidates = await daemon.rpc("task.import") as { candidates: Array<{ id: string }>; explicitSelectionRequired: boolean };
    assert.equal(candidates.explicitSelectionRequired, true);
    assert.deepEqual(candidates.candidates.map((candidate) => candidate.id), ["external-thread"]);
    const imported = await daemon.rpc("task.import", { threadId: "external-thread" }) as { threadId: string };
    assert.equal(imported.threadId, "external-thread");
    const preflight = await daemon.rpc("firmware.preflight") as { dryRun: boolean; flashed: boolean; flashReady: boolean; requiresExplicitConfirmation: boolean };
    assert.deepEqual(preflight, { ...preflight, dryRun: true, flashed: false, flashReady: false, requiresExplicitConfirmation: true });
    const actions = await daemon.rpc("actions.list") as Array<{ actionId: string; enabled: boolean }>;
    assert.equal(actions.find((action) => action.actionId === "git_commit")?.enabled, true);
    assert.equal(actions.find((action) => action.actionId === "scheduled_tasks")?.enabled, false);
    await assert.rejects(() => daemon.rpc("binding.set", {
      controlId: "r0c6", actionId: "plan", instanceId: "disabled-plan",
    }), /Action plan is disabled/);
    await assert.rejects(() => daemon.rpc("binding.instance.create", {
      actionId: "scheduled_tasks",
    }), /Action scheduled_tasks is disabled/);
  } finally {
    await daemon.stop();
    rmSync(directory, { recursive: true, force: true });
  }
});


test("hardware Send preserves the in-memory composer, capture ACK stays active, and confirmed actions use App Server", async () => {
  const directory = mkdtempSync(join(tmpdir(), "arkey-actions-"));
  const transport = new V2Transport();
  const appServer = new FakeAppServer();
  const daemon = new ArkeyDaemon(transport as never, { runtimeDirectory: directory, appServer: appServer as never });
  try {
    const task = (await daemon.rpc("task.list") as Array<{ taskId: string }>)[0];
    await daemon.rpc("task.select", { taskId: task.taskId });
    await daemon.rpc("binding.set", { controlId: "r0c4", actionId: "send", instanceId: "send-physical" });
    const events: Array<{ event: string; data: unknown }> = [];
    daemon.on("runtime", (event) => events.push({ event: event.event, data: event.data }));

    const sendKey = { kind: ControlEventKind.Key, row: 0, column: 4, pressed: true, eventSequence: 100, deviceTick: 1000, token: 0, flags: 0 };
    transport.emit("control", sendKey);
    transport.emit("control", { ...sendKey, pressed: false, eventSequence: 101 });
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(events.filter((event) => event.event === "composer.send.requested").length, 1);
    assert.equal(events.some((event) => event.event === "action.error"), false);

    const staleCaptureSend = { ...sendKey, eventSequence: 110, token: 54, flags: 1 };
    transport.emit("control", staleCaptureSend);
    transport.emit("control", { ...staleCaptureSend, pressed: false, eventSequence: 111 });
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(events.filter((event) => event.event === "composer.send.requested").length, 1);
    assert.equal(events.filter((event) => event.event === "binding.capture.ignored").length, 2);

    await daemon.rpc("binding.capture.start", { token: 55, timeoutMs: 5000 });
    transport.emit("packet", {
      opcode: Opcode.Ack,
      sequence: 50,
      payload: encodeAck({ opcode: Opcode.SetCaptureMode, status: AckStatus.Ok, revision: 0, epoch: 0, deviceTick: 1100 }),
    });
    assert.equal(events.some((event) => event.event === "binding.capture.stopped"), false);
    transport.emit("control", { kind: ControlEventKind.Key, row: 0, column: 5, pressed: true, eventSequence: 102, deviceTick: 1200, token: 55, flags: 1 });
    assert.equal(events.some((event) => event.event === "binding.capture.captured"), true);
    await assert.rejects(
      () => daemon.rpc("binding.capture.start", { token: 56, timeoutMs: 5000 }),
      /Release the previously captured control/,
    );
    transport.emit("control", { kind: ControlEventKind.Key, row: 0, column: 5, pressed: false, eventSequence: 103, deviceTick: 1250, token: 55, flags: 1 });
    assert.equal(events.some((event) => event.event === "binding.capture.released"), true);
    assert.deepEqual(await daemon.rpc("binding.capture.start", { token: 56, timeoutMs: 5000 }), {
      token: 56, timeoutMs: 5000, hardware: true,
    });
    await daemon.rpc("binding.capture.stop");

    appServer.emit("state", { state: "ready" });
    const writes: string[] = [];
    daemon.handle({ type: "status" }, { write: (value: string) => writes.push(value) } as never);
    const status = JSON.parse(writes[0]) as {
      authenticated: boolean;
      models: unknown[];
      capabilities: { profileV2: boolean; voiceStates: string[] };
    };
    assert.equal(status.authenticated, true);
    assert.equal(status.models.length, 1);
    assert.equal(status.capabilities.profileV2, true);
    assert.ok(status.capabilities.voiceStates.includes("recording"));

    appServer.emit("notification", { method: "account/login/completed", params: { loginId: "failed", success: false, error: "denied" } });
    assert.equal(events.some((event) => event.event === "account.login.failed"), true);
    appServer.emit("notification", { method: "account/login/completed", params: { loginId: "ok", success: true, error: null } });
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(events.some((event) => event.event === "account.changed"), true);

    await daemon.rpc("composer.send", { taskId: task.taskId, text: "assign thread" });
    appServer.emit("notification", { method: "turn/completed", params: { threadId: "thread-1", turn: { id: "turn-1", status: "completed" } } });
    const imagePath = join(directory, "reference.png");
    const textPath = join(directory, "not-an-image.txt");
    writeFileSync(imagePath, Uint8Array.from([0x89, 0x50, 0x4e, 0x47]));
    writeFileSync(textPath, "not an image");
    const requestCount = appServer.requests.length;
    await assert.rejects(() => daemon.rpc("composer.send", {
      taskId: task.taskId, text: "keep this composer", attachments: [textPath],
    }), /only accepts absolute local image paths/);
    assert.equal(appServer.requests.length, requestCount, "invalid attachments must not start or steer a turn");
    await daemon.rpc("composer.send", { taskId: task.taskId, text: "inspect image", attachments: [imagePath] });
    const imageTurn = appServer.requests.filter((request) => request.method === "turn/start").at(-1);
    assert.deepEqual((imageTurn?.params as { input: unknown[] }).input, [
      { type: "text", text: "inspect image" },
      { type: "localImage", path: realpathSync(imagePath) },
    ]);
    appServer.emit("notification", { method: "turn/completed", params: { threadId: "thread-1", turn: { id: "turn-1", status: "completed" } } });
    const beforeReview = appServer.requests.filter((request) => request.method === "review/start").length;
    assert.deepEqual(await daemon.rpc("action.trigger", { actionId: "review", taskId: task.taskId, source: "hardware" }), {
      focused: true, confirmationRequired: true,
    });
    assert.equal(appServer.requests.filter((request) => request.method === "review/start").length, beforeReview);
    await daemon.rpc("action.trigger", { actionId: "review", taskId: task.taskId, confirmed: true, reviewTarget: { type: "uncommittedChanges" } });
    assert.equal(appServer.requests.some((request) => request.method === "review/start"), true);

    assert.deepEqual(await daemon.rpc("action.trigger", { actionId: "skill", taskId: task.taskId, source: "hardware" }), {
      focused: true, confirmationRequired: true,
    });
    await assert.rejects(() => daemon.rpc("action.trigger", {
      actionId: "skill", taskId: task.taskId, confirmed: true, skillInput: "openai-docs",
    }), /absolute path/);
    await assert.rejects(() => daemon.rpc("action.trigger", {
      actionId: "skill", taskId: task.taskId, confirmed: true,
      skillInput: { name: "missing", path: "/tmp/missing-skill/SKILL.md" },
    }), /real readable SKILL\.md/);
    const skillDirectory = join(directory, "test-skill");
    const skillPath = join(skillDirectory, "SKILL.md");
    mkdirSync(skillDirectory);
    writeFileSync(skillPath, "# Test Skill\n");
    await daemon.rpc("action.trigger", {
      actionId: "skill", taskId: task.taskId, confirmed: true,
      skillInput: { name: "test-skill", path: skillPath },
    });
    const skillTurn = appServer.requests.filter((request) => request.method === "turn/start").at(-1);
    assert.deepEqual((skillTurn?.params as { input: unknown[] }).input, [{
      type: "skill", name: "test-skill", path: realpathSync(skillPath),
    }]);
    assert.doesNotMatch(readFileSync(join(directory, "appserver-tasks-v1.json"), "utf8"), /reference\.png|inspect image/);
  } finally {
    await daemon.stop();
    rmSync(directory, { recursive: true, force: true });
  }
});

test("voice, entry transitions, binding feedback, and preview epoch share the host lighting contract", async () => {
  const directory = mkdtempSync(join(tmpdir(), "arkey-lighting-"));
  const transport = new V2Transport();
  const appServer = new FakeAppServer();
  const daemon = new ArkeyDaemon(transport as never, { runtimeDirectory: directory, appServer: appServer as never });
  try {
    const task = (await daemon.rpc("task.list") as Array<{ taskId: string }>)[0];
    const runtimeEvents: Array<{ event: string; data: unknown }> = [];
    daemon.on("runtime", (event) => runtimeEvents.push({ event: event.event, data: event.data }));
    await daemon.rpc("binding.set", { controlId: "r0c1", actionId: "ptt", instanceId: "ptt-light" });
    await daemon.rpc("binding.set", { controlId: "r0c2", actionId: "send", instanceId: "send-light" });
    await daemon.rpc("binding.set", { controlId: "r0c3", actionId: "task_agent", taskId: task.taskId, instanceId: "task-light" });
    assert.equal(runtimeEvents.filter((event) => event.event === "lighting.binding.transient").length, 3);
    await new Promise((resolve) => setTimeout(resolve, 610));

    const ledFor = (controlId: string) => q6ProAnsi.controls.find((control) => control.id === controlId)!.ledIndex!;
    const currentEffects = () => transport.sent
      .filter((packet) => packet.opcode === Opcode.SetKeyEffects)
      .flatMap((packet) => decodeSetKeyEffects(packet.payload).effects);

    transport.sent.length = 0;
    await daemon.rpc("voice.state", { state: "recording" });
    assert.deepEqual([...transport.sent.filter((packet) => packet.opcode === Opcode.SetState).at(-1)!.payload], [AgentState.Streaming, 117, 219, 224]);
    assert.equal(currentEffects().find((effect) => effect.led === ledFor("r0c1"))?.hue, 117);
    await new Promise((resolve) => setTimeout(resolve, 80));
    assert.ok(transport.sent.filter((packet) => packet.opcode === Opcode.KeyEvents).length >= 2, "recording must drive a moving global wave");

    transport.sent.length = 0;
    await daemon.rpc("voice.state", { state: "processing" });
    assert.equal(currentEffects().find((effect) => effect.led === ledFor("r0c1"))?.saturation, 0);
    assert.ok(transport.sent.some((packet) => packet.opcode === Opcode.KeyEvents), "processing must start the white moving wave immediately");

    transport.sent.length = 0;
    await daemon.rpc("voice.state", { state: "ready" });
    assert.equal(currentEffects().find((effect) => effect.led === ledFor("r0c2"))?.effect, EffectPrimitive.Solid);

    transport.sent.length = 0;
    await daemon.rpc("voice.state", { state: "error" });
    assert.equal(currentEffects().find((effect) => effect.led === ledFor("r0c1"))?.hue, 250);
    await daemon.rpc("voice.state", { state: "idle" });

    await daemon.rpc("composer.send", { taskId: task.taskId, text: "finish this" });
    appServer.emit("notification", { method: "turn/completed", params: { threadId: "thread-1", turn: { id: "turn-1", status: "completed" } } });
    const entry = [...runtimeEvents].reverse().find((event) => event.event === "lighting.task.entry")?.data as {
      state: string; effect: { effect: EffectPrimitive; durationMs: number };
    };
    assert.equal(entry.state, "completeUnread");
    assert.equal(entry.effect.effect, EffectPrimitive.RiseFade);
    assert.equal(entry.effect.durationMs, 600);

    await daemon.rpc("binding.set", { controlId: "r0c2", actionId: "decline", instanceId: "decline-light", replace: true });
    const replace = [...runtimeEvents].reverse().find((event) => event.event === "lighting.binding.transient")?.data as { kind: string; durationMs: number };
    assert.deepEqual(replace, { ...replace, kind: "replace", durationMs: 600 });

    transport.sent.length = 0;
    const preview = await daemon.rpc("lighting.preview", {
      effects: [{ led: 5, effect: EffectPrimitive.Breath, hue: 20, saturation: 255, value: 200, speed: 90, durationMs: 0 }],
      durationMs: 1000,
      epoch: 4321,
      seed: 77,
    }) as { epoch: number; seed: number };
    assert.deepEqual({ epoch: preview.epoch, seed: preview.seed }, { epoch: 4321, seed: 77 });
    const previewFrame = transport.sent.find((packet) => packet.opcode === Opcode.SetKeyEffects);
    assert.ok(previewFrame);
    const decoded = decodeSetKeyEffects(previewFrame.payload);
    assert.equal(decoded.epoch, 4321);
    assert.equal(decoded.effects[0].phase, 77);
    await daemon.rpc("lighting.stop");
  } finally {
    await daemon.stop();
    rmSync(directory, { recursive: true, force: true });
  }
});
