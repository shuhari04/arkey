import AppKit
import Foundation
import SwiftUI

enum CommandSurfaceMessageSeverity: Equatable {
    case info
    case warning
    case error
}

@MainActor
final class CommandSurfaceStore: ObservableObject {
    @Published var profile = Q6FallbackProfile.profile
    /// Visual-only keyboard choice. It never changes the active daemon profile
    /// or writes a hardware layout, so Q6 Pro can be inspected safely while a
    /// V1 Max is connected (and vice versa).
    @Published var keyboardPreviewProfileId: String?
    @Published var effectCatalog = EffectCatalogDocument.fallback
    @Published var dock = CommandSurfaceDefaults.initialDock()
    @Published var bindings: [String: CommandBinding] = [:]
    @Published var tasks = (0..<6).map(AgentTaskSlot.placeholder)
    @Published var selectedActionId: String?
    @Published var selectedControlId: String?
    @Published var selectedTaskId = "task-slot-0"
    @Published var sortMode: TaskSortMode = .priority
    @Published var composerText = ""
    @Published var attachments: [URL] = []
    @Published var isSending = false
    @Published var isCapturing = false
    @Published var continuousBindingMode = false
    @Published private(set) var bindingInProgress = false
    @Published var lastBoundControlId: String?
    @Published var conflictBinding: CommandBinding?
    @Published private(set) var messageSeverity: CommandSurfaceMessageSeverity = .info
    private var pendingMessageSeverity: CommandSurfaceMessageSeverity?
    @Published var message = "正在连接 ARkey daemon…" {
        didSet {
            messageSeverity = pendingMessageSeverity ?? .info
            pendingMessageSeverity = nil
            messageSequence &+= 1
        }
    }
    @Published private(set) var messageSequence = 0
    @Published var transport: ArkeyTransport = .unavailable
    @Published var deviceSupport = "unavailable"
    @Published var firmwareExtensionVersion: Int?
    @Published var profileMatches = false
    @Published var appServerReady = false
    @Published var authenticated = false
    @Published var restrictionDismissed = false
    @Published var developerEffect = EffectSpec.idle
    @Published var isPreviewing = false
    @Published var hardwarePreviewEnabled = true
    @Published var serviceTiers: [String] = []
    @Published var reasoningEfforts = ["low", "medium", "high"]
    @Published var planAvailable = false
    @Published var voiceControlPhase: String?
    @Published var voiceControlSequence = 0
    @Published var voiceCaptureState: VoiceCaptureState = .idle
    @Published var composerSentSequence = 0
    @Published var foregroundRequestSequence = 0
    @Published var requestedUIAction: String?
    @Published var importCandidates: [ThreadImportCandidate] = []
    @Published var importPickerVisible = false
    @Published var structuredApprovalRequest: StructuredApprovalRequest?
    @Published var workspaceRoot = FileManager.default.currentDirectoryPath
    @Published var workflowPreviewText = ""
    @Published private(set) var isCodexMicroLab = false
    @Published var selectedCodexMicroTarget: CodexMicroLabTarget = .agent1
    @Published private(set) var codexMicroSelectionActive = false
    @Published private(set) var codexMicroLabSnapshot = CodexMicroLabSnapshot.empty

    private let controller: ArkeyController
    private let observer = ArkeyEventObserver()
    private let codexMicroLab = CodexMicroLabService()
    private let codexMicroLabCacheKey = "arkey.codex-micro-lab.snapshot.v1"
    private var previewStopTask: Task<Void, Never>?
    private var observerRetryTask: Task<Void, Never>?
    private var observerRetrySeconds = 1
    private var observerFailureWasPresented = false
    private var started = false
    private var stopping = false
    private var dockState = DockStackState.initial
    private var taskHistory: [String] = []
    private var taskHistoryIndex = -1
    private var controlTransients: [String: TimedLightingEffect] = [:]
    private var taskTransients: [String: TimedLightingEffect] = [:]
    private var transientCleanupTasks: [String: Task<Void, Never>] = [:]
    private var captureRearmGate = CaptureRearmGate()
    private var captureRearmDeferred = false
    private var desiredCaptureToken: Int?
    private var capturedBindingToken: Int?
    private var nextCaptureToken = Int.random(in: 1...65_535)
    private var captureIntentRevision: UInt64 = 0
    private var continuousBindingRevision: UInt64 = 0
    private var captureCommandSerial: UInt64 = 0
    private var captureCommandTail: Task<Void, Never>?
    @Published private var transientRevision = 0
    private var bundledKeyboardProfiles: [KeyboardProfileV2] = []

    private struct CaptureStartRequest: Equatable {
        let revision: UInt64
        let token: Int
    }

    private struct CaptureStopRequest: Equatable {
        let revision: UInt64
    }

    init(controller: ArkeyController) {
        self.controller = controller
        selectedActionId = dock.first?.id
        loadCanonicalProfileFromDisk()
        loadBundledKeyboardProfiles()
        loadCanonicalEffectsFromDisk()
        developerEffect.atmosphereMix = effectCatalog.atmosphereMix
        loadCodexMicroLabCache()
    }

    func publishMessage(_ value: String, severity: CommandSurfaceMessageSeverity = .info) {
        pendingMessageSeverity = severity
        message = value
    }

    var selectedAction: CommandActionInstance? {
        guard let selectedActionId else { return dock.first }
        return dock.first(where: { $0.id == selectedActionId }) ?? dock.first
    }

    var selectedTask: AgentTaskSlot? {
        tasks.first(where: { $0.id == selectedTaskId }) ?? tasks.first(where: { $0.selected }) ?? tasks.first
    }

    var availableKeyboardProfiles: [KeyboardProfileV2] {
        var profiles = bundledKeyboardProfiles
        if !profiles.contains(where: { $0.profileId == profile.profileId }) {
            profiles.append(profile)
        }
        return profiles.sorted { $0.name < $1.name }
    }

    var displayedKeyboardProfile: KeyboardProfileV2 {
        if let keyboardPreviewProfileId,
           let selected = availableKeyboardProfiles.first(where: { $0.profileId == keyboardPreviewProfileId }) {
            return selected
        }
        return profile
    }

    func selectKeyboardPreview(_ profileId: String?) {
        keyboardPreviewProfileId = profileId
    }

    var sortedTasks: [AgentTaskSlot] {
        switch sortMode {
        case .priority:
            tasks.sorted {
                if $0.state.priority != $1.state.priority { return $0.state.priority > $1.state.priority }
                return $0.updatedAt > $1.updatedAt
            }
        case .recent:
            tasks.sorted { $0.updatedAt > $1.updatedAt }
        case .pinned:
            tasks.sorted {
                if $0.pinned != $1.pinned { return $0.pinned && !$1.pinned }
                return $0.updatedAt > $1.updatedAt
            }
        case .custom:
            tasks
        }
    }

    var isUSBV2Ready: Bool {
        isCodexMicroLab || (transport == .usb && firmwareExtensionVersion == 2 && profileMatches)
    }

    var hardwarePreviewDisabledReason: String? {
        if isCodexMicroLab { return "Codex Micro Lab 由 Codex Desktop 自行驱动灯光；ARkey daemon 不写入该模式。" }
        if transport == .bluetooth { return "Bluetooth 模式没有 Raw HID 灯效通道。" }
        if transport != .usb { return "未检测到 USB 键盘。" }
        if deviceSupport == "via-only" { return "VIA-only firmware 没有 ARkey 单键灯效协议。" }
        if deviceSupport != "arkey" { return "未知 Raw HID 设备，未启用硬件写入。" }
        if firmwareExtensionVersion != 2 { return "需要 ARkey v2 firmware。" }
        if !profileMatches { return "键盘 profile hash 与客户端不一致。" }
        return nil
    }

    var restrictionMessage: String? {
        if restrictionDismissed { return nil }
        if isCodexMicroLab { return nil }
        if transport == .bluetooth {
            return "当前仅检测到 Bluetooth：键盘可正常输入，但任务键接管与硬件任务灯不会同步。"
        }
        if transport != .usb {
            return "尚未识别 USB ARkey 键盘。模拟布局与灯效预览仍可使用。"
        }
        if deviceSupport == "via-only" {
            return "当前是 VIA-only firmware：键盘可正常输入，但没有 ARkey 任务键接管和单键灯效协议。"
        }
        if deviceSupport != "arkey" {
            return "检测到未知 Raw HID 设备；为安全起见，不启用任务键接管或硬件预览。"
        }
        if firmwareExtensionVersion != 2 {
            return "当前 firmware 只支持全局灯效。升级至 v2 后才能接管绑定键并同步单键任务灯。"
        }
        if !profileMatches {
            return "设备布局与 Q6 Pro profile hash 不匹配；为安全起见，按键接管和硬件预览已禁用。"
        }
        if !appServerReady || !authenticated {
            return "Codex App Server 尚未就绪或未登录；可先配置布局，任务动作会保持禁用。"
        }
        return nil
    }

    func start() async {
        guard !started else { return }
        started = true
        stopping = false
        await refresh()
        startObserver()
    }

    func stop() {
        stopping = true
        observerRetryTask?.cancel()
        previewStopTask?.cancel()
        for task in transientCleanupTasks.values { task.cancel() }
        transientCleanupTasks.removeAll()
        observer.stop()
    }

