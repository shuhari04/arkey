import { EventEmitter } from "node:events";
import { accessSync, constants, existsSync, mkdirSync, readFileSync, realpathSync, rmSync, statSync, writeFileSync } from "node:fs";
import { createConnection, createServer, type Server, type Socket } from "node:net";
import { homedir } from "node:os";
import { basename, dirname, extname, isAbsolute, join } from "node:path";
import { createHash, randomUUID } from "node:crypto";
import {
  AckStatus,
  AgentState,
  ControlEventKind,
  DEFAULT_ATMOSPHERE_MIX,
  decodeAck,
  EffectPrimitive,
  encodeBindingMask,
  encodeCaptureMode,
  encodeClearKeyEffects,
  encodeKeyEvents,
  encodeSetKeyEffects,
  encodeState,
  matrixBindingBits,
  Opcode,
  type ControlEvent,
  type EffectSpec,
} from "./protocol.js";
import { controlForMatrix, mapText, profileDirectory, profileDocument, q6ProAnsi, type KeyboardProfile } from "./profile.js";
import { effectCatalog, semanticEffect } from "./effects.js";
import { KeyboardTransport } from "./transport.js";
import {
  defaultActions,
  type ActionDescriptor,
  type ArkeySettings,
  type Binding,
  type RpcRequest,
  type RpcResponse,
  type RuntimeEvent,
  type StoredBindings,
  type StoredTasks,
  type TaskLightState,
  type TaskSlot,
} from "./contracts.js";
import { createStores, isSettings, type ArkeyStores } from "./store.js";
import {
  CodexAppServerClient,
  isBinaryApprovalMethod,
  isStructuredRequestMethod,
  type JsonRpcId,
  type JsonRpcNotification,
  type JsonRpcRequest,
} from "./appserver.js";

export const runtimeDir = join(homedir(), ".arkey");
export const socketPath = join(runtimeDir, "arkey.sock");
export const pidPath = join(runtimeDir, "arkey.pid");

interface DefaultQ6Binding {
  controlId: string;
  instanceId: string;
  actionId: string;
  taskSlotIndex?: number;
}

// The out-of-box Q6 Pro layout mirrors the original AgentGlow setup. Agent and
// high-frequency command keys stay on the numpad, while the four approval /
// continuation controls use F13-F16. Task IDs are resolved from the fresh
// runtime's stable slot indexes instead of copying machine-specific IDs.
export const defaultQ6Bindings: readonly DefaultQ6Binding[] = [
  { controlId: "r4c17", instanceId: "task-agent-1", actionId: "task_agent", taskSlotIndex: 0 },
  { controlId: "r4c18", instanceId: "task-agent-2", actionId: "task_agent", taskSlotIndex: 1 },
  { controlId: "r4c19", instanceId: "task-agent-3", actionId: "task_agent", taskSlotIndex: 2 },
  { controlId: "r3c17", instanceId: "task-agent-4", actionId: "task_agent", taskSlotIndex: 3 },
  { controlId: "r3c18", instanceId: "task-agent-5", actionId: "task_agent", taskSlotIndex: 4 },
  { controlId: "r3c19", instanceId: "task-agent-6", actionId: "task_agent", taskSlotIndex: 5 },
  { controlId: "r0c17", instanceId: "approveCurrent", actionId: "approve" },
  { controlId: "r0c18", instanceId: "continueNewTask", actionId: "continue" },
  { controlId: "r0c19", instanceId: "cancelFocusedControl", actionId: "cancel" },
  { controlId: "r0c20", instanceId: "declineCurrent", actionId: "decline" },
  { controlId: "r1c18", instanceId: "openSkill", actionId: "skill" },
  { controlId: "r2c20", instanceId: "toggleFastMode", actionId: "fast" },
  { controlId: "r5c18", instanceId: "pushToTalk", actionId: "ptt" },
  { controlId: "r4c20", instanceId: "send", actionId: "send" },
  { controlId: "encoder-0", instanceId: "dialReasoning", actionId: "reasoning" },
] as const;

export const defaultV1MaxBindings: readonly DefaultQ6Binding[] = [
  { controlId: "r1c15", instanceId: "task-agent-1", actionId: "task_agent", taskSlotIndex: 0 },
  { controlId: "r2c15", instanceId: "task-agent-2", actionId: "task_agent", taskSlotIndex: 1 },
  { controlId: "r3c15", instanceId: "pushToTalk", actionId: "ptt" },
  { controlId: "encoder-0", instanceId: "dialReasoning", actionId: "reasoning" },
] as const;

export type LegacyRuntimeMessage =
  | { type: "event"; source: "codex" | "claude" | "manual"; state: AgentState }
  | { type: "text"; source: "codex" | "claude" | "manual"; text: string }
  | { type: "preview"; state: AgentState; durationMs?: number }
  | { type: "test" }
  | { type: "restore" }
  | { type: "status" };

export type RuntimeMessage = LegacyRuntimeMessage | RpcRequest | { type: "observe" };

export interface RuntimeStatus {
  running: boolean;
  device?: string;
  support?: string;
  extensionVersion?: number;
  layoutMatches?: boolean;
  fullControl?: boolean;
  profileId: string;
  layoutHash: string;
  state: AgentState;
  selectedTaskId?: string;
  appServer: "starting" | "ready" | "offline" | "restarting";
  authenticated: boolean;
  models: Array<{ model: string; displayName?: string; isDefault?: boolean; efforts: string[]; serviceTiers: string[] }>;
  capabilities: {
    protocolEnvelopeVersion: 1;
    extensionVersion: 2;
    profileV2: true;
    appServer: boolean;
    fullHardwareControl: boolean;
    voiceStates: VoiceState[];
    plan: boolean;
    rpcVersion: 1;
  };
  voiceState: VoiceState;
}

export type VoiceState = "idle" | "recording" | "processing" | "ready" | "error";

interface PendingApproval {
  requestId: JsonRpcId;
  method: string;
  params: Record<string, unknown>;
  responded: boolean;
}

interface CaptureSession {
  token: number;
  expiresAt: number;
  timer: NodeJS.Timeout;
}

interface CapturedPress {
  token: number;
  controlId: string;
  kind: ControlEventKind;
  row: number;
  column: number;
}

interface PendingBindingAck {
  resolve: (value: boolean) => void;
  timer: NodeJS.Timeout;
}

interface ReasoningPressSession {
  binding: Binding;
  taskId?: string;
  pressedAtTick: number;
  timer: NodeJS.Timeout;
  longPressFired: boolean;
}

interface ActiveLightingPreview {
  effects: EffectSpec[];
  atmosphereMix: number;
  epoch: number;
  seed: number;
}

export interface ArkeyDaemonOptions {
  runtimeDirectory?: string;
  stores?: ArkeyStores;
  appServer?: CodexAppServerClient;
  now?: () => Date;
}

export class ArkeyDaemon extends EventEmitter<{ runtime: [RuntimeEvent] }> {
  private server?: Server;
  private heartbeat?: NodeJS.Timeout;
  private randomTyping?: NodeJS.Timeout;
  private voiceWave?: NodeJS.Timeout;
  private voiceWavePosition = 0;
  private testTimer?: NodeJS.Timeout;
  private textTimer?: NodeJS.Timeout;
  private lightingTimer?: NodeJS.Timeout;
  private textQueue: number[] = [];
  private state = AgentState.Idle;
  private sourceStates = new Map<string, AgentState>();
  private observers = new Set<Socket>();
  private eventSequence = 0;
  private transport: KeyboardTransport;
  private appServer: CodexAppServerClient;
  private stores: ArkeyStores;
  private settings: ArkeySettings;
  private bindingState: StoredBindings;
  private taskState: StoredTasks;
  private requestQueues = new Map<string, PendingApproval[]>();
  private capture?: CaptureSession;
  private capturedPress?: CapturedPress;
  private reasoningPress?: ReasoningPressSession;
  private activeLightingPreview?: ActiveLightingPreview;
  private overlayEpoch = 0;
  private voiceState: VoiceState = "idle";
  private taskEntryTransients = new Map<string, { state: TaskLightState; effect: EffectSpec; timer: NodeJS.Timeout }>();
  private controlTransients = new Map<string, { effect: EffectSpec; timer: NodeJS.Timeout }>();
  private lastHardwareTaskClick = new Map<string, number>();
  private appServerState: RuntimeStatus["appServer"] = "offline";
  private accountPoll?: NodeJS.Timeout;
  private readonly now: () => Date;
  private readonly directory: string;
  private readonly daemonSocketPath: string;
  private readonly daemonPidPath: string;
  private pendingBindingAcks = new Map<number, Set<PendingBindingAck>>();
  private hardwareRearm?: Promise<boolean>;
  private lastFirmwareArmStatus?: AckStatus;
  private acknowledgedBindingRevision?: number;
  private activeVoiceControl?: { taskId?: string; controlId: string; eventSequence: number };
  private actions: ActionDescriptor[] = defaultActions.map((action) => ({ ...action }));
  private planPreset?: { name: string; mode: "plan"; model?: string; reasoningEffort?: string | null };
  private nextCollaborationModes = new Map<string, Record<string, unknown>>();

  constructor(transport = new KeyboardTransport(), options: ArkeyDaemonOptions = {}) {
    super();
    this.transport = transport;
    this.directory = options.runtimeDirectory ?? runtimeDir;
    this.daemonSocketPath = join(this.directory, "arkey.sock");
    this.daemonPidPath = join(this.directory, "arkey.pid");
    this.stores = options.stores ?? createStores(this.directory);
    this.settings = this.stores.settings.read();
    this.bindingState = this.stores.bindings.read();
    this.taskState = this.stores.tasks.read();
    this.taskState.tasks = this.taskState.tasks.map((task, index) => ({
      ...task,
      slotIndex: Number.isInteger((task as TaskSlot).slotIndex) ? (task as TaskSlot).slotIndex : index,
      selected: task.taskId === this.taskState.selectedTaskId,
      activeTurnId: undefined,
      pendingApprovalCount: 0,
      pendingStructuredRequestCount: 0,
      state: task.state === "working" || task.state === "requiresInput" ? "offline" : task.state,
    }));
    const occupiedSlots = new Set<number>();
    for (const task of this.taskState.tasks) {
      if (occupiedSlots.has(task.slotIndex)) task.slotIndex = this.taskState.tasks.reduce((maximum, candidate) => Math.max(maximum, candidate.slotIndex), -1) + 1;
      occupiedSlots.add(task.slotIndex);
    }
    this.appServer = options.appServer ?? new CodexAppServerClient();
    this.now = options.now ?? (() => new Date());
    this.attachTransport();
    this.attachAppServer();
    this.ensureSixTaskSlots();
  }

  start(): Promise<void> {
    mkdirSync(this.directory, { recursive: true, mode: 0o700 });
    rmSync(this.daemonSocketPath, { force: true });
    writeFileSync(this.daemonPidPath, String(process.pid), { mode: 0o600 });
    const connection = this.ensureConnected();
    this.ensureDefaultBindings(connection?.profile ?? q6ProAnsi);
    this.stores.settings.write(this.settings);
    this.stores.bindings.write(this.bindingState);
    this.persistTasks();
    this.heartbeat = setInterval(() => {
      if (!this.transport.send(Opcode.Heartbeat)) this.ensureConnected();
    }, 1000);
    void this.appServer.start().catch((error) => {
      this.broadcast("appserver.error", { message: error instanceof Error ? error.message : String(error) });
    });
    this.server = createServer((socket) => this.accept(socket));
    return new Promise((resolve, reject) => {
      this.server!.once("error", reject);
      this.server!.listen(this.daemonSocketPath, () => {
        this.server!.off("error", reject);
        resolve();
      });
    });
  }