    func refresh() async {
        if refreshCodexMicroLabIfConnected() { return }
        isCodexMicroLab = false
        await controller.refresh()
        apply(status: controller.status)

        // A shared ~/.arkey socket can still be served by an older board
        // package. Restart it when its declared profile differs from the app's
        // bundled profile, rather than rendering a misleading fallback layout.
        if let daemonProfileId = controller.status?.profileId,
           daemonProfileId != profile.profileId {
            await controller.stop()
            await controller.start()
            apply(status: controller.status)
        }

        do {
            let response = try await ArkeyCommand.rpc("profile.get")
            if let decoded = decodeProfile(from: response) {
                profile = decoded
                profileMatches = controller.status?.layoutMatches
                    ?? controller.status?.layoutHash.map { $0 == decoded.layoutHash }
                    ?? (transport == .simulator)
            }
            applyProfileConnection(response)
        } catch {
            publishMessage("使用内置 \(profile.name) 布局；daemon profile 暂不可用。", severity: .warning)
        }

        if let response = try? await ArkeyCommand.rpc("settings.get") { applySettings(response) }
        if let response = try? await ArkeyCommand.rpc("task.list") { applyTaskList(response) }
        if let response = try? await ArkeyCommand.rpc("binding.list") { applyBindingList(response) }
        if let response = try? await ArkeyCommand.rpc("actions.list") { applyActionCapabilities(response) }
        detectBluetoothFallback()
    }

    func refreshCodexMicroLab() async {
        guard refreshCodexMicroLabIfConnected() else {
            publishMessage("未发现 Codex Micro Lab；请确认键盘以 USB 连接且已刷入实验固件。", severity: .error)
            return
        }
    }

    func selectCodexMicroTarget(_ target: CodexMicroLabTarget) {
        if codexMicroSelectionActive && selectedCodexMicroTarget == target {
            codexMicroSelectionActive = false
            message = "已取消槽位选择；点击键帽不会改写现有 Codex Micro 映射。"
            return
        }
        selectedCodexMicroTarget = target
        codexMicroSelectionActive = true
        message = "已选择 \(target.title)；现在点击要接入的实体键。该键会变为 Micro 独占。"
    }

    func codexMicroTarget(for control: KeyboardControl) -> CodexMicroLabTarget? {
        guard let row = control.matrixRow, let column = control.matrixColumn else { return nil }
        return codexMicroLabSnapshot.mappings.first(where: {
            $0.value.row == UInt8(row) && $0.value.column == UInt8(column)
        })?.key
    }

    func bindCodexMicroTarget(to controlId: String) async {
        guard isCodexMicroLab, codexMicroSelectionActive,
              let control = profile.controls.first(where: { $0.id == controlId }),
              control.bindable,
              let row = control.matrixRow,
              let column = control.matrixColumn,
              row >= 0, row <= Int(UInt8.max), column >= 0, column <= Int(UInt8.max) else {
            publishMessage("这个物理控件不能用于 Codex Micro Lab 绑定。", severity: .error)
            return
        }

        let target = selectedCodexMicroTarget
        let position = CodexMicroLabPosition(row: UInt8(row), column: UInt8(column))
        do {
            let snapshot = try codexMicroLab.setMapping(target: target, position: position)
            applyCodexMicroLabSnapshot(snapshot, persist: true)
            selectedControlId = controlId
            lastBoundControlId = controlId
            codexMicroSelectionActive = false
            message = "\(target.title) 已写入 \(control.label)，并已从固件读回验证。已取消选择，避免误改。"
        } catch {
            publishMessage(error.localizedDescription, severity: .error)
        }
    }

    func clearCodexMicroTarget(_ target: CodexMicroLabTarget? = nil) async {
        let target = target ?? selectedCodexMicroTarget
        do {
            let snapshot = try codexMicroLab.clearMapping(target: target)
            applyCodexMicroLabSnapshot(snapshot, persist: true)
            message = "\(target.title) 已清除并读回验证；原实体键已恢复普通输入。"
        } catch {
            publishMessage(error.localizedDescription, severity: .error)
        }
    }

    func setCodexMicroEncoderEnabled(_ enabled: Bool) async {
        do {
            let snapshot = try codexMicroLab.setEncoderEnabled(enabled)
            applyCodexMicroLabSnapshot(snapshot, persist: true)
            message = enabled
                ? "旋钮已由 Codex Micro 独占并读回验证；旋转不会再调节系统音量。"
                : "旋钮已恢复 Q6/VIA 原始映射并读回验证（通常为系统音量）。"
        } catch {
            publishMessage(error.localizedDescription, severity: .error)
        }
    }

    func repairDaemonAndRefresh() async {
        message = "正在修复 ARkey 后台服务…"
        await controller.repairDaemon()
        apply(status: controller.status)
        await refresh()
    }

    func selectAction(_ action: CommandActionInstance, beginHardwareCapture: Bool = true) {
        guard action.enabled else {
            publishMessage(
                action.kind == .scheduledTasks
                    ? "ChatGPT Scheduled Tasks 暂无公开 App Server 映射。"
                    : "此功能当前不可绑定。",
                severity: .warning
            )
            return
        }
        selectedActionId = action.id
        message = "已选择 \(action.title)；现在按实体键或点击模拟键盘。"
        if beginHardwareCapture {
            guard !bindingInProgress,
                  capturedBindingToken == nil,
                  !captureRearmGate.hasPendingSignals else {
                if continuousBindingMode { captureRearmDeferred = true }
                message = continuousBindingMode
                    ? "当前绑定完成并释放实体键后，将等待 \(action.title)。"
                    : "当前绑定仍在完成；请稍后再次选择 \(action.title)。"
                return
            }
            if let request = prepareCaptureStart() { _ = scheduleCaptureStart(request) }
        }
    }

    @discardableResult
    func beginCapture() async -> Int? {
        guard let request = prepareCaptureStart() else { return nil }
        await scheduleCaptureStart(request).value
        return request.token
    }

    func startQuickBinding() async {
        if let task = setQuickBindingEnabled(true) { await task.value }
    }

    func stopQuickBinding() async {
        if let task = setQuickBindingEnabled(false) { await task.value }
    }

    @discardableResult
    func setQuickBindingEnabled(_ enabled: Bool) -> Task<Void, Never>? {
        continuousBindingRevision &+= 1
        let modeRevision = continuousBindingRevision

        if !enabled {
            continuousBindingMode = false
            captureRearmDeferred = false
            captureRearmGate.reset()
            capturedBindingToken = nil
            let request = prepareCaptureStop()
            return scheduleCaptureStop(request)
        }

        continuousBindingMode = true
        guard selectedAction?.enabled == true else {
            continuousBindingMode = false
            return nil
        }
        guard !bindingInProgress,
              capturedBindingToken == nil,
              !captureRearmGate.hasPendingSignals else {
            captureRearmDeferred = true
            return nil
        }
        if isCapturing, desiredCaptureToken != nil { return nil }
        guard let request = prepareCaptureStart() else {
            continuousBindingMode = false
            return nil
        }
        let command = scheduleCaptureStart(request)
        return Task { @MainActor [weak self] in
            await command.value
            guard let self,
                  self.continuousBindingMode,
                  self.continuousBindingRevision == modeRevision,
                  self.captureIntentRevision == request.revision else { return }
            if !self.isCapturing, self.capturedBindingToken != request.token {
                self.continuousBindingMode = false
                self.captureRearmDeferred = false
            }
        }
    }

    func stopCapture() async {
        let request = prepareCaptureStop()
        await scheduleCaptureStop(request).value
    }

    private func prepareCaptureStart() -> CaptureStartRequest? {
        guard selectedAction?.enabled == true else { return nil }
        captureIntentRevision &+= 1
        nextCaptureToken = nextCaptureToken == 65_535 ? 1 : nextCaptureToken + 1
        let request = CaptureStartRequest(revision: captureIntentRevision, token: nextCaptureToken)
        desiredCaptureToken = request.token
        isCapturing = false
        return request
    }

    private func prepareCaptureStop() -> CaptureStopRequest {
        captureIntentRevision &+= 1
        desiredCaptureToken = nil
        isCapturing = false
        return CaptureStopRequest(revision: captureIntentRevision)
    }

    private func scheduleCaptureStart(_ request: CaptureStartRequest) -> Task<Void, Never> {
        scheduleCaptureCommand { [weak self] in
            guard let self,
                  self.captureIntentRevision == request.revision,
                  self.desiredCaptureToken == request.token else { return }
            do {
                let output = try await ArkeyCommand.rpc("binding.capture.start", payload: [
                    "token": request.token,
                    "timeoutMs": 30_000,
                    "profileId": self.profile.profileId,
                    "layoutHash": self.profile.layoutHash
                ])
                let hardware = output.data(using: .utf8)
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["hardware"] as? Bool ?? false
                guard self.captureIntentRevision == request.revision,
                      self.desiredCaptureToken == request.token else { return }
                self.isCapturing = hardware
                if !hardware {
                    self.desiredCaptureToken = nil
                    self.publishMessage("实体键捕获不可用；仍可拖动功能到模拟键盘。", severity: .warning)
                    _ = try? await ArkeyCommand.rpc("binding.capture.stop", payload: ["token": request.token])
                }
            } catch {
                guard self.captureIntentRevision == request.revision,
                      self.desiredCaptureToken == request.token else { return }
                self.desiredCaptureToken = nil
                self.isCapturing = false
                self.publishMessage("实体键捕获不可用：\(error.localizedDescription)", severity: .error)
            }
        }
    }

    private func scheduleCaptureStop(_ request: CaptureStopRequest) -> Task<Void, Never> {
        scheduleCaptureCommand { [weak self] in
            guard let self else { return }
            do {
                _ = try await ArkeyCommand.rpc("binding.capture.stop")
            } catch { }
            guard self.captureIntentRevision == request.revision,
                  self.desiredCaptureToken == nil else { return }
            self.isCapturing = false
        }
    }