  private attachTransport(): void {
    this.transport.on?.("control", (event) => this.handleControlEvent(event));
    this.transport.on?.("packet", (packet) => {
      if (packet.opcode !== Opcode.Ack) return;
      const ack = decodeAck(packet.payload);
      const pending = this.pendingBindingAcks.get(ack.revision);
      if (pending?.size && ack.opcode === Opcode.SetBindingMask) {
        this.pendingBindingAcks.delete(ack.revision);
        for (const waiter of pending) {
          clearTimeout(waiter.timer);
          waiter.resolve(ack.status === AckStatus.Ok);
        }
      }
      if (ack.opcode === Opcode.SetBindingMask && ack.status === AckStatus.Ok) {
        const wasActive = this.hardwareBindingsActive();
        this.lastFirmwareArmStatus = AckStatus.Ok;
        this.acknowledgedBindingRevision = ack.revision;
        if (!wasActive && this.hardwareBindingsActive()) {
          this.broadcast("binding.activated", { reason: "firmware-ack", revision: ack.revision });
          this.broadcast("binding.changed", this.bindingView());
        }
      } else if (ack.opcode === Opcode.SetBindingMask) {
        this.invalidateHardwareBindingAcknowledgement("firmware-rejected-binding-mask", ack.revision);
      } else if (ack.opcode === Opcode.Heartbeat) {
        const status = ack.status as AckStatus;
        if (this.lastFirmwareArmStatus !== status) {
          this.lastFirmwareArmStatus = status;
          this.broadcast("device.control.status", {
            status,
            armed: status === AckStatus.Ok,
            usb: status !== AckStatus.NotUsb,
            revision: ack.revision,
          });
        }
        if (status === AckStatus.NotArmed) {
          this.invalidateHardwareBindingAcknowledgement("firmware-not-armed");
          void this.rearmHardware("firmware-not-armed");
        } else if (status === AckStatus.NotUsb) {
          this.invalidateHardwareBindingAcknowledgement("transport-degraded");
          this.clearReasoningPress("transport-degraded");
        }
      }
      this.broadcast("firmware.ack", ack);
    });
    this.transport.on?.("disconnect", (error) => {
      this.stopLightingPreview(true, "device-disconnected");
      this.stopCapture(false);
      this.capturedPress = undefined;
      this.clearReasoningPress("device-disconnected");
      this.lastFirmwareArmStatus = undefined;
      this.invalidateHardwareBindingAcknowledgement("device-disconnected");
      this.cancelActiveVoiceControl("device-disconnected");
      if (this.voiceState !== "idle") this.setVoiceState("idle");
      this.broadcast("device.disconnected", { message: error?.message });
    });
    this.transport.on?.("error", (error) => this.broadcast("device.error", { message: error.message }));
  }

  private attachAppServer(): void {
    this.appServer.on("state", (state) => {
      this.appServerState = state.state;
      if (state.state === "offline" || state.state === "restarting") {
        this.invalidatePendingRequests(state.state);
        this.setPlanCapability(undefined);
      }
      this.broadcast("appserver.state", state);
    });
    this.appServer.on("ready", (ready) => {
      this.broadcast("appserver.ready", {
        account: ready.account,
        models: ready.models,
      });
      void this.resumeManagedTasks();
      void this.probePlanCapability();
    });
    this.appServer.on("notification", (notification) => this.handleAppServerNotification(notification));
    this.appServer.on("serverRequest", (request) => this.handleAppServerRequest(request));
    this.appServer.on("stderr", (line) => this.broadcast("appserver.log", { line: line.slice(0, 2000) }));
  }

  private accept(socket: Socket): void {
    let buffer = "";
    socket.setEncoding("utf8");
    socket.on("data", (chunk) => {
      buffer += chunk;
      let newline: number;
      while ((newline = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, newline);
        buffer = buffer.slice(newline + 1);
        if (!line.trim()) continue;
        void this.handleLine(line, socket);
      }
    });
    socket.on("close", () => this.observers.delete(socket));
    socket.on("error", () => this.observers.delete(socket));
  }

  private async handleLine(line: string, socket: Socket): Promise<void> {
    try {
      const message = JSON.parse(line) as RuntimeMessage;
      if (message.type === "observe") {
        this.observers.add(socket);
        socket.write(`${JSON.stringify(this.runtimeEvent("snapshot", this.snapshot()))}\n`);
        return;
      }
      if (message.type === "rpc") {
        const response: RpcResponse = { version: 1, id: message.id };
        try { response.result = await this.rpc(message.method, message.params); }
        catch (error) { response.error = { code: "RPC_FAILED", message: error instanceof Error ? error.message : String(error) }; }
        socket.write(`${JSON.stringify(response)}\n`);
        return;
      }
      this.handle(message, socket);
    } catch (error) {
      socket.write(`${JSON.stringify({ error: error instanceof Error ? error.message : String(error) })}\n`);
    }
  }

  handle(message: LegacyRuntimeMessage, socket?: Socket): void {
    const profile = this.ensureConnected()?.profile;
    if (message.type === "status") {
      socket?.write(`${JSON.stringify(this.status())}\n`);
      return;
    }
    if (message.type === "restore") {
      if (this.testTimer) clearTimeout(this.testTimer);
      this.testTimer = undefined;
      this.sourceStates.clear();
      this.textQueue.length = 0;
      this.stopLightingPreview(false);
      this.setState(AgentState.Idle);
      this.transport.send(Opcode.Restore);
      void this.rearmHardware("manual-restore");
      this.broadcast("lighting.restored", {});
      return;
    }
    if (message.type === "event") {
      this.sourceStates.set(message.source, message.state);
      this.setState(mergeStates([...this.sourceStates.values()]));
      return;
    }
    if (message.type === "preview") {
      this.sourceStates.set("manual", message.state);
      this.setState(mergeStates([...this.sourceStates.values()]));
      this.scheduleManualRestore(message.durationMs ?? 5000);
      return;
    }
    if (!profile) return;
    if (message.type === "text") {
      this.setState(AgentState.Streaming);
      this.textQueue.push(...mapText(profile, message.text));
      this.startTextPlayback();
      if (message.source === "manual") this.scheduleManualRestore(Math.max(1200, this.textQueue.length * 35 + 700));
      return;
    }
    if (message.type === "test") {
      this.sourceStates.set("manual", AgentState.Thinking);
      this.setState(mergeStates([...this.sourceStates.values()]));
      this.scheduleManualRestore(5000);
    }
  }

  async rpc(method: string, params: unknown = {}): Promise<unknown> {
    const object = asObject(params);
    switch (method) {
      case "profile.get":
        return {
          profile: profileDocument(this.activeProfile()),
          connection: this.transport.connection ? {
            product: this.transport.connection.product,
            support: this.transport.connection.support,
            extensionVersion: this.transport.connection.extensionVersion,
            layoutMatches: this.transport.connection.layoutMatches,
            fullControl: this.transport.connection.fullControl,
          } : undefined,
        };
      case "settings.get":
        return this.settings;
      case "settings.update": {
        const previousHardwareSync = this.settings.hardwareSync;
        const next: ArkeySettings = {
          version: 1,
          workspaceRoot: typeof object.workspaceRoot === "string" ? object.workspaceRoot : this.settings.workspaceRoot,
          hardwareSync: typeof object.hardwareSync === "boolean" ? object.hardwareSync : this.settings.hardwareSync,
          atmosphereMix: typeof object.atmosphereMix === "number" ? object.atmosphereMix : this.settings.atmosphereMix,
          taskSort: typeof object.taskSort === "string" ? object.taskSort as ArkeySettings["taskSort"] : this.settings.taskSort,
          onboardingSkipped: typeof object.onboardingSkipped === "boolean" ? object.onboardingSkipped : this.settings.onboardingSkipped,
          selectedModel: typeof object.selectedModel === "string" ? object.selectedModel : this.settings.selectedModel,
        };
        if (!isSettings(next)) throw new Error("Invalid Arkey settings");
        this.settings = next;
        this.stores.settings.write(this.settings);
        if (previousHardwareSync && !next.hardwareSync && this.transport.connection?.fullControl) {
          this.transport.send(Opcode.ClearKeyEffects, encodeClearKeyEffects());
        } else if (!previousHardwareSync && next.hardwareSync) {
          this.restoreHardwareOverlays();
        } else {
          this.renderOverlays();
        }
        this.broadcast("settings.changed", this.settings);
        return this.settings;
      }
      case "binding.list":
        return this.bindingView();
      case "binding.set":
        return this.setBinding(object);
      case "binding.instance.create": {
        const actionId = String(object.actionId ?? "");
        const action = this.actions.find((candidate) => candidate.actionId === actionId);
        if (!action) throw new Error(`Unknown action ${actionId}`);
        if (!action.enabled) throw new Error(`Action ${actionId} is disabled: ${action.disabledReason ?? "not currently available"}`);
        const task = actionId === "task_agent" ? this.createTask(typeof object.title === "string" ? object.title : undefined) : undefined;
        return { instanceId: randomUUID(), actionId, task };
      }
      case "binding.remove":
        return this.removeBinding(String(object.controlId ?? ""));
      case "binding.capture.start":
        return this.startCapture(numberParam(object.token, Math.floor(Math.random() * 65535)), numberParam(object.timeoutMs, 30_000));
      case "binding.capture.stop":
        this.stopCapture(true, "client-stop");
        return { stopped: true };
      case "task.list":
        return this.sortedTasks();
      case "task.select":
        return this.selectTask(String(object.taskId ?? ""));
      case "task.update":
        return this.updateTask(object);
      case "task.reorder":
        return this.reorderTasks(object.taskIds);
      case "task.create":
      case "task.slot.create":
        return this.createTask(typeof object.title === "string" ? object.title : undefined);
      case "task.import":
        return this.importTask(typeof object.threadId === "string" ? object.threadId : undefined);
      case "task.fork":
        return this.forkTask(String(object.taskId ?? this.taskState.selectedTaskId ?? ""));
      case "account.login.start":
        await this.ensureAppServer();
        return this.startAccountLogin();
      case "firmware.preflight":
        return this.firmwarePreflight();
      case "account.read":
        await this.ensureAppServer();
        return this.appServer.request("account/read", { refreshToken: false });
      case "composer.send":
        return this.sendComposer(String(object.text ?? ""), typeof object.taskId === "string" ? object.taskId : undefined, object.attachments);
      case "action.trigger":
        return this.triggerAction(String(object.actionId ?? ""), object);
      case "approval.respond":
        return this.respondStructuredApproval(object);
      case "lighting.preview":
        return this.startLightingPreview(object);
      case "lighting.stop":
        this.stopLightingPreview(true);
        return { stopped: true };
      case "voice.state":
        return this.setVoiceState(String(object.state ?? "") as VoiceState);
      case "actions.list":
        return this.actions;
      default:
        throw new Error(`Unknown Arkey RPC method ${method}`);
    }
  }

  private status(): RuntimeStatus {
    const connection = this.ensureConnected();
    const profile = connection?.profile ?? this.activeProfile();
    const account = this.appServer.account;
    const authenticated = this.appServerState === "ready" && this.isAccountAuthenticated(account);
    return {
      running: true,
      device: connection?.product,
      support: connection?.support,
      extensionVersion: connection?.extensionVersion,
      layoutMatches: connection?.layoutMatches,
      fullControl: connection?.fullControl,
      profileId: profile.profileId,
      layoutHash: profile.layoutHash,
      state: this.state,
      selectedTaskId: this.taskState.selectedTaskId,
      appServer: this.appServerState,
      authenticated,
      models: this.appServer.models.map((model) => ({
        model: model.model,
        displayName: model.displayName,
        isDefault: model.isDefault,
        efforts: model.supportedReasoningEfforts?.map((effort) => effort.reasoningEffort) ?? [],
        serviceTiers: model.serviceTiers?.map((tier) => tier.id) ?? [],
      })),
      capabilities: {
        protocolEnvelopeVersion: 1,
        extensionVersion: 2,
        profileV2: true,
        appServer: this.appServerState === "ready",
        fullHardwareControl: connection?.fullControl ?? false,
        voiceStates: ["idle", "recording", "processing", "ready", "error"],
        plan: this.planPreset !== undefined,
        rpcVersion: 1,
      },
      voiceState: this.voiceState,
    };
  }

  private firmwarePreflight(): Record<string, unknown> {
    const profile = this.activeProfile();
    const isV1Max = profile.profileId === "keychron-v1-max-ansi-knob";
    const binaryPath = join(profileDirectory, "..", "build", isV1Max ? "arkey-v1-max-ansi-knob-v0.1.0.bin" : "arkey-q6-pro-ansi-v0.1.0.bin");
    const binaryExists = existsSync(binaryPath);
    const binary = binaryExists ? readFileSync(binaryPath) : undefined;
    return {
      dryRun: true,
      flashed: false,
      target: isV1Max ? "keychron/v1_max/ansi_encoder" : "keychron/q6_pro/ansi_encoder",
      pinnedQmkCommit: isV1Max ? "bc1bdeb85f39cccd5e503f4d8f472078a8c1472a" : "618127a725a1773e85f13455602cf6f72ab4de17",
      profileId: profile.profileId,
      layoutHash: profile.layoutHash,
      connection: this.transport.connection ? {
        product: this.transport.connection.product,
        extensionVersion: this.transport.connection.extensionVersion,
        layoutMatches: this.transport.connection.layoutMatches,
        fullControl: this.transport.connection.fullControl,
      } : undefined,
      binary: binary ? {
        path: binaryPath,
        bytes: statSync(binaryPath).size,
        sha256: createHash("sha256").update(binary).digest("hex"),
      } : { path: binaryPath, missing: true },
      recovery: {
        configured: false,
        reason: "Select and verify the matching official recovery bundle before flashing",
      },
      dfu: { detected: false, probed: false },
      flashReady: false,
      requiresExplicitConfirmation: true,
    };
  }

  private snapshot(): Record<string, unknown> {
    const status = this.status();
    return {
      status,
      settings: this.settings,
      bindings: this.bindingView(),
      tasks: this.sortedTasks(),
      actions: this.actions,
      authenticated: status.authenticated,
      models: status.models,
      capabilities: status.capabilities,
      voiceState: this.voiceState,
    };
  }

  private ensureConnected() {
    if (this.transport.connection?.support === "arkey") return this.transport.connection;
    const previous = this.transport.connection;
    const connection = this.transport.connect();
    if (connection && connection !== previous) {
      this.lastFirmwareArmStatus = undefined;
      this.invalidateHardwareBindingAcknowledgement("device-connected");
      this.broadcast("device.connected", {
        product: connection.product,
        support: connection.support,
        extensionVersion: connection.extensionVersion,
        layoutMatches: connection.layoutMatches,
        fullControl: connection.fullControl,
      });
      // Legacy firmware can restore the global layer immediately. Full-control
      // v2 waits for the binding-mask ACK in rearmHardware before restoring any
      // live lighting state.
      if (connection.support === "arkey" && !connection.fullControl && this.state !== AgentState.Idle) this.setState(this.state);
      if (connection.fullControl) {
        void this.rearmHardware("device-connected");
      }
    }
    return connection;
  }

  private scheduleManualRestore(durationMs: number): void {
    if (this.testTimer) clearTimeout(this.testTimer);
    this.testTimer = setTimeout(() => {
      this.testTimer = undefined;
      this.sourceStates.delete("manual");
      const next = mergeStates([...this.sourceStates.values()]);
      this.setState(next);
      if (next === AgentState.Idle) {
        this.transport.send(Opcode.Restore);
        void this.rearmHardware("global-animation-restored");
      }
    }, Math.min(30_000, Math.max(250, durationMs)));
  }

  private startTextPlayback(): void {
    if (this.textTimer) return;
    this.textTimer = setInterval(() => {
      const led = this.textQueue.shift();
      if (led !== undefined) this.transport.send(Opcode.KeyEvents, encodeKeyEvents([{ led }]));
      if (!this.textQueue.length && this.textTimer) {
        clearInterval(this.textTimer);
        this.textTimer = undefined;
      }
    }, 35);
  }

  private setState(state: AgentState): void {
    this.state = state;
    const colors: Record<number, [number, number, number]> = {
      [AgentState.Idle]: [0, 0, 0],
      [AgentState.Thinking]: [170, 230, 130],
      [AgentState.Tool]: [30, 255, 210],
      [AgentState.Streaming]: [115, 255, 220],
      [AgentState.Complete]: [85, 255, 220],
      [AgentState.Error]: [0, 255, 255],
    };
    this.transport.send(Opcode.SetState, encodeState(state, ...colors[state]));
    if (this.randomTyping) clearInterval(this.randomTyping);
    this.randomTyping = undefined;
    const profile = this.transport.connection?.profile;
    if (profile && (state === AgentState.Thinking || state === AgentState.Tool)) {
      this.randomTyping = setInterval(() => {
        const led = profile.randomKeys[Math.floor(Math.random() * profile.randomKeys.length)];
        this.transport.send(Opcode.KeyEvents, encodeKeyEvents([{ led }]));
      }, state === AgentState.Tool ? 90 : 180);
    }
    this.applyVoiceGlobalOverride();
    this.broadcast("lighting.global", { state });
  }

  private setVoiceState(state: VoiceState): Record<string, unknown> {
    if (!["idle", "recording", "processing", "ready", "error"].includes(state)) throw new Error(`Unknown voice state ${state}`);
    this.voiceState = state;
    if (state === "recording" || state === "processing") this.sourceStates.set("voice", AgentState.Streaming);
    else if (state === "error") this.sourceStates.set("voice", AgentState.Error);
    else this.sourceStates.delete("voice");
    this.setState(mergeStates([...this.sourceStates.values()]));
    this.updateVoiceWave();
    this.renderOverlays();
    const result = { state, effects: state === "idle" || state === "error" ? undefined : effectCatalog.voice[state] };
    this.broadcast("voice.state.changed", result);
    return result;
  }

  private applyVoiceGlobalOverride(): void {
    if (this.voiceState === "recording") {
      const voice = effectCatalog.voice.recording;
      this.transport.send(Opcode.SetState, encodeState(AgentState.Streaming, voice.hue, voice.saturation, voice.value));
    } else if (this.voiceState === "processing") {
      const voice = effectCatalog.voice.processing;
      this.transport.send(Opcode.SetState, encodeState(AgentState.Streaming, voice.hue, voice.saturation, voice.value));
    }
  }

  private updateVoiceWave(): void {
    if (this.voiceWave) clearInterval(this.voiceWave);
    this.voiceWave = undefined;
    this.voiceWavePosition = 0;
    if (this.voiceState !== "recording" && this.voiceState !== "processing") return;

    const controls = this.activeProfile().controls.filter((control) => control.ledIndex !== null);
    const maximumX = controls.reduce((maximum, control) => Math.max(maximum, control.frame.x + control.frame.width / 2), 0);
    const steps = Math.max(1, Math.ceil(maximumX * 2) + 1);
    const tick = () => {
      const center = (this.voiceWavePosition % steps) / 2;
      this.voiceWavePosition = (this.voiceWavePosition + 1) % steps;
      const events = controls
        .map((control) => ({ control, distance: Math.abs(control.frame.x + control.frame.width / 2 - center) }))
        .filter((candidate) => candidate.distance <= 0.72)
        .slice(0, 12)
        .map((candidate) => ({
          led: candidate.control.ledIndex!,
          intensity: Math.max(150, Math.round(255 - candidate.distance * 120)),
        }));
      if (events.length) this.transport.send(Opcode.KeyEvents, encodeKeyEvents(events));
    };
    tick();
    this.voiceWave = setInterval(tick, 70);
  }

  private voiceEffectForBinding(binding: Binding, led: number): EffectSpec | undefined {
    const applies = binding.actionId === "ptt" || (this.voiceState === "ready" && binding.actionId === "send");
    if (!applies || this.voiceState === "idle") return undefined;
    if (this.voiceState === "error") return semanticEffect(led, "error", true);
    const definition = effectCatalog.voice[this.voiceState];
    return {
      led,
      effect: effectCatalog.primitives[definition.primitive],
      hue: definition.hue,
      saturation: definition.saturation,
      value: definition.value,
      speed: definition.primitive === "solid" ? 0 : Math.max(1, Math.min(255, Math.round((3200 - effectCatalog.selectedPulsePeriodMs) / 10))),
      phase: 0,
      durationMs: 0,
      flags: 0,
    };
  }

  private async setBinding(params: Record<string, unknown>): Promise<unknown> {
    const profile = this.activeProfile();
    const controlId = this.canonicalBindingControlId(String(params.controlId ?? ""), profile);
    const actionId = String(params.actionId ?? "");
    const instanceId = String(params.instanceId ?? randomUUID());
    const control = profile.controls.find((candidate) => candidate.id === controlId) ??
      (profile.encoder.id === controlId ? profile.encoder : undefined);
    if (!control || !control.bindable) throw new Error(`Control ${controlId} is not bindable`);
    const action = this.actions.find((candidate) => candidate.actionId === actionId);
    if (!action) throw new Error(`Unknown action ${actionId}`);
    if (!action.enabled) throw new Error(`Action ${actionId} is disabled: ${action.disabledReason ?? "not currently available"}`);
    const taskId = typeof params.taskId === "string" ? params.taskId : undefined;
    if (actionId === "task_agent" && !taskId) throw new Error("task_agent binding requires a daemon taskId from task.create");
    if (taskId && !this.taskState.tasks.some((task) => task.taskId === taskId)) throw new Error(`Unknown Arkey task ${taskId}`);
    const existing = this.bindingState.bindings.find((binding) =>
      binding.profileId === profile.profileId && this.canonicalBindingControlId(binding.controlId, profile) === controlId
    );
    if (existing && params.replace !== true) throw new Error(`Control ${controlId} is already bound`);
    const now = this.now().toISOString();
    const binding: Binding = {
      controlId,
      instanceId,
      actionId,
      taskId,
      profileId: profile.profileId,
      layoutHash: profile.layoutHash,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
    };
    const previous = this.bindingState;
    if (controlId === profile.encoder.id) this.clearReasoningPress("binding-changed");
    const next: StoredBindings = {
      version: 1,
      revision: (previous.revision + 1) & 0xffff,
      bindings: [...previous.bindings.filter((candidate) =>
        candidate.profileId !== profile.profileId || this.canonicalBindingControlId(candidate.controlId, profile) !== controlId
      ), binding],
    };
    this.invalidateHardwareBindingAcknowledgement("binding-revision-changed");
    this.bindingState = next;
    this.stores.bindings.write(next);
    const hardwareSynchronized = await this.syncBindingMask(true);
    if (this.transport.connection?.fullControl && !hardwareSynchronized) {
      this.bindingState = previous;
      this.stores.bindings.write(previous);
      void this.syncBindingMask(false);
      throw new Error("Firmware did not acknowledge the binding; persisted state was rolled back");
    }
    this.startBindingTransient(binding.controlId, existing ? "replace" : "success");
    const bindingResult = {
      ...binding,
      active: this.isBindingCurrent(binding) && this.hardwareBindingsActive(),
      pending: this.isBindingCurrent(binding) && !this.hardwareBindingsActive(),
      incompatible: !this.isBindingCurrent(binding),
    };
    this.broadcast("binding.changed", { ...this.bindingView(), binding: bindingResult, change: existing ? "replace" : "set", hardwareSynchronized });
    return { binding: bindingResult, revision: next.revision, hardwareSynchronized, hardwareAck: this.hardwareBindingsActive() };
  }