    private func scheduleCaptureCommand(
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) -> Task<Void, Never> {
        captureCommandSerial &+= 1
        let serial = captureCommandSerial
        let previous = captureCommandTail
        let command = Task { @MainActor [weak self] in
            await previous?.value
            guard !Task.isCancelled, let self else { return }
            await operation()
            if self.captureCommandSerial == serial { self.captureCommandTail = nil }
        }
        captureCommandTail = command
        return command
    }

    private func cancelContinuousBindingState() {
        continuousBindingRevision &+= 1
        continuousBindingMode = false
        captureRearmDeferred = false
        captureRearmGate.reset()
        capturedBindingToken = nil
    }

    func requestBinding(
        to controlId: String,
        replacing: Bool = false,
        captureToken: Int? = nil,
        actionOverride: CommandActionInstance? = nil
    ) async {
        guard let action = actionOverride ?? selectedAction else {
            if let captureToken { completeCapturedBinding(token: captureToken) }
            return
        }
        guard let control = profile.controls.first(where: { $0.id == controlId }), control.bindable else {
            publishMessage("这个物理控件不能绑定。", severity: .error)
            if let captureToken { completeCapturedBinding(token: captureToken) }
            return
        }
        guard !bindingInProgress else {
            if let captureToken { completeCapturedBinding(token: captureToken) }
            publishMessage("另一个按键绑定正在写入；已忽略重复请求。", severity: .warning)
            return
        }

        bindingInProgress = true
        var rearmAfterBinding = false
        defer {
            bindingInProgress = false
            if continuousBindingMode, captureRearmDeferred || rearmAfterBinding {
                captureRearmDeferred = false
                rearmContinuousCapture()
            }
        }

        selectedControlId = controlId
        if captureToken == nil {
            rearmAfterBinding = continuousBindingMode
            await stopCapture()
        }
        if let existing = bindings[controlId], !replacing {
            conflictBinding = existing
            message = "\(control.label) 已绑定 \(existing.action.title)。"
            cancelContinuousBindingState()
            return
        }

        do {
            let taskId: String?
            if action.kind == .taskAgent, let ordinal = action.ordinal {
                taskId = try await ensureTaskSlot(for: ordinal).id
            } else {
                taskId = nil
            }
            let nextRevision = (bindings.values.map(\.revision).max() ?? 0) + 1
            let replacedBinding = bindings[controlId]
            var payload: [String: Any] = [
                "controlId": controlId,
                "instanceId": action.id,
                "actionId": action.kind.rpcId,
                "replace": replacing,
                "revision": nextRevision,
                "profileId": profile.profileId,
                "layoutHash": profile.layoutHash
            ]
            if let ordinal = action.ordinal { payload["ordinal"] = ordinal }
            if let taskId { payload["taskId"] = taskId }
            let response = try await ArkeyCommand.rpc("binding.set", payload: payload)
            guard bindingWasAcknowledged(response) else {
                throw ArkeyCommandError.failed("daemon 未返回 firmware binding ACK")
            }
            let revision = bindingRevision(from: response) ?? nextRevision
            let binding = CommandBinding(
                controlId: controlId,
                action: action,
                revision: revision,
                createdAt: Date(),
                taskId: taskId
            )
            withAnimation(.spring(response: 0.24, dampingFraction: 0.78)) {
                bindings[controlId] = binding
                lastBoundControlId = controlId
                conflictBinding = nil
                consume(action)
                if replacing,
                   let oldAction = replacedBinding?.action,
                   oldAction.id != action.id,
                   !dock.contains(where: { $0.id == oldAction.id }) {
                    dock.append(oldAction)
                    dockState.actions = dock
                }
            }
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard self?.lastBoundControlId == controlId else { return }
                self?.lastBoundControlId = nil
            }
            isCapturing = false
            message = "\(action.title) 已写入 \(control.label)，binding revision \(revision) 已确认。"
            if let captureToken {
                completeCapturedBinding(token: captureToken)
            }
        } catch {
            publishMessage(error.localizedDescription, severity: .error)
            if let captureToken { completeCapturedBinding(token: captureToken) }
        }
    }

    func replaceConflict() async {
        guard let controlId = conflictBinding?.controlId else { return }
        await requestBinding(to: controlId, replacing: true)
    }

    func removeBinding(_ controlId: String) async {
        let removedBinding = bindings[controlId]
        do {
            _ = try await ArkeyCommand.rpc("binding.remove", payload: [
                "controlId": controlId,
                "profileId": profile.profileId,
                "layoutHash": profile.layoutHash
            ])
            withAnimation(.easeOut(duration: 0.18)) { _ = bindings.removeValue(forKey: controlId) }
            if let action = removedBinding?.action, !dock.contains(where: { $0.id == action.id }) {
                dock.append(action)
                dockState.actions = dock
            }
            message = "按键绑定已清除。"
        } catch {
            publishMessage(error.localizedDescription, severity: .error)
        }
    }

    func chooseTask(_ id: String, bringToFront: Bool = false, recordHistory: Bool = true) async {
        selectedTaskId = id
        tasks = tasks.map { slot in
            var slot = slot
            slot.selected = slot.id == id
            return slot
        }
        do {
            _ = try await ArkeyCommand.rpc("task.select", payload: ["taskId": id])
            if recordHistory {
                if taskHistoryIndex + 1 < taskHistory.count {
                    taskHistory.removeSubrange((taskHistoryIndex + 1)..<taskHistory.count)
                }
                if taskHistory.last != id { taskHistory.append(id) }
                taskHistoryIndex = taskHistory.count - 1
            }
            if bringToFront {
                NSApp.activate(ignoringOtherApps: true)
            }
        } catch {
            publishMessage(error.localizedDescription, severity: .error)
        }
    }

    func navigateTaskHistory(delta: Int) async {
        guard !taskHistory.isEmpty else {
            message = "当前没有任务选择历史。"
            return
        }
        let target = min(taskHistory.count - 1, max(0, taskHistoryIndex + delta))
        guard target != taskHistoryIndex else {
            message = delta < 0 ? "已经是最早的任务选择。" : "已经是最新的任务选择。"
            return
        }
        taskHistoryIndex = target
        await chooseTask(taskHistory[target], recordHistory: false)
    }

    func persistSortMode(_ mode: TaskSortMode) async {
        sortMode = mode
        do {
            _ = try await ArkeyCommand.rpc("settings.update", payload: ["taskSort": mode.rawValue])
        } catch {
            publishMessage("排序已在本窗口生效，daemon 持久化失败：\(error.localizedDescription)", severity: .warning)
        }
    }

    func togglePinned(_ taskId: String) async {
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        let pinned = !tasks[index].pinned
        do {
            _ = try await ArkeyCommand.rpc("task.update", payload: ["taskId": taskId, "pinned": pinned])
            tasks[index].pinned = pinned
            message = pinned ? "任务已固定到 Pinned 顶部。" : "任务已取消固定。"
        } catch {
            publishMessage(error.localizedDescription, severity: .error)
        }
    }

    func moveCustomTask(_ taskId: String, delta: Int) async {
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        let target = min(tasks.count - 1, max(0, index + delta))
        guard target != index else { return }
        let task = tasks.remove(at: index)
        tasks.insert(task, at: target)
        do {
            _ = try await ArkeyCommand.rpc("task.reorder", payload: ["taskIds": tasks.map(\.id)])
        } catch {
            publishMessage("自定义顺序未持久化：\(error.localizedDescription)", severity: .warning)
        }
    }

    func loadImportCandidates() async {
        do {
            let output = try await ArkeyCommand.rpc("task.import")
            guard let data = output.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = object["candidates"] as? [[String: Any]] else {
                throw ArkeyCommandError.failed("App Server 未返回可导入任务列表")
            }
            importCandidates = candidates.compactMap { candidate in
                guard let id = candidate["id"] as? String else { return nil }
                return ThreadImportCandidate(
                    id: id,
                    title: (candidate["name"] as? String) ?? (candidate["title"] as? String) ?? "Codex task",
                    cwd: candidate["cwd"] as? String,
                    updatedAt: (candidate["updatedAt"] as? String) ?? (candidate["recencyAt"] as? String)
                )
            }
            importPickerVisible = true
            message = importCandidates.isEmpty ? "当前工作区没有可显式导入的 CLI / VS Code 任务。" : "请选择要导入的 Codex 任务。"
        } catch {
            publishMessage(error.localizedDescription, severity: .error)
        }
    }

    func importTask(_ threadId: String) async {
        do {
            _ = try await ArkeyCommand.rpc("task.import", payload: ["threadId": threadId])
            importPickerVisible = false
            if let response = try? await ArkeyCommand.rpc("task.list") { applyTaskList(response) }
            message = "任务已通过 thread/resume 显式导入 ARkey。"
        } catch {
            publishMessage(error.localizedDescription, severity: .error)
        }
    }

    func sendComposer() async {
        let prompt = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!prompt.isEmpty || !attachments.isEmpty), !isSending else { return }
        isSending = true
        defer { isSending = false }
        let payload: [String: Any] = [
            "taskId": selectedTaskId,
            "text": prompt,
            "attachments": attachments.map { $0.path(percentEncoded: false) }
        ]
        do {
            _ = try await ArkeyCommand.rpc("composer.send", payload: payload)
            composerText = ""
            attachments.removeAll()
            composerSentSequence += 1
            message = "Prompt 已交给所选任务。"
        } catch {
            publishMessage("发送失败，Composer 内容已保留：\(error.localizedDescription)", severity: .error)
        }
    }

    func trigger(_ kind: CommandActionKind) async {
        switch kind {
        case .taskAgent:
            break
        case .openTerminal:
            do {
                _ = try await NSWorkspace.shared.openApplication(
                    at: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                    configuration: .init()
                )
            } catch {
                publishMessage(error.localizedDescription, severity: .error)
            }
        case .openBrowser:
            NSWorkspace.shared.open(URL(string: "https://chatgpt.com/codex")!)
        case .attachFile:
            message = "请从 Composer 的附件按钮选择文件。"
        case .navigateBack, .navigateForward, .toggleSidebar:
            requestedUIAction = kind.rpcId
            message = "已切换 ARkey 本地界面：\(kind.title)。"
        case .gitCommit, .createPullRequest:
            workflowPreviewText = await readGitPreview()
            requestedUIAction = kind.rpcId
            NSApp.activate(ignoringOtherApps: true)
            message = "已打开 \(kind.title) 预览；确认前不会执行 Git 操作。"
        case .scheduledTasks:
            message = "Scheduled Tasks 暂无公开 App Server 动作。"
        default:
            do {
                _ = try await ArkeyCommand.rpc("action.trigger", payload: [
                    "actionId": kind.rpcId,
                    "taskId": selectedTaskId
                ])
                message = "已触发 \(kind.title)。"
            } catch {
                publishMessage(error.localizedDescription, severity: .error)
            }
        }
    }

    func confirmWorkflow(actionId: String, explicitInput: String?) async {
        switch actionId {
        case "review", "skill":
            var payload: [String: Any] = [
                "actionId": actionId,
                "taskId": selectedTaskId,
                "confirmed": true
            ]
            if let explicitInput { payload["skillInput"] = explicitInput }
            do {
                _ = try await ArkeyCommand.rpc("action.trigger", payload: payload)
                requestedUIAction = nil
                message = actionId == "review" ? "Review 已通过 App Server 启动。" : "Skill input 已显式提交。"
            } catch {
                publishMessage(error.localizedDescription, severity: .error)
            }
        case "approval":
            guard let request = structuredApprovalRequest,
                  let text = explicitInput,
                  let data = text.data(using: .utf8),
                  let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                publishMessage("结构化审批需要一个明确的 JSON object result。", severity: .error)
                return
            }
            do {
                _ = try await ArkeyCommand.rpc("approval.respond", payload: [
                    "requestId": request.requestID.value,
                    "result": result
                ])
                structuredApprovalRequest = nil
                requestedUIAction = nil
                message = "结构化响应已显式提交，等待 App Server resolved。"
            } catch {
                publishMessage(error.localizedDescription, severity: .error)
            }
        case "git_commit", "create_pr":
            requestedUIAction = nil
            message = "已确认进入工作流；仍需展示真实 diff、分支和文案后才能执行。"
        default:
            requestedUIAction = nil
        }
    }

    func cycleReasoning(delta: Int) async {
        do {
            let output = try await ArkeyCommand.rpc("action.trigger", payload: [
                "actionId": CommandActionKind.dialReasoning.rpcId,
                "taskId": selectedTaskId,
                "direction": delta >= 0 ? "clockwise" : "counterClockwise"
            ])
            if let data = output.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                applyTaskDictionary(object)
            }
            let effort = tasks.first(where: { $0.id == selectedTaskId })?.reasoningEffort ?? "dynamic"
            message = "Reasoning: \(effort)（将在下一次 Send 时使用）"
        } catch {
            publishMessage("无法更新 reasoning：\(error.localizedDescription)", severity: .error)
        }
    }

    func previewLighting() async {
        previewStopTask?.cancel()
        var spec = developerEffect
        spec.epoch = UInt64(Date().timeIntervalSince1970 * 1_000)
        developerEffect = spec
        let hardware = hardwarePreviewEnabled && hardwarePreviewDisabledReason == nil
        let durationMs = min(30_000, max(250, spec.durationMs ?? 5_000))
        let effects = wireEffects(for: spec)
        isPreviewing = true
        message = hardware ? "正在同步客户端与硬件预览…" : "正在客户端模拟预览。"
        previewStopTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(durationMs))
            guard !Task.isCancelled else { return }
            await self?.stopLightingPreview()
        }
        do {
            _ = try? await ArkeyCommand.rpc("settings.update", payload: [
                "hardwareSync": hardwarePreviewEnabled,
                "atmosphereMix": spec.atmosphereMix
            ])
            let output = try await ArkeyCommand.rpc("lighting.preview", payload: [
                "effects": effects,
                "durationMs": durationMs,
                "atmosphereMix": spec.atmosphereMix,
                "epoch": spec.epoch,
                "seed": spec.seed,
                "phase": spec.phase,
                "startedAtMs": spec.epoch
            ])
            applyPreviewStart(output)
            message = hardware ? "客户端与硬件正在同相预览。" : "正在客户端模拟预览。"
        } catch {
            publishMessage("daemon / 硬件预览不可用，客户端模拟继续：\(error.localizedDescription)", severity: .warning)
        }
    }

    func stopLightingPreview() async {
        previewStopTask?.cancel()
        previewStopTask = nil
        do { _ = try await ArkeyCommand.rpc("lighting.stop") } catch { }
        isPreviewing = false
        message = "已恢复实时任务灯状态。"
    }

    func syncVoiceState(_ state: VoiceCaptureState) async {
        voiceCaptureState = state
        let wireState = state == .locked ? VoiceCaptureState.recording.rawValue : state.rawValue
        do {
            _ = try await ArkeyCommand.rpc("voice.state", payload: [
                "state": wireState,
                "taskId": selectedTaskId
            ])
        } catch {
            // Speech and the on-screen simulator remain useful without hardware.
            if state != .idle {
                publishMessage("语音状态仅在客户端模拟：\(error.localizedDescription)", severity: .warning)
            }
        }
    }

    func lightingColor(for control: KeyboardControl, at date: Date) -> Color {
        let keyPreviewTarget = developerEffect.target == .selectedKey
            && (developerEffect.targetControlId ?? selectedControlId) == control.id
        let taskPreviewTarget = developerEffect.target == .selectedTask && bindings[control.id]?.taskId == selectedTaskId
        if isPreviewing,
           developerEffect.target == .globalAtmosphere || keyPreviewTarget || taskPreviewTarget {
            return animatedColor(spec: developerEffect, control: control, date: date)
        }
        if let transient = controlTransients[control.id], transient.expiresAt > date {
            return animatedColor(spec: transient.spec, control: control, date: date, includeSeed: false)
        }
        guard let binding = bindings[control.id] else {
            return globalAtmosphereColor(for: control, at: date).opacity(0.24)
        }
        if let taskId = binding.taskId,
           let transient = taskTransients[taskId], transient.expiresAt > date {
            return animatedColor(spec: transient.spec, control: control, date: date, includeSeed: false)
        }
        if !binding.active { return Color.orange.opacity(0.58) }
        if binding.action.kind == .taskAgent,
           let taskId = binding.taskId,
           let slot = tasks.first(where: { $0.id == taskId }) {
            if slot.state == .unassigned { return .black }
            let semantic = Color(arkeyHex: semanticHex(for: slot.state))
            let pulse = semanticEnvelope(for: slot.state, selected: slot.id == selectedTaskId, date: date)
            let atmosphere = globalLuminance(at: date)
            let brightness = ArkeyLightingMath.semanticBrightness(pulse, globalLuminance: atmosphere)
            return semantic.opacity(brightness)
        }
        return commandColor(for: binding.action.kind, date: date)
    }

    private func commandColor(for kind: CommandActionKind, date: Date) -> Color {
        switch kind {
        case .approveCurrent:
            return selectedTask?.pendingApprovalCount ?? 0 > 0 ? Color(arkeyHex: "#FF6D00") : .white.opacity(0.45)
        case .declineCurrent:
            return selectedTask?.pendingApprovalCount ?? 0 > 0 ? Color(arkeyHex: "#FF0033") : .white.opacity(0.38)
        case .pushToTalk:
            switch voiceCaptureState {
            case .recording, .locked:
                return Color(arkeyHex: "#20E0B2").opacity(0.72 + 0.28 * globalLuminance(at: date))
            case .processing, .ready:
                return .white.opacity(0.72 + 0.28 * globalLuminance(at: date))
            case .error:
                return Color(arkeyHex: "#FF0033")
            case .idle:
                return .white.opacity(0.45)
            }
        case .send:
            return voiceCaptureState == .ready || !composerText.isEmpty || !attachments.isEmpty ? .white : .white.opacity(0.35)
        case .toggleFastMode:
            return selectedTask?.serviceTier == nil ? .white.opacity(0.48) : Color(arkeyHex: "#304FFE")
        default:
            return .white.opacity(0.62 + 0.12 * globalLuminance(at: date))
        }
    }

    private func startObserver() {
        observerRetryTask?.cancel()
        // Codex Micro Lab is driven by its own HID service, and an unavailable
        // daemon has no event socket to observe. Avoid creating a short-lived
        // `observe` process in either case; that was the source of the
        // repeating “事件流尚未连接” banner on Macs without a local daemon.
        guard !isCodexMicroLab, controller.status?.running == true else { return }
        do {
            try observer.start { [weak self] line in
                Task { @MainActor in self?.handleEventLine(line) }
            } onTermination: { [weak self] _ in
                Task { @MainActor in self?.scheduleObserverReconnect() }
            }
        } catch {
            if !observerFailureWasPresented {
                observerFailureWasPresented = true
                publishMessage("事件流暂不可用：\(error.localizedDescription)", severity: .warning)
            }
            scheduleObserverReconnect()
        }
    }

    private func scheduleObserverReconnect() {
        guard !stopping else { return }
        let delay = observerRetrySeconds
        observerRetrySeconds = min(30, observerRetrySeconds * 2)
        observerRetryTask?.cancel()
        observerRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.startObserver()
        }
    }

    func handleEventLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        // A parsable event confirms the stream is genuinely live. Only then
        // reset reconnect backoff and allow a future failure to be surfaced.
        observerRetrySeconds = 1
        observerFailureWasPresented = false
        let type = (json["type"] as? String) ?? (json["event"] as? String) ?? ""
        let payload = json["data"] as? [String: Any] ?? json
        switch type {
        case "snapshot":
            applyRuntimeSnapshot(payload)
        case "device", "device.status", "status", "device.connected":
            transport = .usb
            applyStatusDictionary(payload["status"] as? [String: Any] ?? payload)
        case "device.disconnected":
            transport = .unavailable
            deviceSupport = "unavailable"
            firmwareExtensionVersion = nil
            profileMatches = false
            isCapturing = false
            previewStopTask?.cancel()
            previewStopTask = nil
            isPreviewing = false
            captureIntentRevision &+= 1
            desiredCaptureToken = nil
            cancelContinuousBindingState()
        case "binding.capture.started":
            guard let token = payload["token"] as? Int,
                  token == desiredCaptureToken else { break }
            isCapturing = payload["hardware"] as? Bool ?? true
        case "binding.capture.captured", "binding.capture", "control.capture":
            guard let controlId = payload["controlId"] as? String,
                  let token = payload["token"] as? Int,
                  token == desiredCaptureToken else { break }
            desiredCaptureToken = nil
            capturedBindingToken = token
            isCapturing = false
            guard let capturedAction = selectedAction else {
                cancelContinuousBindingState()
                message = "没有可绑定功能，已忽略这次实体键捕获。"
                break
            }
            Task {
                await requestBinding(
                    to: controlId,
                    captureToken: token,
                    actionOverride: capturedAction
                )
            }
        case "binding.capture.released":
            guard let token = payload["token"] as? Int,
                  token == capturedBindingToken else { break }
            if captureRearmGate.releaseObserved(token: token) {
                capturedBindingToken = nil
                if continuousBindingMode { rearmContinuousCapture() }
            }
        case "binding.capture.stopped":
            guard let token = payload["token"] as? Int,
                  token == desiredCaptureToken else { break }
            desiredCaptureToken = nil
            isCapturing = false
            if payload["reason"] as? String == "timeout" {
                captureIntentRevision &+= 1
                cancelContinuousBindingState()
                publishMessage("连续绑定已在 30 秒无输入后停止。", severity: .warning)
            }
        case "binding.ack":
            break
        case "binding.changed":
            Task {
                if let response = try? await ArkeyCommand.rpc("binding.list") { applyBindingList(response) }
            }
        case "task", "task.updated", "thread.updated", "turn.updated", "task.changed", "task.selected":
            applyTaskDictionary(payload["task"] as? [String: Any] ?? payload)
        case "task.effort.changed":
            if let taskId = payload["taskId"] as? String,
               let effort = payload["effort"] as? String,
               let index = tasks.firstIndex(where: { $0.id == taskId }) {
                tasks[index].reasoningEffort = effort
            }
        case "task.fast.changed":
            if let taskId = payload["taskId"] as? String,
               let tier = payload["serviceTier"] as? String,
               let index = tasks.firstIndex(where: { $0.id == taskId }) {
                tasks[index].serviceTier = tier
            }
        case "appServer.status", "app_server", "appserver.state":
            let state = (payload["state"] as? String) ?? "offline"
            appServerReady = state == "ready"
            if state != "ready" { structuredApprovalRequest = nil }
        case "appserver.ready":
            appServerReady = true
            if let accountResponse = payload["account"] as? [String: Any], accountResponse.keys.contains("account") {
                authenticated = accountResponse["account"] != nil && !(accountResponse["account"] is NSNull)
            } else {
                authenticated = payload["account"] != nil && !(payload["account"] is NSNull)
            }
            applyModelCapabilities(payload["models"] as? [[String: Any]] ?? [])
        case "appserver.notification":
            if payload["method"] as? String == "account/login/completed" {
                let params = payload["params"] as? [String: Any]
                let success = (params?["success"] as? Bool) ?? (payload["success"] as? Bool) ?? false
                authenticated = success
                if success {
                    message = "ChatGPT 登录已完成。"
                } else {
                    publishMessage("ChatGPT 登录未完成，请重试。", severity: .error)
                }
            }
        case "account.changed":
            authenticated = payload["authenticated"] as? Bool ?? authenticated
        case "account.login.failed", "account.error":
            authenticated = false
            publishMessage(
                (payload["error"] as? String) ?? (payload["message"] as? String) ?? "ChatGPT 登录未完成。",
                severity: .error
            )
        case "composer.send.requested":
            Task { await sendComposer() }
        case "approval.requested":
            if let task = payload["task"] as? [String: Any] { applyTaskDictionary(task) }
            let structured = payload["structured"] as? Bool ?? false
            if structured {
                captureStructuredApproval(payload)
                requestedUIAction = "approval"
                NSApp.activate(ignoringOtherApps: true)
            }
        case "voice.state":
            if let raw = payload["state"] as? String, let state = VoiceCaptureState(rawValue: raw) {
                voiceCaptureState = state
            }
        case "voice.state.changed":
            if let raw = payload["state"] as? String, let state = VoiceCaptureState(rawValue: raw) {
                voiceCaptureState = state
            }
        case "lighting.binding.transient":
            guard let controlId = payload["controlId"] as? String,
                  let effect = payload["effect"] as? [String: Any],
                  let spec = decodeWireEffect(effect, target: .selectedKey, controlId: controlId) else { break }
            installTransient(spec, key: "control:\(controlId)", controlId: controlId, taskId: nil)
        case "lighting.task.entry":
            guard let taskId = payload["taskId"] as? String,
                  let effect = payload["effect"] as? [String: Any],
                  let spec = decodeWireEffect(effect, target: .selectedTask, controlId: nil) else { break }
            installTransient(spec, key: "task:\(taskId)", controlId: nil, taskId: taskId)
        case "lighting.task.entry.completed":
            if let taskId = payload["taskId"] as? String {
                taskTransients.removeValue(forKey: taskId)
                transientCleanupTasks.removeValue(forKey: "task:\(taskId)")?.cancel()
                transientRevision &+= 1
            }
        case "lighting.preview.stopped":
            previewStopTask?.cancel()
            previewStopTask = nil
            isPreviewing = false
            message = "预览已停止，已恢复实时任务灯状态。"
        case "actions.changed":
            if let actions = json["data"] as? [[String: Any]] {
                applyActionObjects(actions)
            } else if let actions = payload["actions"] as? [[String: Any]] {
                applyActionObjects(actions)
            }
        case "voice.control":
            voiceControlPhase = payload["phase"] as? String
            voiceControlSequence += 1
        case "voice.toggle.requested":
            voiceControlPhase = "toggle"
            voiceControlSequence += 1
        case "app.foreground.requested":
            foregroundRequestSequence += 1
        case "approval.ui.required":
            captureStructuredApproval(payload)
            requestedUIAction = "approval"
            NSApp.activate(ignoringOtherApps: true)
        case "approval.responded":
            if let request = structuredApprovalRequest,
               request.requestID.displayValue == requestIDDisplayValue(payload["requestId"]) {
                structuredApprovalRequest = nil
                requestedUIAction = nil
            }
        case "action.ui.requested":
            requestedUIAction = (payload["actionId"] as? String) ?? "approval"
            NSApp.activate(ignoringOtherApps: true)
        case "error", "device.error", "appserver.error", "action.error":
            publishMessage((payload["message"] as? String) ?? "ARkey runtime error", severity: .error)
        default:
            break
        }
    }

    private func completeCapturedBinding(token: Int) {
        guard token == capturedBindingToken else { return }
        if captureRearmGate.bindingCompleted(token: token) {
            capturedBindingToken = nil
            if continuousBindingMode { rearmContinuousCapture() }
        }
    }

    private func rearmContinuousCapture() {
        guard continuousBindingMode, selectedAction?.enabled == true else { return }
        guard !bindingInProgress,
              capturedBindingToken == nil,
              !captureRearmGate.hasPendingSignals else {
            captureRearmDeferred = true
            return
        }
        captureRearmDeferred = false
        _ = setQuickBindingEnabled(true)
    }

    private func apply(status: ArkeyStatus?) {
        guard let status else {
            transport = .unavailable
            deviceSupport = "unavailable"
            firmwareExtensionVersion = nil
            profileMatches = false
            appServerReady = false
            authenticated = false
            return
        }
        transport = status.transport ?? (status.device == nil ? .unavailable : .usb)
        deviceSupport = status.support ?? deviceSupport
        firmwareExtensionVersion = status.extensionVersion
        profileMatches = status.layoutMatches ?? status.layoutHash.map { $0 == profile.layoutHash } ?? false
        appServerReady = status.appServerRunning ?? (status.appServer == "ready")
        authenticated = status.authenticated ?? authenticated
    }

    private func applyStatusDictionary(_ json: [String: Any]) {
        if let raw = json["transport"] as? String { transport = ArkeyTransport(rawValue: raw) ?? transport }
        if let support = json["support"] as? String { deviceSupport = support }
        if json["device"] as? String != nil || json["product"] as? String != nil { transport = .usb }
        firmwareExtensionVersion = json["extensionVersion"] as? Int ?? firmwareExtensionVersion
        profileMatches = json["layoutMatches"] as? Bool
            ?? (json["layoutHash"] as? String).map { $0 == profile.layoutHash }
            ?? profileMatches
        appServerReady = json["appServerRunning"] as? Bool
            ?? ((json["appServer"] as? String).map { $0 == "ready" })
            ?? appServerReady
        authenticated = json["authenticated"] as? Bool ?? authenticated
    }

    private func applyRuntimeSnapshot(_ json: [String: Any]) {
        applyStatusDictionary(json["status"] as? [String: Any] ?? json)
        authenticated = json["authenticated"] as? Bool ?? authenticated
        if let models = json["models"] as? [[String: Any]] { applyModelCapabilities(models) }
        if let rawVoiceState = json["voiceState"] as? String,
           let state = VoiceCaptureState(rawValue: rawVoiceState) {
            voiceCaptureState = state
        }
        if let settings = json["settings"] as? [String: Any] { applySettingsDictionary(settings) }
        if let taskList = json["tasks"] as? [[String: Any]] { applyTaskObjects(taskList) }
        if let bindingObject = json["bindings"] as? [String: Any] { applyBindingObject(bindingObject) }
        if let actions = json["actions"] as? [[String: Any]] { applyActionObjects(actions) }
    }

    private func applyTaskList(_ output: String) {
        guard let data = output.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else { return }
        if let list = value as? [[String: Any]] { applyTaskObjects(list) }
        else if let object = value as? [String: Any], let list = object["tasks"] as? [[String: Any]] { applyTaskObjects(list) }
    }

    private func applyTaskObjects(_ objects: [[String: Any]]) {
        let decoded = objects.enumerated().compactMap { index, object in
            decodeTask(object, fallbackSlotIndex: index)
        }
        guard !decoded.isEmpty else { return }
        tasks = decoded
        if let selected = decoded.first(where: { $0.selected }) {
            selectedTaskId = selected.id
            if taskHistory.isEmpty {
                taskHistory = [selected.id]
                taskHistoryIndex = 0
            }
        }
    }

    private func decodeTask(_ json: [String: Any], fallbackSlotIndex: Int? = nil) -> AgentTaskSlot? {
        guard let taskId = (json["taskId"] as? String) ?? (json["slotId"] as? String) ?? (json["id"] as? String) else { return nil }
        let selected = json["selected"] as? Bool ?? false
        return AgentTaskSlot(
            id: taskId,
            slotIndex: json["slotIndex"] as? Int ?? fallbackSlotIndex ?? tasks.first(where: { $0.id == taskId })?.slotIndex ?? tasks.count,
            threadId: json["threadId"] as? String,
            title: json["title"] as? String ?? "Agent",
            state: taskState(json["state"] as? String),
            updatedAt: parseDate(json["recencyAt"] as? String) ?? Date(),
            activeTurnId: json["activeTurnId"] as? String,
            pendingApprovalCount: json["pendingApprovalCount"] as? Int ?? 0,
            pendingStructuredRequestCount: json["pendingStructuredRequestCount"] as? Int ?? 0,
            pinned: json["pinned"] as? Bool ?? false,
            selected: selected,
            reasoningEffort: (json["effort"] as? String) ?? (json["reasoningEffort"] as? String),
            serviceTier: json["serviceTier"] as? String
        )
    }

    private func applyTaskDictionary(_ json: [String: Any]) {
        let existingIndex = ((json["taskId"] as? String) ?? (json["id"] as? String))
            .flatMap { id in tasks.first(where: { $0.id == id })?.slotIndex }
        guard let incoming = decodeTask(json, fallbackSlotIndex: existingIndex) else { return }
        if let index = tasks.firstIndex(where: { $0.id == incoming.id }) { tasks[index] = incoming }
        else { tasks.append(incoming) }
        if incoming.selected { selectedTaskId = incoming.id }
    }

    private func applyBindingList(_ output: String) {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        applyBindingObject(object)
    }

    private func applyBindingObject(_ object: [String: Any]) {
        let revision = object["revision"] as? Int ?? 0
        let values = object["bindings"] as? [[String: Any]] ?? []
        var next: [String: CommandBinding] = [:]
        for value in values {
            guard let controlId = value["controlId"] as? String,
                  let instanceId = value["instanceId"] as? String,
                  let actionId = value["actionId"] as? String,
                  let kind = CommandActionKind(rpcId: actionId) else { continue }
            let taskId = value["taskId"] as? String
            let ordinal = taskId.flatMap { id in tasks.first(where: { $0.id == id }).map { $0.slotIndex + 1 } }
            let action = CommandActionInstance(id: instanceId, kind: kind, title: kind.title, ordinal: ordinal, enabled: true)
            next[controlId] = CommandBinding(
                controlId: controlId,
                action: action,
                revision: revision,
                createdAt: parseDate(value["createdAt"] as? String) ?? Date(),
                taskId: taskId,
                active: value["active"] as? Bool ?? false
            )
        }
        bindings = next
        dockState = .initial
        for binding in next.values.filter(\.active).sorted(by: { $0.createdAt < $1.createdAt }) {
            _ = dockState.consume(instanceId: binding.action.id)
        }
        dock = dockState.actions
        selectedActionId = dock.first?.id
    }

    private func applyProfileConnection(_ output: String) {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let connection = object["connection"] as? [String: Any] else { return }
        transport = .usb
        deviceSupport = connection["support"] as? String ?? deviceSupport
        firmwareExtensionVersion = connection["extensionVersion"] as? Int
        profileMatches = connection["layoutMatches"] as? Bool ?? false
    }

    private func applySettings(_ output: String) {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        applySettingsDictionary(object)
    }

    private func applySettingsDictionary(_ object: [String: Any]) {
        if let root = object["workspaceRoot"] as? String, !root.isEmpty { workspaceRoot = root }
        if let hardware = object["hardwareSync"] as? Bool { hardwarePreviewEnabled = hardware }
        if let mix = object["atmosphereMix"] as? Double { developerEffect.atmosphereMix = mix }
        if let raw = object["taskSort"] as? String, let mode = TaskSortMode(rawValue: raw) { sortMode = mode }
    }

    private func applyActionCapabilities(_ output: String) {
        guard let data = output.data(using: .utf8),
              let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        applyActionObjects(objects)
    }

    private func applyActionObjects(_ objects: [[String: Any]]) {
        let capabilities = Dictionary(uniqueKeysWithValues: objects.compactMap { object -> (CommandActionKind, Bool)? in
            guard let actionId = object["actionId"] as? String,
                  let kind = CommandActionKind(rpcId: actionId),
                  let enabled = object["enabled"] as? Bool else { return nil }
            return (kind, enabled)
        })
        planAvailable = capabilities[.togglePlanMode] ?? false
        dock = dock.map { action in
            guard let enabled = capabilities[action.kind], enabled != action.enabled else { return action }
            return CommandActionInstance(
                id: action.id,
                kind: action.kind,
                title: action.title,
                ordinal: action.ordinal,
                enabled: enabled
            )
        }
        dockState.actions = dock
        if let selectedActionId,
           dock.first(where: { $0.id == selectedActionId })?.enabled != true {
            self.selectedActionId = dock.first(where: \.enabled)?.id
        }
    }

    private func applyModelCapabilities(_ models: [[String: Any]]) {
        guard let model = models.first(where: { $0["isDefault"] as? Bool == true }) ?? models.first else { return }
        if let efforts = model["supportedReasoningEfforts"] as? [[String: Any]] {
            let values = efforts.compactMap { $0["reasoningEffort"] as? String }
            if !values.isEmpty { reasoningEfforts = values }
        } else if let values = model["efforts"] as? [String], !values.isEmpty {
            reasoningEfforts = values
        }
        if let tiers = model["serviceTiers"] as? [[String: Any]] {
            serviceTiers = tiers.compactMap { $0["id"] as? String }
        } else if let tiers = model["serviceTiers"] as? [String] {
            serviceTiers = tiers
        }
    }

    private func taskState(_ raw: String?) -> AgentTaskState {
        switch raw {
        case "idle": .idle
        case "working": .working
        case "completeUnread", "unread": .unread
        case "requiresInput": .requiresInput
        case "error": .error
        case "offline", "unassigned", .none: .unassigned
        default: .idle
        }
    }

    private func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    private func bindingRevision(from output: String) -> Int? {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["revision"] as? Int
    }

    func semanticHex(for state: AgentTaskState) -> String {
        effectCatalog.semantics[semanticName(for: state)]?.hex ?? state.hexColor
    }

    private func semanticName(for state: AgentTaskState) -> String {
        switch state {
        case .unassigned: "unassigned"
        case .idle: "idle"
        case .working: "working"
        case .unread: "completeUnread"
        case .requiresInput: "requiresInput"
        case .error: "error"
        }
    }

    private func wireEffects(for spec: EffectSpec) -> [[String: Any]] {
        let controls: [KeyboardControl]
        switch spec.target {
        case .selectedKey:
            let target = spec.targetControlId ?? selectedControlId
            controls = profile.controls.filter { $0.id == target && $0.ledIndex != nil }
        case .selectedTask:
            controls = profile.controls.filter { control in
                control.ledIndex != nil && bindings[control.id]?.taskId == selectedTaskId
            }
        case .globalAtmosphere:
            controls = profile.controls.filter { $0.ledIndex != nil }
        }

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var value: CGFloat = 0
        var alpha: CGFloat = 0
        let color = NSColor(Color(arkeyHex: spec.hexColor)).usingColorSpace(.deviceRGB) ?? .white
        color.getHue(&hue, saturation: &saturation, brightness: &value, alpha: &alpha)
        let primitiveName: String
        switch spec.primitive {
        case .snake: primitiveName = "breath"
        case .typing: primitiveName = "pressFlash"
        case .completeWave: primitiveName = "riseFade"
        default: primitiveName = spec.primitive.rawValue
        }
        let primitive = effectCatalog.primitives[primitiveName] ?? 1
        return controls.compactMap { control in
            guard let led = control.ledIndex else { return nil }
            let phase = spatialPhase(for: spec, control: control)
            return [
                "led": led,
                "effect": primitive,
                "hue": Int((hue * 255).rounded()),
                "saturation": Int((saturation * 255).rounded()),
                "value": Int((min(1, max(0, spec.brightness)) * 255).rounded()),
                "speed": Int(min(255, max(1, spec.speed * 64)).rounded()),
                "phase": Int((phase * 255).rounded()),
                "durationMs": spec.durationMs ?? 0,
                "flags": 0
            ]
        }
    }


    private func consume(_ action: CommandActionInstance) {
        dockState.actions = dock
        _ = dockState.consume(instanceId: action.id)
        dock = dockState.actions
        selectedActionId = dock.first?.id
    }

    private func ensureTaskSlot(for ordinal: Int) async throws -> AgentTaskSlot {
        let slotIndex = ordinal - 1
        if let existing = tasks.first(where: { $0.slotIndex == slotIndex && !$0.id.hasPrefix("task-slot-") }) {
            return existing
        }
        if let response = try? await ArkeyCommand.rpc("task.list") {
            applyTaskList(response)
            if let existing = tasks.first(where: { $0.slotIndex == slotIndex && !$0.id.hasPrefix("task-slot-") }) {
                return existing
            }
        }
        while !tasks.contains(where: { $0.slotIndex == slotIndex && !$0.id.hasPrefix("task-slot-") }) {
            let output = try await ArkeyCommand.rpc("task.create", payload: [
                "title": "Agent \(tasks.count + 1)"
            ])
            guard let data = output.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let created = decodeTask(object, fallbackSlotIndex: tasks.count) else {
                throw ArkeyCommandError.failed("daemon 未返回稳定的任务槽")
            }
            if let index = tasks.firstIndex(where: { $0.id == created.id }) { tasks[index] = created }
            else { tasks.append(created) }
        }
        guard let slot = tasks.first(where: { $0.slotIndex == slotIndex && !$0.id.hasPrefix("task-slot-") }) else {
            throw ArkeyCommandError.failed("无法创建 Agent Key 对应的任务槽")
        }
        return slot
    }

    private func bindingWasAcknowledged(_ output: String) -> Bool {
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else { return false }
        if let bool = json as? Bool { return bool }
        guard let object = json as? [String: Any] else { return false }
        return (object["hardwareSynchronized"] as? Bool)
            ?? (object["acknowledged"] as? Bool)
            ?? (object["firmwareAck"] as? Bool)
            ?? (object["ok"] as? Bool)
            ?? false
    }

    private func decodeProfile(from output: String) -> KeyboardProfileV2? {
        guard let data = output.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        if let direct = try? decoder.decode(KeyboardProfileV2.self, from: data) { return direct }
        struct Envelope: Decodable { let profile: KeyboardProfileV2 }
        return try? decoder.decode(Envelope.self, from: data).profile
    }

    private func loadCanonicalProfileFromDisk() {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        if let bundled = Bundle.main.url(forResource: "keychron-q6-pro-ansi", withExtension: "json") {
            candidates.append(bundled)
        }
        var directory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        for _ in 0..<5 {
            candidates.append(directory.appendingPathComponent("profiles/keychron-q6-pro-ansi.json"))
            directory.deleteLastPathComponent()
        }
        let decoder = JSONDecoder()
        for candidate in candidates where fileManager.isReadableFile(atPath: candidate.path) {
            guard let data = try? Data(contentsOf: candidate),
                  let decoded = try? decoder.decode(KeyboardProfileV2.self, from: data) else { continue }
            profile = decoded
            return
        }
    }

    private func loadBundledKeyboardProfiles() {
        let fileManager = FileManager.default
        let fileNames = ["keychron-q6-pro-ansi", "keychron-v1-max-ansi-knob"]
        var candidates: [URL] = []
        for name in fileNames {
            if let bundled = Bundle.main.url(forResource: name, withExtension: "json") {
                candidates.append(bundled)
            }
        }
        var directory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        for _ in 0..<5 {
            for name in fileNames {
                candidates.append(directory.appendingPathComponent("profiles/\(name).json"))
            }
            directory.deleteLastPathComponent()
        }
        let decoder = JSONDecoder()
        let decodedProfiles: [KeyboardProfileV2] = candidates.compactMap { candidate in
            guard fileManager.isReadableFile(atPath: candidate.path),
                  let data = try? Data(contentsOf: candidate),
                  let decoded = try? decoder.decode(KeyboardProfileV2.self, from: data) else { return nil }
            return decoded
        }
        bundledKeyboardProfiles = decodedProfiles.reduce(into: [KeyboardProfileV2]()) { result, profile in
            if !result.contains(where: { $0.profileId == profile.profileId }) { result.append(profile) }
        }
    }

    private func loadCanonicalEffectsFromDisk() {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        if let bundled = Bundle.main.url(forResource: "effects-v1", withExtension: "json") {
            candidates.append(bundled)
        }
        var directory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        for _ in 0..<5 {
            candidates.append(directory.appendingPathComponent("profiles/effects-v1.json"))
            directory.deleteLastPathComponent()
        }
        let decoder = JSONDecoder()
        for candidate in candidates where fileManager.isReadableFile(atPath: candidate.path) {
            guard let data = try? Data(contentsOf: candidate),
                  let decoded = try? decoder.decode(EffectCatalogDocument.self, from: data) else { continue }
            effectCatalog = decoded
            return
        }
    }

    private func animatedColor(
        spec: EffectSpec,
        control: KeyboardControl,
        date: Date,
        includeSeed: Bool = true
    ) -> Color {
        let elapsedMs = (spec.epoch > 0
            ? max(0, date.timeIntervalSince1970 - Double(spec.epoch) / 1_000)
            : date.timeIntervalSince1970) * 1_000
        let speedByte = min(255, max(1, Int((spec.speed * 64).rounded())))
        let phase = spatialPhase(for: spec, control: control, includeSeed: includeSeed)
        let effectivePrimitive: LightingPrimitive = switch spec.primitive {
        case .snake: .breath
        case .typing: .pressFlash
        case .completeWave: .riseFade
        default: spec.primitive
        }
        let envelope: Double
        switch effectivePrimitive {
        case .off: envelope = 0
        case .solid: envelope = 1
        case .shallowBreath:
            let period = Double(max(650, 3_200 - speedByte * 10))
            envelope = (166 + easedTriangle(elapsedMs / period + phase) * 89) / 255
        case .breath:
            let period = Double(max(650, 3_200 - speedByte * 10))
            envelope = (32 + easedTriangle(elapsedMs / period + phase) * 223) / 255
        case .doublePulse:
            let period = Double(max(700, 1_700 - speedByte * 4))
            let position = (elapsedMs + phase * period).truncatingRemainder(dividingBy: period)
            if position < 180 { envelope = easedTriangle(position / 180) }
            else if position >= 280 && position < 460 { envelope = easedTriangle((position - 280) / 180) }
            else { envelope = 0 }
        case .riseFade:
            let duration = Double(spec.durationMs ?? 600)
            let rise = max(1, duration / 5)
            if elapsedMs >= duration { envelope = 0 }
            else if elapsedMs < rise { envelope = elapsedMs / rise }
            else { envelope = (duration - elapsedMs) / (duration - rise) }
        case .pressFlash:
            let duration = Double(spec.durationMs ?? 250)
            envelope = elapsedMs >= duration ? 0 : (duration - elapsedMs) / duration
        case .snake, .typing, .completeWave:
            envelope = 0
        }
        return Color(arkeyHex: spec.hexColor).opacity(min(1, max(0, spec.brightness * envelope)))
    }

    private func spatialPhase(for spec: EffectSpec, control: KeyboardControl, includeSeed: Bool = true) -> Double {
        let offset: Double
        switch spec.primitive {
        case .snake:
            offset = control.x / max(1, profile.maxX)
        case .typing:
            offset = Double((control.ledIndex ?? 0) % 13) / 13
        case .completeWave:
            let center = profile.maxX / 2
            offset = abs((control.x + control.width / 2) - center) / max(1, center)
        default:
            offset = 0
        }
        let seedPhase = includeSeed ? Double((spec.seed + (control.ledIndex ?? 0) * 53) & 0xff) / 256 : 0
        let value = spec.phase + offset + seedPhase
        return value - floor(value)
    }

    private func easedTriangle(_ normalizedPhase: Double) -> Double {
        let phase = normalizedPhase - floor(normalizedPhase)
        let triangle = phase < 0.5 ? phase * 2 : (1 - phase) * 2
        return triangle * triangle
    }

    private func applyPreviewStart(_ output: String) {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let startedAt = object["startedAt"] as? String,
           let date = ISO8601DateFormatter().date(from: startedAt) {
            developerEffect.epoch = UInt64(max(0, date.timeIntervalSince1970 * 1_000))
        }
        if let seed = object["seed"] as? Int { developerEffect.seed = seed }
    }

    private func captureStructuredApproval(_ payload: [String: Any]) {
        guard let method = payload["method"] as? String,
              let requestID = runtimeRequestID(payload["requestId"]) else { return }
        if let current = structuredApprovalRequest,
           current.requestID.displayValue != requestID.displayValue {
            // The daemon owns FIFO ordering; keep its currently visible queue head.
            return
        }
        let params = payload["params"] as? [String: Any]
            ?? structuredApprovalRequest?.params
            ?? [:]
        structuredApprovalRequest = StructuredApprovalRequest(
            requestID: requestID,
            method: method,
            params: params
        )
    }

    private func runtimeRequestID(_ value: Any?) -> RuntimeRequestID? {
        if let value = value as? String { return .string(value) }
        if let value = value as? NSNumber { return .integer(value.intValue) }
        if let value = value as? Int { return .integer(value) }
        return nil
    }

    private func requestIDDisplayValue(_ value: Any?) -> String? {
        runtimeRequestID(value)?.displayValue
    }

    private func decodeWireEffect(
        _ object: [String: Any],
        target: EffectTarget,
        controlId: String?
    ) -> EffectSpec? {
        guard let effect = object["effect"] as? Int,
              let primitiveName = effectCatalog.primitives.first(where: { $0.value == effect })?.key,
              let primitive = LightingPrimitive(rawValue: primitiveName) else { return nil }
        let hue = CGFloat(object["hue"] as? Int ?? 0) / 255
        let saturation = CGFloat(object["saturation"] as? Int ?? 0) / 255
        let color = NSColor(calibratedHue: hue, saturation: saturation, brightness: 1, alpha: 1)
        let spec = EffectSpec(
            primitive: primitive,
            target: target,
            targetControlId: controlId,
            hexColor: Color(nsColor: color).arkeyHex(),
            brightness: Double(object["value"] as? Int ?? 255) / 255,
            speed: Double(object["speed"] as? Int ?? 1) / 64,
            durationMs: object["durationMs"] as? Int,
            seed: 0,
            phase: Double(object["phase"] as? Int ?? 0) / 255,
            epoch: UInt64(Date().timeIntervalSince1970 * 1_000),
            atmosphereMix: effectCatalog.atmosphereMix
        )
        return spec
    }

    private func installTransient(
        _ spec: EffectSpec,
        key: String,
        controlId: String?,
        taskId: String?
    ) {
        let durationMs = max(1, spec.durationMs ?? (spec.primitive == .pressFlash ? 250 : 600))
        let timed = TimedLightingEffect(spec: spec, expiresAt: Date().addingTimeInterval(Double(durationMs) / 1_000))
        if let controlId { controlTransients[controlId] = timed }
        if let taskId { taskTransients[taskId] = timed }
        transientCleanupTasks[key]?.cancel()
        transientCleanupTasks[key] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(durationMs))
            guard !Task.isCancelled, let self else { return }
            if let controlId { self.controlTransients.removeValue(forKey: controlId) }
            if let taskId { self.taskTransients.removeValue(forKey: taskId) }
            self.transientCleanupTasks.removeValue(forKey: key)
            self.transientRevision &+= 1
        }
        transientRevision &+= 1
    }

    private func semanticEnvelope(for state: AgentTaskState, selected: Bool, date: Date) -> Double {
        guard selected else { return 1 }
        let definition = effectCatalog.semantics[semanticName(for: state)]
        let primitive = definition?.selectedPrimitive ?? .solid
        let period = Double(effectCatalog.selectedPulsePeriodMs)
        let eased = easedTriangle(date.timeIntervalSince1970 * 1_000 / period)
        switch primitive {
        case .off: return 0
        case .solid: return 1
        case .shallowBreath: return (166 + eased * 89) / 255
        case .breath: return (32 + eased * 223) / 255
        default: return 1
        }
    }

    private func globalLuminance(at date: Date) -> Double {
        0.52 + 0.48 * (sin(date.timeIntervalSince1970 * 0.72) + 1) / 2
    }

    private func globalAtmosphereColor(for control: KeyboardControl, at date: Date) -> Color {
        let moving = (sin(date.timeIntervalSince1970 * 3.1 - control.x * 0.72 - control.y * 0.34) + 1) / 2
        let opacity = 0.28 + 0.34 * moving
        switch voiceCaptureState {
        case .recording, .locked: return Color(arkeyHex: "#20E0B2").opacity(opacity)
        case .processing, .ready: return Color.white.opacity(opacity)
        case .error: return Color(arkeyHex: "#FF0033").opacity(opacity)
        case .idle: return Color(arkeyHex: "#304FFE").opacity(opacity)
        }
    }

    private func detectBluetoothFallback() {
        guard transport == .unavailable else { return }
        if BluetoothKeyboardDetector.isConnected(vendorId: profile.vendorId, productIds: profile.productIds) {
            transport = .bluetooth
            deviceSupport = "bluetooth-only"
        }
    }

    private func refreshCodexMicroLabIfConnected() -> Bool {
        guard codexMicroLab.isConnected else { return false }
        let productName = codexMicroLab.deviceName
        let labProfileID = CodexMicroLabProtocol.keyboardProfileID(forProductName: productName)
        if let labProfile = availableKeyboardProfiles.first(where: { $0.profileId == labProfileID }) {
            // This is the active hardware profile used for writes. The
            // separate preview selector remains visual-only by design.
            profile = labProfile
        }
        isCodexMicroLab = true
        transport = .usb
        deviceSupport = "codex-micro-lab"
        firmwareExtensionVersion = nil
        profileMatches = true
        appServerReady = false
        authenticated = false

        if let snapshot = codexMicroLab.readMappingsIfAvailable() {
            applyCodexMicroLabSnapshot(snapshot, persist: true)
            message = "已连接 \(productName ?? "Codex Micro Lab")（\(profile.name)）；\(snapshot.verification.detail)"
        } else {
            // Show the firmware's documented first-boot layout rather than an
            // empty keyboard when IOKit cannot synchronously fetch Raw HID
            // input.  Subsequent ARkey edits replace and persist this cache.
            // The two Lab boards share a USB identity.  Only V1 has a
            // firmware-defined ready-to-use default; a Q6 readback failure
            // must stay empty instead of drawing V1's compact-nav mapping.
            let firmwareDefault: CodexMicroLabSnapshot = labProfileID == "keychron-v1-max-ansi-knob"
                ? .v1MaxDefaults
                : .empty
            var cached = codexMicroLabSnapshot.mappings.isEmpty
                ? firmwareDefault
                : codexMicroLabSnapshot
            cached.verification = .pendingReadback
            applyCodexMicroLabSnapshot(cached, persist: true)
            message = "已连接 \(productName ?? "Codex Micro Lab")（\(profile.name)）；\(cached.verification.detail)"
        }
        return true
    }

    private func applyCodexMicroLabSnapshot(_ snapshot: CodexMicroLabSnapshot, persist: Bool) {
        codexMicroLabSnapshot = snapshot
        guard persist, let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: codexMicroLabCacheKey)
    }

    private func loadCodexMicroLabCache() {
        guard let data = UserDefaults.standard.data(forKey: codexMicroLabCacheKey),
              let snapshot = try? JSONDecoder().decode(CodexMicroLabSnapshot.self, from: data) else { return }
        codexMicroLabSnapshot = snapshot
    }

    private func readGitPreview() async -> String {
        let root = workspaceRoot
        return await Task.detached(priority: .userInitiated) {
            func run(_ arguments: [String]) -> String {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = ["-C", root] + arguments
                process.standardOutput = pipe
                process.standardError = pipe
                do { try process.run(); process.waitUntilExit() }
                catch { return error.localizedDescription }
                return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return [
                "$ git status --short --branch\n\(run(["status", "--short", "--branch"]))",
                "$ git diff --stat\n\(run(["diff", "--stat"]))",
                "$ git diff --cached --stat\n\(run(["diff", "--cached", "--stat"]))"
            ].joined(separator: "\n\n")
        }.value
    }
}