  private async removeBinding(controlId: string): Promise<unknown> {
    const profile = this.activeProfile();
    controlId = this.canonicalBindingControlId(controlId, profile);
    if (!controlId) throw new Error("binding.remove requires controlId");
    const previous = this.bindingState;
    if (!previous.bindings.some((binding) => binding.profileId === profile.profileId && this.canonicalBindingControlId(binding.controlId, profile) === controlId)) return { removed: false };
    if (controlId === profile.encoder.id) this.clearReasoningPress("binding-removed");
    const next: StoredBindings = {
      version: 1,
      revision: (previous.revision + 1) & 0xffff,
      bindings: previous.bindings.filter((binding) =>
        binding.profileId !== profile.profileId || this.canonicalBindingControlId(binding.controlId, profile) !== controlId
      ),
    };
    this.invalidateHardwareBindingAcknowledgement("binding-revision-changed");
    this.bindingState = next;
    this.stores.bindings.write(next);
    const hardwareSynchronized = await this.syncBindingMask(true);
    if (this.transport.connection?.fullControl && !hardwareSynchronized) {
      this.bindingState = previous;
      this.stores.bindings.write(previous);
      void this.syncBindingMask(false);
      throw new Error("Firmware did not acknowledge removal; persisted state was rolled back");
    }
    this.renderOverlays();
    this.broadcast("binding.changed", { ...this.bindingView(), controlId, removed: true, change: "remove", hardwareSynchronized });
    return { removed: true, revision: next.revision, hardwareSynchronized, hardwareAck: this.hardwareBindingsActive() };
  }

  private syncBindingMask(waitForAck: boolean): Promise<boolean> {
    if (!this.transport.connection?.fullControl) return Promise.resolve(false);
    const profile = this.activeProfile();
    const positions = this.bindingState.bindings.filter((binding) => this.isBindingCurrent(binding)).flatMap((binding) => {
      const bindingControlId = this.canonicalBindingControlId(binding.controlId, profile);
      const controlId = bindingControlId === profile.encoder.id ? profile.encoder.pressControlId : bindingControlId;
      const control = profile.controls.find((candidate) => candidate.id === controlId);
      return control ? [control.matrix] : [];
    });
    // Two bits per encoder: CW then CCW. A bound knob must capture both.
    const encoderMask = this.bindingState.bindings.some((binding) =>
      this.isBindingCurrent(binding) && this.canonicalBindingControlId(binding.controlId, profile) === profile.encoder.id
    ) ? 0x03 : 0;
    const payload = encodeBindingMask({
      revision: this.bindingState.revision,
      matrixBits: matrixBindingBits(positions, profile.matrix.columns),
      encoderMask,
      flags: 0,
    });
    if (!waitForAck) return Promise.resolve(this.transport.send(Opcode.SetBindingMask, payload));
    return new Promise((resolve) => {
      const revision = this.bindingState.revision;
      let pending!: PendingBindingAck;
      pending = {
        resolve,
        timer: setTimeout(() => {
          const waiters = this.pendingBindingAcks.get(revision);
          waiters?.delete(pending);
          if (!waiters?.size) this.pendingBindingAcks.delete(revision);
          resolve(false);
        }, 750),
      };
      const waiters = this.pendingBindingAcks.get(revision) ?? new Set<PendingBindingAck>();
      waiters.add(pending);
      this.pendingBindingAcks.set(revision, waiters);
      if (!this.transport.send(Opcode.SetBindingMask, payload)) {
        clearTimeout(pending.timer);
        waiters.delete(pending);
        if (!waiters.size) this.pendingBindingAcks.delete(revision);
        resolve(false);
      }
    });
  }

  private rearmHardware(reason: string): Promise<boolean> {
    if (!this.transport.connection?.fullControl) return Promise.resolve(false);
    if (this.hardwareRearm) return this.hardwareRearm;
    let operation!: Promise<boolean>;
    operation = this.syncBindingMask(true).then((synchronized) => {
      if (!synchronized) {
        this.broadcast("device.control.rearm.failed", { reason, revision: this.bindingState.revision });
        return false;
      }
      // The firmware restore path intentionally drops both the leased bindings
      // and every live light layer. Re-arm the mask first, then reconstruct the
      // current global atmosphere and semantic overlays in that order.
      this.setState(this.state);
      this.restoreHardwareOverlays();
      this.broadcast("device.control.rearmed", { reason, revision: this.bindingState.revision });
      return true;
    }).finally(() => {
      if (this.hardwareRearm === operation) this.hardwareRearm = undefined;
    });
    this.hardwareRearm = operation;
    return operation;
  }

  private startCapture(token: number, timeoutMs: number): Record<string, unknown> {
    if (this.capturedPress) throw new Error("Release the previously captured control before starting another capture");
    this.stopCapture(false);
    const boundedTimeout = Math.min(30_000, Math.max(250, timeoutMs));
    const hardware = this.transport.connection?.fullControl === true &&
      this.transport.send(Opcode.SetCaptureMode, encodeCaptureMode({ enabled: true, token, timeoutMs: boundedTimeout }));
    const timer = setTimeout(() => this.stopCapture(true, "timeout"), boundedTimeout);
    this.capture = { token, expiresAt: Date.now() + boundedTimeout, timer };
    this.broadcast("binding.capture.started", { token, timeoutMs: boundedTimeout, hardware });
    return { token, timeoutMs: boundedTimeout, hardware };
  }

  private stopCapture(notify: boolean, reason?: string): void {
    if (!this.capture) return;
    clearTimeout(this.capture.timer);
    const token = this.capture.token;
    this.capture = undefined;
    if (this.transport.connection?.fullControl) this.transport.send(Opcode.SetCaptureMode, encodeCaptureMode({ enabled: false, token, timeoutMs: 0 }));
    if (notify) this.broadcast("binding.capture.stopped", { token, reason });
  }

  private handleControlEvent(event: ControlEvent): void {
    const profile = this.activeProfile();
    const matrixControlId = event.kind === ControlEventKind.Key
      ? controlForMatrix(profile, event.row, event.column)?.id
      : undefined;
    const encoderPress = matrixControlId === profile.encoder.pressControlId;
    const controlId = event.kind === ControlEventKind.Key
      ? encoderPress ? profile.encoder.id : matrixControlId
      : profile.encoder.id;
    if (!controlId) return;
    const isCaptureEvent = (event.flags & 0x01) !== 0;
    const capturedPress = this.capturedPress;
    if (!event.pressed && isCaptureEvent && capturedPress &&
      event.token === capturedPress.token && event.kind === capturedPress.kind &&
      event.row === capturedPress.row && event.column === capturedPress.column) {
      this.capturedPress = undefined;
      this.broadcast("binding.capture.released", { token: capturedPress.token, controlId: capturedPress.controlId, event });
      return;
    }
    if (this.capture && event.pressed && isCaptureEvent && event.token === this.capture.token) {
      const token = this.capture.token;
      this.stopCapture(false);
      this.capturedPress = { token, controlId, kind: event.kind, row: event.row, column: event.column };
      this.broadcast("binding.capture.captured", { token, controlId, event });
      return;
    }
    // A capture-flagged event belongs exclusively to its capture lifecycle.
    // Firmware reports can remain queued while the host stops or replaces a
    // token, so an unmatched event must never fall through to a live binding
    // such as Send, Approve, or Decline.
    if (isCaptureEvent) {
      this.broadcast("binding.capture.ignored", {
        token: event.token,
        activeToken: this.capture?.token,
        capturedToken: capturedPress?.token,
        controlId,
        reason: "stale-or-unmatched-token",
      });
      return;
    }
    const binding = this.bindingState.bindings.find((candidate) =>
      this.isBindingCurrent(candidate) && this.canonicalBindingControlId(candidate.controlId, profile) === controlId
    );
    if (!binding) return;
    if (binding.actionId === "reasoning" && encoderPress) {
      this.handleReasoningPress(event, binding);
      return;
    }
    if (binding.actionId === "ptt" && event.kind === ControlEventKind.Key) {
      const taskId = binding.taskId ?? this.taskState.selectedTaskId;
      if (event.pressed) {
        this.cancelActiveVoiceControl("replaced");
        this.activeVoiceControl = { taskId, controlId, eventSequence: event.eventSequence };
      } else {
        const active = this.activeVoiceControl;
        if (!active || active.controlId !== controlId) return;
        this.activeVoiceControl = undefined;
      }
      this.broadcast("voice.control", {
        phase: event.pressed ? "press" : "release",
        taskId,
        controlId,
        deviceTick: event.deviceTick,
        eventSequence: event.eventSequence,
      });
      return;
    }
    // Firmware reports paired press/release events for both keys and encoder
    // directions. Actions fire once, on press only.
    if (!event.pressed) return;
    void this.triggerAction(binding.actionId, {
      source: "hardware",
      taskId: binding.taskId,
      instanceId: binding.instanceId,
      direction: event.kind === ControlEventKind.EncoderClockwise ? "clockwise" :
        event.kind === ControlEventKind.EncoderCounterClockwise ? "counterClockwise" : undefined,
    }).catch((error) => this.broadcast("action.error", { actionId: binding.actionId, message: error instanceof Error ? error.message : String(error) }));
  }

  private cancelActiveVoiceControl(reason: string): void {
    const active = this.activeVoiceControl;
    if (!active) return;
    this.activeVoiceControl = undefined;
    this.broadcast("voice.control", {
      phase: "cancel",
      taskId: active.taskId,
      controlId: active.controlId,
      eventSequence: active.eventSequence,
      reason,
    });
  }

  private handleReasoningPress(event: ControlEvent, binding: Binding): void {
    if (event.pressed) {
      this.clearReasoningPress("replaced");
      const taskId = binding.taskId ?? this.taskState.selectedTaskId;
      let session!: ReasoningPressSession;
      session = {
        binding,
        taskId,
        pressedAtTick: event.deviceTick >>> 0,
        longPressFired: false,
        timer: setTimeout(() => {
          if (this.reasoningPress !== session) return;
          this.fireReasoningLongPress(session, 500);
        }, 500),
      };
      this.reasoningPress = session;
      this.broadcast("reasoning.press", {
        phase: "press",
        taskId,
        controlId: this.activeProfile().encoder.id,
        deviceTick: event.deviceTick,
        thresholdMs: 500,
      });
      return;
    }

    const session = this.reasoningPress;
    if (!session || session.binding.instanceId !== binding.instanceId) return;
    clearTimeout(session.timer);
    const durationMs = (event.deviceTick - session.pressedAtTick) >>> 0;
    if (!session.longPressFired && durationMs >= 500) this.fireReasoningLongPress(session, durationMs);
    if (!session.longPressFired) {
      const task = session.taskId ? this.taskState.tasks.find((candidate) => candidate.taskId === session.taskId) : undefined;
      this.broadcast("task.effort.confirmed", {
        taskId: session.taskId,
        effort: task?.effort,
        instanceId: binding.instanceId,
        durationMs,
      });
    }
    this.broadcast("reasoning.press", {
      phase: "release",
      taskId: session.taskId,
      controlId: this.activeProfile().encoder.id,
      deviceTick: event.deviceTick,
      durationMs,
      longPress: session.longPressFired,
    });
    this.reasoningPress = undefined;
  }

  private fireReasoningLongPress(session: ReasoningPressSession, durationMs: number): void {
    if (session.longPressFired) return;
    session.longPressFired = true;
    this.broadcast("app.foreground.requested", {
      taskId: session.taskId,
      instanceId: session.binding.instanceId,
      controlId: this.activeProfile().encoder.id,
      reason: "reasoning-long-press",
      durationMs,
    });
  }

  private clearReasoningPress(reason: string): void {
    const session = this.reasoningPress;
    if (!session) return;
    clearTimeout(session.timer);
    this.reasoningPress = undefined;
    this.broadcast("reasoning.press", {
      phase: "cancelled",
      taskId: session.taskId,
      controlId: this.activeProfile().encoder.id,
      reason,
    });
  }

  private ensureSixTaskSlots(): void {
    while (this.taskState.tasks.length < 6) {
      const slotIndex = this.nextSlotIndex();
      this.taskState.tasks.push({
        taskId: randomUUID(),
        slotIndex,
        title: `Agent ${slotIndex + 1}`,
        state: "unassigned",
        unread: false,
        selected: false,
        pinned: false,
        recencyAt: this.now().toISOString(),
        pendingApprovalCount: 0,
        pendingStructuredRequestCount: 0,
      });
    }
    if (!this.taskState.selectedTaskId && this.taskState.tasks[0]) {
      this.taskState.selectedTaskId = this.taskState.tasks[0].taskId;
      this.taskState.tasks[0].selected = true;
    }
  }

  private activeProfile(): KeyboardProfile {
    return this.transport.connection?.profile ?? q6ProAnsi;
  }

  private ensureDefaultBindings(profile: KeyboardProfile): void {
    // Revision zero is the untouched state written by the first public build.
    // A user-cleared layout has a later revision and must remain empty.
    if (this.bindingState.revision !== 0 || this.bindingState.bindings.length !== 0) return;
    const tasksBySlot = new Map(this.taskState.tasks.map((task) => [task.slotIndex, task]));
    const timestamp = this.now().toISOString();
    const templates = profile.profileId === "keychron-v1-max-ansi-knob" ? defaultV1MaxBindings : defaultQ6Bindings;
    const bindings = templates.flatMap((template): Binding[] => {
      const taskId = template.taskSlotIndex === undefined
        ? undefined
        : tasksBySlot.get(template.taskSlotIndex)?.taskId;
      if (template.taskSlotIndex !== undefined && !taskId) return [];
      return [{
        controlId: template.controlId,
        instanceId: template.instanceId,
        actionId: template.actionId,
        taskId,
        profileId: profile.profileId,
        layoutHash: profile.layoutHash,
        createdAt: timestamp,
        updatedAt: timestamp,
      }];
    });
    this.bindingState = { version: 1, revision: 1, bindings };
  }

  private createTask(title?: string): TaskSlot {
    const slotIndex = this.nextSlotIndex();
    const task: TaskSlot = {
      taskId: randomUUID(),
      slotIndex,
      title: title?.trim() || `Agent ${slotIndex + 1}`,
      state: "unassigned",
      unread: false,
      selected: false,
      pinned: false,
      recencyAt: this.now().toISOString(),
      pendingApprovalCount: 0,
      pendingStructuredRequestCount: 0,
    };
    this.taskState.tasks.push(task);
    this.persistTasks();
    this.broadcast("task.changed", task);
    return task;
  }

  private nextSlotIndex(): number {
    return this.taskState.tasks.reduce((maximum, task) => Math.max(maximum, task.slotIndex), -1) + 1;
  }

  private selectTask(taskId: string): TaskSlot {
    const task = this.requireTask(taskId);
    this.taskState.selectedTaskId = taskId;
    for (const candidate of this.taskState.tasks) candidate.selected = candidate.taskId === taskId;
    task.unread = false;
    if (task.state === "completeUnread") this.setTaskLightState(task, "idle");
    task.recencyAt = this.now().toISOString();
    this.persistTasks();
    this.renderTaskAtmosphere();
    this.renderOverlays();
    this.broadcast("task.selected", task);
    return task;
  }

  private updateTask(params: Record<string, unknown>): TaskSlot {
    const task = this.requireTask(String(params.taskId ?? ""));
    if (typeof params.pinned !== "boolean") throw new Error("task.update requires boolean pinned");
    task.pinned = params.pinned;
    this.persistTasks();
    this.broadcast("task.changed", task);
    return task;
  }

  private reorderTasks(value: unknown): TaskSlot[] {
    if (!Array.isArray(value) || !value.every((taskId) => typeof taskId === "string")) {
      throw new Error("task.reorder requires taskIds");
    }
    const taskIds = value as string[];
    const expected = new Set(this.taskState.tasks.map((task) => task.taskId));
    const received = new Set(taskIds);
    if (taskIds.length !== this.taskState.tasks.length || received.size !== taskIds.length ||
      received.size !== expected.size || [...received].some((taskId) => !expected.has(taskId))) {
      throw new Error("task.reorder taskIds must be the unique complete Arkey task set");
    }
    const byId = new Map(this.taskState.tasks.map((task) => [task.taskId, task]));
    this.taskState.tasks = taskIds.map((taskId) => byId.get(taskId)!);
    this.persistTasks();
    this.broadcast("task.reordered", { taskIds, tasks: this.taskState.tasks });
    return this.taskState.tasks;
  }

  private async sendComposer(text: string, requestedTaskId?: string, attachments?: unknown): Promise<TaskSlot> {
    const input: Array<Record<string, unknown>> = [];
    if (text.trim()) input.push({ type: "text", text });
    input.push(...localImageInputs(attachments));
    if (!input.length) throw new Error("Composer text and attachments are empty");
    return this.sendTaskInput(input, requestedTaskId, true, "composer.sent");
  }

  private async sendTaskInput(input: Array<Record<string, unknown>>, requestedTaskId: string | undefined, allowSteer: boolean, event: string): Promise<TaskSlot> {
    await this.ensureAppServer();
    const task = this.requireTask(requestedTaskId ?? this.taskState.selectedTaskId ?? "");
    if (!task.threadId) {
      const started = await this.appServer.request<Record<string, unknown>>("thread/start", {
        cwd: this.settings.workspaceRoot,
        model: task.model ?? this.settings.selectedModel ?? null,
        serviceTier: task.serviceTier ?? null,
      });
      const thread = asObject(started.thread);
      if (typeof thread.id !== "string") throw new Error("App Server thread/start returned no thread id");
      task.threadId = thread.id;
      this.setTaskLightState(task, "idle");
    }
    let response: Record<string, unknown>;
    if (task.activeTurnId) {
      if (!allowSteer) throw new Error("This action requires the selected task to be idle");
      response = await this.appServer.request<Record<string, unknown>>("turn/steer", {
        threadId: task.threadId,
        expectedTurnId: task.activeTurnId,
        input,
      });
    } else {
      const collaborationMode = this.nextCollaborationModes.get(task.taskId);
      const turnParams: Record<string, unknown> = {
        threadId: task.threadId,
        input,
        model: task.model ?? this.settings.selectedModel ?? null,
        serviceTier: task.serviceTier ?? null,
        effort: task.effort ?? null,
      };
      if (collaborationMode) turnParams.collaborationMode = collaborationMode;
      response = await this.appServer.request<Record<string, unknown>>("turn/start", turnParams);
      if (collaborationMode) this.nextCollaborationModes.delete(task.taskId);
    }
    const turn = asObject(response.turn);
    if (typeof turn.id === "string") task.activeTurnId = turn.id;
    this.setTaskLightState(task, "working");
    task.unread = false;
    task.recencyAt = this.now().toISOString();
    this.persistTasks();
    this.renderTaskAtmosphere();
    this.renderOverlays();
    this.broadcast(event, { taskId: task.taskId, threadId: task.threadId, turnId: task.activeTurnId });
    return task;
  }

  private async forkTask(taskId: string): Promise<TaskSlot> {
    await this.ensureAppServer();
    const source = this.requireTask(taskId);
    if (!source.threadId) throw new Error("Cannot fork an unassigned task");
    if (source.activeTurnId || source.state === "working") throw new Error("Continue in new task is available only while idle");
    const response = await this.appServer.request<Record<string, unknown>>("thread/fork", { threadId: source.threadId });
    const thread = asObject(response.thread);
    if (typeof thread.id !== "string") throw new Error("App Server thread/fork returned no thread id");
    const target = this.createTask(`${source.title} continuation`);
    target.threadId = thread.id;
    this.setTaskLightState(target, "idle");
    target.model = source.model;
    target.effort = source.effort;
    target.serviceTier = source.serviceTier;
    this.persistTasks();
    this.selectTask(target.taskId);
    return target;
  }

  private async importTask(threadId?: string): Promise<unknown> {
    await this.ensureAppServer();
    if (!threadId) {
      const response = await this.appServer.request<Record<string, unknown>>("thread/list", {
        cwd: this.settings.workspaceRoot,
        sourceKinds: ["cli", "vscode"],
        sortKey: "recency_at",
        sortDirection: "desc",
        limit: 50,
      });
      const managed = new Set(this.taskState.tasks.flatMap((task) => task.threadId ? [task.threadId] : []));
      const data = Array.isArray(response.data) ? response.data.filter((thread) => {
        const value = asObject(thread);
        return typeof value.id === "string" && !managed.has(value.id);
      }) : [];
      return { candidates: data, explicitSelectionRequired: true };
    }
    if (this.taskForThread(threadId)) throw new Error("Thread is already managed by Arkey");
    const response = await this.appServer.request<Record<string, unknown>>("thread/resume", { threadId });
    const thread = asObject(response.thread);
    if (typeof thread.id !== "string") throw new Error("App Server thread/resume returned no thread id");
    const task = this.createTask(typeof thread.name === "string" ? thread.name : "Imported Agent");
    task.threadId = thread.id;
    this.setTaskLightState(task, "idle");
    this.persistTasks();
    this.selectTask(task.taskId);
    this.broadcast("task.imported", task);
    return task;
  }

  private async triggerAction(actionId: string, params: Record<string, unknown>): Promise<unknown> {
    const action = this.actions.find((candidate) => candidate.actionId === actionId);
    if (!action) throw new Error(`Unknown action ${actionId}`);
    if (!action.enabled) throw new Error(`Action ${actionId} is disabled: ${action.disabledReason ?? "not currently available"}`);
    const taskId = typeof params.taskId === "string" ? params.taskId : this.taskState.selectedTaskId;
    switch (actionId) {
      case "task_agent":
        if (!taskId) throw new Error("Agent key has no task");
        {
          const task = this.selectTask(taskId);
          if (params.source === "hardware" && typeof params.instanceId === "string") {
            const timestamp = this.now().getTime();
            const previous = this.lastHardwareTaskClick.get(params.instanceId);
            if (previous !== undefined && timestamp - previous <= 350) {
              this.lastHardwareTaskClick.delete(params.instanceId);
              this.broadcast("app.foreground.requested", { taskId, instanceId: params.instanceId });
            } else {
              this.lastHardwareTaskClick.set(params.instanceId, timestamp);
            }
          }
          return task;
        }
      case "send":
        if (params.source === "hardware" && (typeof params.text !== "string" || !params.text.trim()) &&
          (!Array.isArray(params.attachments) || params.attachments.length === 0)) {
          this.broadcast("composer.send.requested", { taskId, source: "hardware", instanceId: params.instanceId });
          return { requested: true, taskId };
        }
        return this.sendComposer(String(params.text ?? ""), taskId, params.attachments);
      case "approve":
        return this.resolveApproval(taskId, "accept");
      case "decline":
        return this.resolveApproval(taskId, "decline");
      case "continue":
        if (!taskId) throw new Error("No selected task");
        return this.forkTask(taskId);
      case "fast": {
        await this.ensureAppServer();
        const task = this.requireTask(taskId ?? "");
        const tier = this.appServer.fastTier(task.model ?? this.settings.selectedModel);
        if (!tier) throw new Error("The selected model does not expose a Fast service tier");
        task.serviceTier = tier;
        this.persistTasks();
        this.broadcast("task.fast.changed", { taskId: task.taskId, serviceTier: tier });
        return task;
      }
      case "reasoning": {
        await this.ensureAppServer();
        const task = this.requireTask(taskId ?? "");
        const efforts = this.appServer.reasoningEfforts(task.model ?? this.settings.selectedModel);
        if (!efforts.length) throw new Error("The selected model does not expose reasoning efforts");
        const current = Math.max(-1, efforts.indexOf(task.effort ?? this.appServer.defaultEffort(task.model) ?? ""));
        const direction = params.direction === "counterClockwise" ? -1 : 1;
        task.effort = efforts[(current + direction + efforts.length) % efforts.length];
        this.persistTasks();
        this.broadcast("task.effort.changed", { taskId: task.taskId, effort: task.effort, efforts });
        return task;
      }
      case "ptt":
        this.broadcast("voice.toggle.requested", { taskId });
        return { focused: true };
      case "review": {
        if (params.source === "hardware" || params.confirmed !== true) {
          this.broadcast("action.ui.requested", { actionId, taskId });
          return { focused: true, confirmationRequired: true };
        }
        await this.ensureAppServer();
        const task = this.requireTask(taskId ?? "");
        if (!task.threadId) throw new Error("Review requires an assigned App Server task");
        const target = reviewTarget(params.reviewTarget);
        const response = await this.appServer.request("review/start", { threadId: task.threadId, target });
        this.broadcast("review.started", { taskId: task.taskId, target });
        return response;
      }
      case "skill": {
        if (params.source === "hardware" || params.confirmed !== true) {
          this.broadcast("action.ui.requested", { actionId, taskId });
          return { focused: true, confirmationRequired: true };
        }
        const skill = explicitSkillInput(params.skillInput);
        return this.sendTaskInput([{ type: "skill", name: skill.name, path: skill.path }], taskId, false, "skill.started");
      }
      case "plan": {
        const task = this.requireTask(taskId ?? "");
        const collaborationMode = this.planModeForTask(task);
        this.nextCollaborationModes.set(task.taskId, collaborationMode);
        this.broadcast("task.plan.changed", { taskId: task.taskId, enabled: true, appliesTo: "nextTurn", collaborationMode });
        return { taskId: task.taskId, appliesTo: "nextTurn", collaborationMode };
      }
      case "git_commit":
      case "create_pr":
      case "navigate_back":
      case "navigate_forward":
      case "toggle_sidebar":
      case "terminal":
      case "browser":
      case "attach":
      case "cancel":
        this.broadcast("action.ui.requested", { actionId, taskId });
        return { focused: true };
      default:
        throw new Error(`Unsupported action ${actionId}`);
    }
  }