private struct TimedLightingEffect {
    let spec: EffectSpec
    let expiresAt: Date
}

private extension CommandActionKind {
    init?(rpcId: String) {
        switch rpcId {
        case "task_agent": self = .taskAgent
        case "approve": self = .approveCurrent
        case "decline": self = .declineCurrent
        case "ptt": self = .pushToTalk
        case "send": self = .send
        case "continue": self = .continueNewTask
        case "fast": self = .toggleFastMode
        case "plan": self = .togglePlanMode
        case "reasoning": self = .dialReasoning
        case "cancel": self = .cancelFocusedControl
        case "review": self = .reviewChanges
        case "git_commit": self = .gitCommit
        case "create_pr": self = .createPullRequest
        case "skill": self = .openSkill
        case "navigate_back": self = .navigateBack
        case "navigate_forward": self = .navigateForward
        case "toggle_sidebar": self = .toggleSidebar
        case "terminal": self = .openTerminal
        case "browser": self = .openBrowser
        case "attach": self = .attachFile
        case "scheduled_tasks": self = .scheduledTasks
        default: return nil
        }
    }

    var rpcId: String {
        switch self {
        case .taskAgent: "task_agent"
        case .approveCurrent: "approve"
        case .declineCurrent: "decline"
        case .pushToTalk: "ptt"
        case .send: "send"
        case .continueNewTask: "continue"
        case .toggleFastMode: "fast"
        case .togglePlanMode: "plan"
        case .dialReasoning: "reasoning"
        case .cancelFocusedControl: "cancel"
        case .reviewChanges: "review"
        case .gitCommit: "git_commit"
        case .createPullRequest: "create_pr"
        case .openSkill: "skill"
        case .navigateBack: "navigate_back"
        case .navigateForward: "navigate_forward"
        case .toggleSidebar: "toggle_sidebar"
        case .openTerminal: "terminal"
        case .openBrowser: "browser"
        case .attachFile: "attach"
        case .scheduledTasks: "scheduled_tasks"
        }
    }
}