  private resolveApproval(taskId: string | undefined, decision: "accept" | "decline"): Record<string, unknown> {
    const task = this.requireTask(taskId ?? "");
    if (!task.threadId) throw new Error("Selected task has no App Server thread");
    const approval = this.requestQueues.get(task.threadId)?.[0];
    if (!approval) throw new Error("Selected task has no pending approval");
    if (isStructuredRequestMethod(approval.method)) {
      this.broadcast("approval.ui.required", { taskId: task.taskId, requestId: approval.requestId, method: approval.method, params: approval.params });
      return { focused: true, structured: true, requestId: approval.requestId };
    }
    if (!isBinaryApprovalMethod(approval.method)) throw new Error("Queue head is not a binary approval");
    if (approval.responded) throw new Error("Approval response is awaiting serverRequest/resolved");
    this.appServer.respond(approval.requestId, { decision });
    approval.responded = true;
    this.broadcast("approval.responded", { taskId: task.taskId, requestId: approval.requestId, decision });
    return { requestId: approval.requestId, decision, pendingResolution: true };
  }

  private respondStructuredApproval(params: Record<string, unknown>): Record<string, unknown> {
    const requestId = params.requestId;
    if (typeof requestId !== "string" && typeof requestId !== "number") throw new Error("approval.respond requires requestId");
    if (!params.result || typeof params.result !== "object" || Array.isArray(params.result)) throw new Error("approval.respond requires an explicit structured result");
    for (const [threadId, queue] of this.requestQueues) {
      const request = queue[0];
      if (!request || request.requestId !== requestId || !isStructuredRequestMethod(request.method)) continue;
      if (request.responded) throw new Error("Structured response is awaiting serverRequest/resolved");
      this.appServer.respond(requestId, params.result);
      request.responded = true;
      this.broadcast("approval.responded", { taskId: this.taskForThread(threadId)?.taskId, requestId, structured: true });
      return { requestId, pendingResolution: true };
    }
    throw new Error("Structured approval request is not pending");
  }

  private handleAppServerRequest(request: JsonRpcRequest): void {
    const params = asObject(request.params);
    const threadId = typeof params.threadId === "string" ? params.threadId : undefined;
    if (!threadId) {
      this.broadcast("appserver.request.unrouted", { method: request.method, requestId: request.id });
      return;
    }
    const task = this.taskForThread(threadId);
    if (!task) {
      this.appServer.respondError(request.id, -32600, "Thread is not managed by Arkey");
      return;
    }
    if (!isBinaryApprovalMethod(request.method) && !isStructuredRequestMethod(request.method)) {
      this.broadcast("appserver.request.unhandled", { taskId: task.taskId, method: request.method, requestId: request.id });
      return;
    }
    const pending: PendingApproval = { requestId: request.id, method: request.method, params, responded: false };
    const queue = this.requestQueues.get(threadId) ?? [];
    queue.push(pending);
    this.requestQueues.set(threadId, queue);
    this.updateRequestCounts(task);
    this.setTaskLightState(task, "requiresInput");
    this.persistTasks();
    this.renderTaskAtmosphere();
    this.renderOverlays();
    if (queue.length === 1) this.announceApprovalHead(task, pending);
    this.broadcast("task.changed", task);
  }

  private announceApprovalHead(task: TaskSlot, request: PendingApproval): void {
    if (isStructuredRequestMethod(request.method)) {
      this.broadcast("approval.ui.required", {
        taskId: task.taskId,
        requestId: request.requestId,
        method: request.method,
        params: request.params,
      });
    }
    this.broadcast("approval.requested", {
      taskId: task.taskId,
      requestId: request.requestId,
      method: request.method,
      params: request.params,
      structured: !isBinaryApprovalMethod(request.method),
      reason: typeof request.params.reason === "string" ? request.params.reason : undefined,
      command: typeof request.params.command === "string" ? request.params.command : undefined,
      cwd: typeof request.params.cwd === "string" ? request.params.cwd : undefined,
    });
  }

  private handleAppServerNotification(notification: JsonRpcNotification): void {
    const params = asObject(notification.params);
    if (notification.method === "account/login/completed") {
      if (params.success === true && (params.error === null || params.error === undefined)) {
        this.stopAccountPoll();
        void this.refreshAccount("login-completed");
      } else {
        this.stopAccountPoll();
        this.broadcast("account.login.failed", {
          loginId: typeof params.loginId === "string" ? params.loginId : undefined,
          error: typeof params.error === "string" ? params.error : "ChatGPT login did not complete successfully",
        });
      }
    } else if (notification.method === "account/updated") {
      void this.refreshAccount("account-updated");
    }
    const threadId = typeof params.threadId === "string" ? params.threadId : undefined;
    const task = threadId ? this.taskForThread(threadId) : undefined;
    if (notification.method === "serverRequest/resolved" && threadId) {
      const requestId = params.requestId;
      this.removeResolvedRequest(threadId, requestId as JsonRpcId);
      if (task) this.refreshTaskInputState(task);
    } else if (task && notification.method === "thread/status/changed") {
      const status = asObject(params.status);
      if (status.type === "idle") this.refreshTaskInputState(task);
      else if (status.type === "systemError") this.setTaskLightState(task, "error");
      else if (status.type === "notLoaded") this.setTaskLightState(task, "offline");
      else if (status.type === "active") {
        const flags = Array.isArray(status.activeFlags) ? status.activeFlags : [];
        this.setTaskLightState(task, flags.includes("waitingOnApproval") || flags.includes("waitingOnUserInput") ? "requiresInput" : "working");
      }
    } else if (task && notification.method === "turn/started") {
      const turn = asObject(params.turn);
      task.activeTurnId = typeof turn.id === "string" ? turn.id : task.activeTurnId;
      this.setTaskLightState(task, "working");
      task.unread = false;
    } else if (task && notification.method === "turn/completed") {
      const turn = asObject(params.turn);
      task.activeTurnId = undefined;
      if (turn.status === "completed") {
        task.unread = true;
        this.setTaskLightState(task, "completeUnread");
      } else if (turn.status === "failed") {
        this.setTaskLightState(task, "error");
      } else {
        this.setTaskLightState(task, "idle");
      }
    } else if (task && notification.method === "error" && params.willRetry !== true) {
      const error = asObject(params.error);
      task.lastError = typeof error.message === "string" ? error.message : "Codex App Server error";
      this.setTaskLightState(task, "error");
    }
    if (task) {
      task.recencyAt = this.now().toISOString();
      this.persistTasks();
      this.renderTaskAtmosphere();
      this.renderOverlays();
      this.broadcast("task.changed", task);
    }
    this.broadcast("appserver.notification", notification);
  }

  private async refreshAccount(reason: string): Promise<void> {
    try {
      const account = await this.appServer.request<Record<string, unknown>>("account/read", { refreshToken: false });
      this.appServer.account = account;
      const authenticated = this.isAccountAuthenticated(account);
      if (authenticated) this.stopAccountPoll();
      this.broadcast("account.changed", { reason, authenticated, account: account.account ?? null });
    } catch (error) {
      this.broadcast("account.error", { reason, message: error instanceof Error ? error.message : String(error) });
    }
  }

  private async startAccountLogin(): Promise<unknown> {
    const result = await this.appServer.request<Record<string, unknown>>("account/login/start", {
      type: "chatgptDeviceCode",
    });
    this.startAccountPoll();
    return result;
  }

  private startAccountPoll(): void {
    this.stopAccountPoll();
    let attempts = 0;
    this.accountPoll = setInterval(() => {
      attempts += 1;
      void this.refreshAccount(`login-poll-${attempts}`);
      if (attempts >= 80) {
        this.stopAccountPoll();
        this.broadcast("account.login.failed", { error: "ChatGPT login timed out" });
      }
    }, 3000);
    this.accountPoll.unref?.();
  }

  private stopAccountPoll(): void {
    if (!this.accountPoll) return;
    clearInterval(this.accountPoll);
    this.accountPoll = undefined;
  }

  private isAccountAuthenticated(account: Record<string, unknown> | undefined): boolean {
    return !!account && account.account !== null && account.account !== undefined;
  }

  private removeResolvedRequest(threadId: string, requestId: JsonRpcId): void {
    const queue = this.requestQueues.get(threadId) ?? [];
    const wasHead = queue[0]?.requestId === requestId;
    const next = queue.filter((request) => request.requestId !== requestId);
    if (next.length) this.requestQueues.set(threadId, next);
    else this.requestQueues.delete(threadId);
    const task = this.taskForThread(threadId);
    if (task) {
      this.updateRequestCounts(task);
      if (wasHead && next[0]) this.announceApprovalHead(task, next[0]);
    }
  }

  private refreshTaskInputState(task: TaskSlot): void {
    if (!task.threadId) return;
    this.updateRequestCounts(task);
    if (task.pendingApprovalCount || task.pendingStructuredRequestCount) this.setTaskLightState(task, "requiresInput");
    else this.setTaskLightState(task, task.activeTurnId ? "working" : task.unread ? "completeUnread" : "idle");
  }

  private updateRequestCounts(task: TaskSlot): void {
    const queue = task.threadId ? this.requestQueues.get(task.threadId) ?? [] : [];
    task.pendingApprovalCount = queue.filter((request) => isBinaryApprovalMethod(request.method)).length;
    task.pendingStructuredRequestCount = queue.filter((request) => isStructuredRequestMethod(request.method)).length;
  }

  private invalidatePendingRequests(reason: string): void {
    if (!this.requestQueues.size) return;
    const invalidated = [...this.requestQueues.values()].flat().map((request) => request.requestId);
    this.requestQueues.clear();
    for (const task of this.taskState.tasks) {
      if (!task.pendingApprovalCount && !task.pendingStructuredRequestCount) continue;
      task.pendingApprovalCount = 0;
      task.pendingStructuredRequestCount = 0;
      this.setTaskLightState(task, task.activeTurnId ? "working" : task.unread ? "completeUnread" : "offline");
      this.broadcast("task.changed", task);
    }
    this.persistTasks();
    this.renderTaskAtmosphere();
    this.renderOverlays();
    this.broadcast("approval.invalidated", { reason, requestIds: invalidated });
  }

  private setTaskLightState(task: TaskSlot, state: TaskLightState): void {
    if (task.state === state) return;
    const previous = this.taskEntryTransients.get(task.taskId);
    if (previous) {
      clearTimeout(previous.timer);
      this.taskEntryTransients.delete(task.taskId);
    }
    task.state = state;
    const definition = effectCatalog.semantics[state];
    if (!definition.entryPrimitive) return;
    const durationMs = definition.entryDurationMs ?? (definition.entryPrimitive === "doublePulse" ? 900 : 600);
    const steady = semanticEffect(0, state, true);
    const effect: EffectSpec = {
      ...steady,
      effect: effectCatalog.primitives[definition.entryPrimitive],
      durationMs,
    };
    const timer = setTimeout(() => {
      this.taskEntryTransients.delete(task.taskId);
      this.renderOverlays();
      this.broadcast("lighting.task.entry.completed", { taskId: task.taskId, state });
    }, durationMs);
    this.taskEntryTransients.set(task.taskId, { state, effect, timer });
    this.broadcast("lighting.task.entry", { taskId: task.taskId, state, effect, durationMs });
  }

  private startBindingTransient(controlId: string, kind: "success" | "replace"): void {
    const targetControlId = this.bindingTransientTargetControlId(controlId);
    const previous = this.controlTransients.get(targetControlId);
    if (previous) clearTimeout(previous.timer);
    const effect: EffectSpec = {
      led: 0,
      effect: EffectPrimitive.PressFlash,
      hue: kind === "replace" ? 18 : 96,
      saturation: 255,
      value: 255,
      speed: 140,
      phase: 0,
      durationMs: 600,
      flags: 0,
    };
    const timer = setTimeout(() => {
      this.controlTransients.delete(targetControlId);
      this.renderOverlays();
    }, 600);
    this.controlTransients.set(targetControlId, { effect, timer });
    this.renderOverlays();
    this.broadcast("lighting.binding.transient", { controlId, targetControlId, kind, effect, durationMs: 600 });
  }

  private bindingTransientTargetControlId(controlId: string): string {
    const profile = this.activeProfile();
    const direct = profile.controls.find((control) => control.id === controlId && control.ledIndex !== null);
    if (direct) return direct.id;
    const selectedTaskId = this.taskState.selectedTaskId;
    const selectedTaskKey = this.bindingState.bindings.find((binding) => {
      if (!this.isBindingCurrent(binding) || binding.actionId !== "task_agent" || binding.taskId !== selectedTaskId) return false;
      return profile.controls.some((control) => control.id === binding.controlId && control.ledIndex !== null);
    });
    if (selectedTaskKey) return selectedTaskKey.controlId;
    const encoderCenterX = profile.encoder.frame.x + profile.encoder.frame.width / 2;
    const encoderCenterY = profile.encoder.frame.y + profile.encoder.frame.height / 2;
    return profile.controls
      .filter((control) => control.ledIndex !== null)
      .map((control) => ({
        control,
        distance: Math.hypot(
          control.frame.x + control.frame.width / 2 - encoderCenterX,
          control.frame.y + control.frame.height / 2 - encoderCenterY,
        ),
      }))
      .sort((left, right) => left.distance - right.distance)[0]?.control.id ?? profile.controls[0].id;
  }

  private renderTaskAtmosphere(): void {
    const states = this.taskState.tasks.map((task) => {
      if (task.state === "error") return AgentState.Error;
      if (task.state === "working") return AgentState.Thinking;
      if (task.state === "requiresInput") return AgentState.Tool;
      if (task.state === "completeUnread") return AgentState.Complete;
      return AgentState.Idle;
    });
    const merged = mergeStates(states);
    if (merged === AgentState.Idle) this.sourceStates.delete("appserver");
    else this.sourceStates.set("appserver", merged);
    this.setState(mergeStates([...this.sourceStates.values()]));
  }

  private renderOverlays(): void {
    if (!this.transport.connection?.fullControl || !this.settings.hardwareSync || this.lightingTimer) return;
    const profile = this.activeProfile();
    const effects: EffectSpec[] = [];
    const renderedTransients = new Set<string>();
    const selected = this.taskState.selectedTaskId;
    for (const binding of this.bindingState.bindings) {
      if (!this.isBindingCurrent(binding)) continue;
      const control = profile.controls.find((candidate) => candidate.id === binding.controlId);
      if (!control || control.ledIndex === null) continue;
      const bindingTransient = this.controlTransients.get(binding.controlId);
      if (bindingTransient) {
        effects.push({ ...bindingTransient.effect, led: control.ledIndex });
        renderedTransients.add(binding.controlId);
        continue;
      }
      const voiceEffect = this.voiceEffectForBinding(binding, control.ledIndex);
      if (voiceEffect) {
        effects.push(voiceEffect);
        continue;
      }
      let state: TaskLightState = "idle";
      if (binding.actionId === "task_agent") {
        state = binding.taskId ? this.taskState.tasks.find((task) => task.taskId === binding.taskId)?.state ?? "unassigned" : "unassigned";
      } else if (binding.actionId === "approve" || binding.actionId === "decline") {
        const task = this.taskState.tasks.find((candidate) => candidate.taskId === selected);
        state = task?.pendingApprovalCount ? "requiresInput" : "unassigned";
      } else if (binding.actionId === "send") {
        state = "idle";
      } else {
        state = "idle";
      }
      const isSelected = binding.taskId !== undefined && binding.taskId === selected;
      const entry = binding.taskId ? this.taskEntryTransients.get(binding.taskId) : undefined;
      effects.push(entry ? { ...entry.effect, led: control.ledIndex } : effectForTaskState(control.ledIndex, state, isSelected));
    }
    for (const [controlId, transient] of this.controlTransients) {
      if (renderedTransients.has(controlId)) continue;
      const control = profile.controls.find((candidate) => candidate.id === controlId);
      if (control?.ledIndex !== null && control?.ledIndex !== undefined) effects.push({ ...transient.effect, led: control.ledIndex });
    }
    this.sendEffects(effects, this.settings.atmosphereMix);
  }

  private restoreHardwareOverlays(): void {
    if (!this.transport.connection?.fullControl || !this.settings.hardwareSync) return;
    if (this.activeLightingPreview) {
      this.sendEffects(this.activeLightingPreview.effects, this.activeLightingPreview.atmosphereMix, this.activeLightingPreview.epoch);
      return;
    }
    this.renderOverlays();
  }

  private startLightingPreview(params: Record<string, unknown>): Record<string, unknown> {
    this.stopLightingPreview(false);
    const durationMs = Math.min(30_000, Math.max(250, numberParam(params.durationMs, 5000)));
    const mix = Math.min(1, Math.max(0, numberParam(params.atmosphereMix, this.settings.atmosphereMix)));
    const epoch = Math.round(numberParam(params.epoch, (this.overlayEpoch + 1) & 0xffff)) & 0xffff;
    const seed = Math.round(numberParam(params.seed, Math.floor(Math.random() * 0x1_0000_0000))) >>> 0;
    const rawEffects = Array.isArray(params.effects) ? params.effects : [];
    const profile = this.activeProfile();
    const effects = rawEffects.map((effect, index) => parseEffectSpec(effect, (seed + index * 53) & 0xff, profile.ledCount));
    if (!effects.length && typeof params.controlId === "string") {
      const control = profile.controls.find((candidate) => candidate.id === params.controlId);
      if (control?.ledIndex !== null && control?.ledIndex !== undefined) {
        effects.push(effectForTaskState(control.ledIndex, String(params.state ?? "working") as TaskLightState, true));
      }
    }
    if (!effects.length) throw new Error("lighting.preview requires effects or a lit controlId");
    this.activeLightingPreview = { effects, atmosphereMix: mix, epoch, seed };
    const hardware = this.transport.connection?.fullControl === true && this.settings.hardwareSync;
    if (hardware) this.sendEffects(effects, mix, epoch);
    this.lightingTimer = setTimeout(() => this.stopLightingPreview(true), durationMs);
    const preview = { previewId: randomUUID(), effects, durationMs, atmosphereMix: mix, epoch, seed, startedAt: this.now().toISOString(), hardware };
    this.broadcast("lighting.preview.started", preview);
    return preview;
  }

  private stopLightingPreview(notify: boolean, reason?: string): void {
    if (!this.lightingTimer) return;
    clearTimeout(this.lightingTimer);
    this.lightingTimer = undefined;
    this.activeLightingPreview = undefined;
    if (this.transport.connection?.fullControl) this.transport.send(Opcode.ClearKeyEffects, encodeClearKeyEffects());
    this.renderOverlays();
    if (notify) this.broadcast("lighting.preview.stopped", { reason });
  }

  private sendEffects(effects: EffectSpec[], atmosphereMix = DEFAULT_ATMOSPHERE_MIX, epoch?: number): boolean {
    if (!this.transport.connection?.fullControl) return false;
    this.overlayEpoch = epoch === undefined ? (this.overlayEpoch + 1) & 0xffff : epoch & 0xffff;
    return encodeSetKeyEffects(effects, this.bindingState.revision, this.overlayEpoch, atmosphereMix)
      .every((payload) => this.transport.send(Opcode.SetKeyEffects, payload));
  }

  private sortedTasks(): TaskSlot[] {
    const priority: Record<TaskLightState, number> = {
      requiresInput: 6,
      completeUnread: 5,
      working: 4,
      error: 3,
      idle: 2,
      offline: 1,
      unassigned: 0,
    };
    const tasks = [...this.taskState.tasks];
    if (this.settings.taskSort === "custom") return tasks;
    return tasks.sort((left, right) => {
      if (this.settings.taskSort === "pinned" && left.pinned !== right.pinned) return left.pinned ? -1 : 1;
      if (this.settings.taskSort === "priority" && priority[left.state] !== priority[right.state]) return priority[right.state] - priority[left.state];
      return Date.parse(right.recencyAt) - Date.parse(left.recencyAt);
    });
  }

  private taskForThread(threadId: string): TaskSlot | undefined {
    return this.taskState.tasks.find((task) => task.threadId === threadId);
  }

  private isBindingCurrent(binding: Binding): boolean {
    const profile = this.activeProfile();
    return binding.profileId === profile.profileId && binding.layoutHash === profile.layoutHash;
  }

  private canonicalBindingControlId(controlId: string, profile = this.activeProfile()): string {
    return controlId === profile.encoder.pressControlId ? profile.encoder.id : controlId;
  }

  private hardwareBindingsActive(): boolean {
    return this.transport.connection?.fullControl === true &&
      this.lastFirmwareArmStatus === AckStatus.Ok &&
      this.acknowledgedBindingRevision === this.bindingState.revision;
  }

  private bindingView(): Record<string, unknown> {
    const hardwareAck = this.hardwareBindingsActive();
    return {
      ...this.bindingState,
      hardwareAck,
      fullControl: this.transport.connection?.fullControl ?? false,
      bindings: this.bindingState.bindings.map((binding) => {
        const compatible = this.isBindingCurrent(binding);
        return {
          ...binding,
          active: compatible && hardwareAck,
          pending: compatible && !hardwareAck,
          incompatible: !compatible,
        };
      }),
    };
  }

  private invalidateHardwareBindingAcknowledgement(reason: string, revision?: number): void {
    if (revision !== undefined &&
      this.acknowledgedBindingRevision !== undefined &&
      revision !== this.acknowledgedBindingRevision &&
      revision !== this.bindingState.revision) return;
    const acknowledgedRevision = this.acknowledgedBindingRevision;
    this.acknowledgedBindingRevision = undefined;
    if (acknowledgedRevision === undefined) return;
    this.broadcast("binding.deactivated", { reason, revision: acknowledgedRevision });
    this.broadcast("binding.changed", this.bindingView());
  }

  private requireTask(taskId: string): TaskSlot {
    const task = this.taskState.tasks.find((candidate) => candidate.taskId === taskId);
    if (!task) throw new Error(`Unknown Arkey task ${taskId || "<none>"}`);
    return task;
  }

  private persistTasks(): void {
    this.stores.tasks.write(this.taskState);
  }

  private async ensureAppServer(): Promise<void> {
    if (this.appServerState === "ready") return;
    await this.appServer.start();
  }

  private async probePlanCapability(): Promise<void> {
    try {
      const response = await this.appServer.request<Record<string, unknown>>("collaborationMode/list", {});
      if (this.appServerState !== "ready") return;
      const masks = Array.isArray(response.data) ? response.data.map(asObject) : [];
      const mask = masks.find((candidate) =>
        candidate.mode === "plan" || (candidate.mode == null && typeof candidate.name === "string" && candidate.name.toLowerCase() === "plan")
      );
      if (!mask || typeof mask.name !== "string") {
        this.setPlanCapability(undefined);
        this.broadcast("appserver.capability", { capability: "plan", enabled: false });
        return;
      }
      const preset = {
        name: mask.name,
        mode: "plan" as const,
        model: typeof mask.model === "string" ? mask.model : undefined,
        reasoningEffort: typeof mask.reasoning_effort === "string" ? mask.reasoning_effort : null,
      };
      this.setPlanCapability(preset);
      this.broadcast("appserver.capability", { capability: "plan", enabled: true, preset });
    } catch (error) {
      if (this.appServerState !== "ready") return;
      this.setPlanCapability(undefined);
      this.broadcast("appserver.capability", {
        capability: "plan",
        enabled: false,
        reason: error instanceof Error ? error.message : String(error),
      });
    }
  }

  private setPlanCapability(preset: typeof this.planPreset): void {
    const wasEnabled = this.planPreset !== undefined;
    this.planPreset = preset;
    if (!preset) this.nextCollaborationModes.clear();
    this.actions = this.actions.map((action) => action.actionId === "plan" ? {
      ...action,
      enabled: preset !== undefined,
      disabledReason: preset ? undefined : "Requires collaborationMode/list support",
    } : action);
    if (wasEnabled !== (preset !== undefined)) this.broadcast("actions.changed", this.actions);
  }

  private planModeForTask(task: TaskSlot): Record<string, unknown> {
    const preset = this.planPreset;
    if (!preset) throw new Error("Plan is unavailable because collaborationMode/list exposed no Plan preset");
    const model = preset.model ?? task.model ?? this.settings.selectedModel ??
      this.appServer.models.find((candidate) => candidate.isDefault)?.model ?? this.appServer.models[0]?.model;
    if (!model) throw new Error("Plan preset requires a model, but no model is available");
    return {
      mode: "plan",
      settings: {
        model,
        reasoning_effort: preset.reasoningEffort ?? task.effort ?? this.appServer.defaultEffort(model) ?? null,
        developer_instructions: null,
      },
    };
  }

  private async resumeManagedTasks(): Promise<void> {
    for (const task of this.taskState.tasks) {
      if (!task.threadId) continue;
      try {
        await this.appServer.request("thread/resume", { threadId: task.threadId });
        if (task.state === "offline") this.setTaskLightState(task, task.unread ? "completeUnread" : "idle");
      } catch (error) {
        this.setTaskLightState(task, "offline");
        task.lastError = error instanceof Error ? error.message : String(error);
      }
    }
    this.persistTasks();
    this.renderTaskAtmosphere();
    this.renderOverlays();
    this.broadcast("task.resumed", { tasks: this.sortedTasks() });
  }

  private runtimeEvent<T>(event: string, data: T): RuntimeEvent<T> {
    return {
      version: 1,
      event,
      sequence: ++this.eventSequence,
      timestamp: this.now().toISOString(),
      data,
    };
  }

  private broadcast<T>(event: string, data: T): void {
    const value = this.runtimeEvent(event, data);
    this.emit("runtime", value);
    const line = `${JSON.stringify(value)}\n`;
    for (const observer of this.observers) {
      if (!observer.destroyed) observer.write(line);
    }
  }

  async stop(): Promise<void> {
    if (this.heartbeat) clearInterval(this.heartbeat);
    if (this.randomTyping) clearInterval(this.randomTyping);
    if (this.voiceWave) clearInterval(this.voiceWave);
    if (this.textTimer) clearInterval(this.textTimer);
    if (this.testTimer) clearTimeout(this.testTimer);
    if (this.lightingTimer) clearTimeout(this.lightingTimer);
    this.stopAccountPoll();
    for (const transient of this.taskEntryTransients.values()) clearTimeout(transient.timer);
    for (const transient of this.controlTransients.values()) clearTimeout(transient.timer);
    this.taskEntryTransients.clear();
    this.controlTransients.clear();
    this.activeLightingPreview = undefined;
    this.stopCapture(false);
    this.capturedPress = undefined;
    this.clearReasoningPress("daemon-stopped");
    this.cancelActiveVoiceControl("daemon-stopped");
    for (const waiters of this.pendingBindingAcks.values()) {
      for (const pending of waiters) {
        clearTimeout(pending.timer);
        pending.resolve(false);
      }
    }
    this.pendingBindingAcks.clear();
    this.transport.send(Opcode.Restore);
    this.transport.close();
    await this.appServer.stop();
    for (const observer of this.observers) observer.end();
    this.observers.clear();
    await new Promise<void>((resolve) => this.server?.close(() => resolve()) ?? resolve());
    rmSync(this.daemonSocketPath, { force: true });
    rmSync(this.daemonPidPath, { force: true });
  }
}

export function effectForTaskState(led: number, state: TaskLightState, selected: boolean): EffectSpec {
  return semanticEffect(led, state, selected);
}

function parseEffectSpec(value: unknown, defaultPhase = 0, ledCount = q6ProAnsi.ledCount): EffectSpec {
  const object = asObject(value);
  const effect = numberParam(object.effect, EffectPrimitive.Solid);
  if (effect < EffectPrimitive.Off || effect > EffectPrimitive.PressFlash) throw new Error("Unknown effect primitive");
  const led = numberParam(object.led, -1);
  if (!Number.isInteger(led) || led < 0 || led >= ledCount) throw new Error("Effect LED is outside the active profile");
  return {
    led,
    effect,
    hue: numberParam(object.hue, 0),
    saturation: numberParam(object.saturation, 255),
    value: numberParam(object.value, 255),
    speed: numberParam(object.speed, 100),
    phase: numberParam(object.phase, defaultPhase),
    durationMs: numberParam(object.durationMs, 0),
    flags: numberParam(object.flags, 0),
  };
}

function numberParam(value: unknown, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

function asObject(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
}

function reviewTarget(value: unknown): Record<string, unknown> {
  if (value === undefined || value === null) return { type: "uncommittedChanges" };
  const target = asObject(value);
  switch (target.type) {
    case "uncommittedChanges": return { type: "uncommittedChanges" };
    case "baseBranch":
      if (typeof target.branch !== "string" || !target.branch.trim()) break;
      return { type: "baseBranch", branch: target.branch.trim() };
    case "commit":
      if (typeof target.sha !== "string" || !target.sha.trim()) break;
      return { type: "commit", sha: target.sha.trim(), title: typeof target.title === "string" ? target.title : null };
    case "custom":
      if (typeof target.instructions !== "string" || !target.instructions.trim()) break;
      return { type: "custom", instructions: target.instructions.trim() };
  }
  throw new Error("review requires a valid explicit target");
}

function localImageInputs(value: unknown): Array<Record<string, unknown>> {
  if (value === undefined) return [];
  if (!Array.isArray(value)) throw new Error("attachments must be an array of absolute local image paths");
  if (value.length > 20) throw new Error("attachments supports at most 20 images per explicit send");
  const allowedExtensions = new Set([".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic", ".heif", ".tif", ".tiff", ".bmp"]);
  const paths = new Set<string>();
  return value.map((candidate) => {
    if (typeof candidate !== "string" || !isAbsolute(candidate) || !allowedExtensions.has(extname(candidate).toLowerCase())) {
      throw new Error("attachments only accepts absolute local image paths");
    }
    let path: string;
    try {
      path = realpathSync(candidate);
      accessSync(path, constants.R_OK);
      const stat = statSync(path);
      if (!stat.isFile() || stat.size === 0 || !allowedExtensions.has(extname(path).toLowerCase())) throw new Error("not an image file");
    } catch {
      throw new Error(`Attachment is not a real readable local image: ${candidate}`);
    }
    if (paths.has(path)) throw new Error(`Duplicate attachment: ${path}`);
    paths.add(path);
    return { type: "localImage", path };
  });
}

function explicitSkillInput(value: unknown): { name: string; path: string } {
  let name: string | undefined;
  let path: string | undefined;
  if (typeof value === "string" && value.trim()) path = value.trim();
  const input = asObject(value);
  if (typeof input.name === "string" && input.name.trim() && typeof input.path === "string" && input.path.trim()) {
    name = input.name.trim();
    path = input.path.trim();
  }
  if (!path) throw new Error("skill requires confirmed explicit skillInput {name,path}");
  if (!isAbsolute(path) || basename(path) !== "SKILL.md") {
    throw new Error("skillInput.path must be an absolute path whose basename is exactly SKILL.md");
  }
  let realPath: string;
  try {
    realPath = realpathSync(path);
    accessSync(realPath, constants.R_OK);
    if (basename(realPath) !== "SKILL.md" || !statSync(realPath).isFile()) throw new Error("not a readable SKILL.md file");
  } catch {
    throw new Error("skillInput.path must resolve to a real readable SKILL.md file");
  }
  const resolvedName = name ?? basename(dirname(realPath));
  if (!resolvedName) throw new Error("skillInput.name must be non-empty");
  return { name: resolvedName, path: realPath };
}

export function sendMessage(message: LegacyRuntimeMessage, waitForReply = false): Promise<RuntimeStatus | undefined> {
  return new Promise((resolve, reject) => {
    const socket = createConnection(socketPath);
    socket.once("error", reject);
    socket.once("connect", () => {
      socket.write(`${JSON.stringify(message)}\n`);
      if (!waitForReply) {
        socket.end();
        resolve(undefined);
      }
    });
    if (waitForReply) {
      let buffer = "";
      socket.setEncoding("utf8");
      socket.on("data", (chunk) => {
        buffer += chunk;
        if (buffer.includes("\n")) {
          socket.end();
          resolve(JSON.parse(buffer.slice(0, buffer.indexOf("\n"))) as RuntimeStatus);
        }
      });
    }
  });
}

export function sendRpc(method: string, params: unknown = {}, id: string | number = randomUUID()): Promise<unknown> {
  return new Promise((resolve, reject) => {
    const socket = createConnection(socketPath);
    socket.once("error", reject);
    socket.once("connect", () => socket.write(`${JSON.stringify({ type: "rpc", id, method, params })}\n`));
    let buffer = "";
    socket.setEncoding("utf8");
    socket.on("data", (chunk) => {
      buffer += chunk;
      const newline = buffer.indexOf("\n");
      if (newline < 0) return;
      socket.end();
      const response = JSON.parse(buffer.slice(0, newline)) as RpcResponse;
      if (response.error) reject(new Error(response.error.message));
      else resolve(response.result);
    });
  });
}

export function observeRuntimeEvents(onEvent: (event: RuntimeEvent) => void): Socket {
  const socket = createConnection(socketPath);
  let buffer = "";
  socket.setEncoding("utf8");
  socket.once("connect", () => socket.write(`${JSON.stringify({ type: "observe" })}\n`));
  socket.on("data", (chunk) => {
    buffer += chunk;
    let newline: number;
    while ((newline = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, newline);
      buffer = buffer.slice(newline + 1);
      if (line.trim()) onEvent(JSON.parse(line) as RuntimeEvent);
    }
  });
  return socket;
}

export function readDaemonPid(): number | undefined {
  try { return Number(readFileSync(pidPath, "utf8")); } catch { return undefined; }
}

export function mergeStates(states: AgentState[]): AgentState {
  const priority: Record<number, number> = {
    [AgentState.Idle]: 0,
    [AgentState.Complete]: 1,
    [AgentState.Thinking]: 2,
    [AgentState.Streaming]: 3,
    [AgentState.Tool]: 4,
    [AgentState.Error]: 5,
  };
  return states.reduce((selected, candidate) => priority[candidate] > priority[selected] ? candidate : selected, AgentState.Idle);
}
