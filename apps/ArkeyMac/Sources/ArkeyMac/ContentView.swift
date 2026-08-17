import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject private var controller: ArkeyController
    @ObservedObject private var notch: ArkeyNotchCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var store: CommandSurfaceStore
    @StateObject private var speech = SpeechCoordinator()
    @AppStorage("arkey.developerDrawer.visible") private var developerDrawerVisible = false
    @State private var showOnboarding: Bool
    @State private var pttPointerDown = false
    @State private var composerBeforeSpeech = ""
    @State private var taskRailVisible = true
    @State private var sidebarWasVisibleBeforeDrawer = true
    @State private var composerHovered = false
    @State private var pttHovered = false
    @State private var transientMessage: String?
    @State private var transientMessageSeverity: CommandSurfaceMessageSeverity = .info
    @State private var transientMessageTask: Task<Void, Never>?
    @StateObject private var firmwareFlasher = FirmwareFlashingService()
    @StateObject private var updates = ArkeyUpdateService()
    @StateObject private var diagnostics = ArkeyDiagnostics.shared
    @State private var firmwareToolVisible = false
    @State private var updateCenterVisible = false
    @State private var diagnosticCenterVisible = false
    @FocusState private var composerFocused: Bool

    init(controller: ArkeyController, notch: ArkeyNotchCoordinator) {
        self.controller = controller
        self.notch = notch
        _store = StateObject(wrappedValue: CommandSurfaceStore(controller: controller))
        _showOnboarding = State(initialValue: !UserDefaults.standard.bool(forKey: "arkey.onboarding.completed"))
    }

    var body: some View {
        ZStack {
            commandSurfaceBackground
            HStack(spacing: 0) {
                appShell
                if developerDrawerVisible {
                    DeveloperLightingDrawer(
                        store: store,
                        controller: controller,
                        isPresented: $developerDrawerVisible
                    )
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .disabled(showOnboarding)
            .accessibilityHidden(showOnboarding)
            if showOnboarding {
                Color.black.opacity(0.58)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .zIndex(9)
                OnboardingFlowView(store: store, speech: speech, isPresented: $showOnboarding)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.55), radius: 30, y: 16)
                    .transition(.scale(scale: 0.97).combined(with: .opacity))
                    .zIndex(10)
                    .accessibilityAddTraits(.isModal)
            }
            if let transientMessage, !showOnboarding {
                VStack {
                    Spacer()
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: transientMessageSymbol)
                            .foregroundStyle(transientMessageColor)
                        Text(transientMessage)
                            .lineLimit(transientMessageSeverity == .error ? 4 : (transientMessageSeverity == .warning ? 2 : 1))
                            .fixedSize(horizontal: false, vertical: true)
                            .help(transientMessage)
                        if transientMessageSeverity == .error {
                            Button {
                                dismissTransientMessage()
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(ArkeyIconButtonStyle(size: 22))
                            .help("关闭错误")
                            .accessibilityLabel("关闭错误")
                        }
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ArkeyTheme.textSecondary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, transientMessageSeverity == .error ? 8 : 0)
                    .frame(minHeight: 30)
                    .frame(maxWidth: 520)
                    .background(ArkeyTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(
                            transientMessageSeverity == .info ? ArkeyTheme.strokeStrong : transientMessageColor.opacity(0.5),
                            lineWidth: 0.75
                        )
                    )
                    .shadow(color: .black.opacity(0.32), radius: 12, y: 5)
                    .padding(.bottom, 14)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(transientMessageAccessibilityLabel)
                }
                .padding(.horizontal, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(8)
            }
        }
        .frame(minWidth: developerDrawerVisible ? 1120 : 980, minHeight: 680)
        .preferredColorScheme(.dark)
        .animation(
            reduceMotion ? .easeOut(duration: 0.08) : .spring(response: 0.30, dampingFraction: 0.86),
            value: developerDrawerVisible
        )
        .animation(.easeOut(duration: 0.18), value: showOnboarding)
        .sheet(
            isPresented: Binding(
                get: { workflowRequest != nil },
                set: { if !$0 { store.requestedUIAction = nil } }
            ),
            onDismiss: { composerFocused = true }
        ) {
            if let action = workflowRequest {
                WorkflowPreviewView(
                    actionId: action,
                    approval: store.structuredApprovalRequest,
                    gitPreview: store.workflowPreviewText
                ) {
                    store.requestedUIAction = nil
                } onConfirm: { explicitInput in
                    Task { await store.confirmWorkflow(actionId: action, explicitInput: explicitInput) }
                }
            }
        }
        .sheet(isPresented: $store.importPickerVisible, onDismiss: { composerFocused = true }) {
            TaskImportView(store: store)
        }
        .sheet(isPresented: $firmwareToolVisible) {
            FirmwareToolView(flasher: firmwareFlasher)
        }
        .sheet(isPresented: $updateCenterVisible) {
            UpdateCenterView(updates: updates)
        }
        .sheet(isPresented: $diagnosticCenterVisible) {
            DiagnosticCenterView(diagnostics: diagnostics)
        }
        .confirmationDialog(
            "按键已被占用",
            isPresented: Binding(
                get: { store.conflictBinding != nil },
                set: { if !$0 { store.conflictBinding = nil } }
            )
        ) {
            Button("替换现有绑定") { Task { await store.replaceConflict() } }
            if let controlId = store.conflictBinding?.controlId {
                Button("清除现有绑定", role: .destructive) { Task { await store.removeBinding(controlId) } }
            }
            Button("取消", role: .cancel) { store.conflictBinding = nil }
        } message: {
            if let conflict = store.conflictBinding {
                Text("此控件已经绑定 \(conflict.action.title)。ARkey 不会隐式 swap。")
            }
        }
        .task {
            await store.start()
            updates.start()
            diagnostics.record(
                category: .app,
                name: "app.command-surface.started",
                details: ["version": ArkeyUpdateService.currentVersion]
            )
            speech.refreshPermissionStatus()
            if developerDrawerVisible {
                sidebarWasVisibleBeforeDrawer = taskRailVisible
                taskRailVisible = false
            }
            if !showOnboarding { composerFocused = true }
        }
        .onChange(of: speech.transcript) { _, transcript in
            guard !transcript.isEmpty,
                  speech.state == .recording || speech.state == .locked || speech.state == .processing || speech.state == .ready else { return }
            store.composerText = mergeVoiceTranscript(transcript)
        }
        .onChange(of: speech.state) { _, state in
            Task { await store.syncVoiceState(state) }
        }
        .onChange(of: store.composerSentSequence) { _, _ in
            speech.markPromptSent()
        }
        .onChange(of: store.messageSequence) { _, _ in
            presentTransientMessage(store.message, severity: store.messageSeverity)
        }
        .onChange(of: speech.errorMessage) { _, error in
            if let error {
                store.composerText = composerBeforeSpeech
                store.publishMessage(error, severity: .error)
            }
        }
        .onChange(of: store.voiceControlSequence) { _, _ in
            switch store.voiceControlPhase {
            case "press":
                if speech.state == .idle || speech.state == .ready || speech.state == .error {
                    composerBeforeSpeech = store.composerText
                }
                speech.pressBegan()
            case "release":
                speech.pressEnded()
            case "toggle":
                if speech.isCapturing { speech.stopRecording() }
                else {
                    composerBeforeSpeech = store.composerText
                    speech.startRecording()
                }
            case "cancel":
                speech.cancel()
                store.composerText = composerBeforeSpeech
            default:
                break
            }
        }
        .onChange(of: store.foregroundRequestSequence) { _, _ in
            NSApp.activate(ignoringOtherApps: true)
            composerFocused = true
        }
        .onChange(of: showOnboarding) { _, isPresented in
            composerFocused = !isPresented
        }
        .onChange(of: developerDrawerVisible) { wasVisible, isVisible in
            if isVisible {
                sidebarWasVisibleBeforeDrawer = taskRailVisible
                taskRailVisible = false
            } else if wasVisible && sidebarWasVisibleBeforeDrawer {
                taskRailVisible = true
            }
        }
        .onChange(of: store.requestedUIAction) { _, action in
            switch action {
            case "toggle_sidebar":
                toggleTaskSidebar()
                store.requestedUIAction = nil
            case "terminal":
                store.requestedUIAction = nil
                Task { await store.trigger(.openTerminal) }
            case "browser":
                store.requestedUIAction = nil
                Task { await store.trigger(.openBrowser) }
            case "attach":
                store.requestedUIAction = nil
                chooseAttachments()
            case "cancel":
                store.requestedUIAction = nil
                developerDrawerVisible = false
            case "navigate_back":
                store.requestedUIAction = nil
                Task { await store.navigateTaskHistory(delta: -1) }
            case "navigate_forward":
                store.requestedUIAction = nil
                Task { await store.navigateTaskHistory(delta: 1) }
            default:
                break
            }
        }
        .onDisappear {
            transientMessageTask?.cancel()
            Task { await store.syncVoiceState(.idle) }
            store.stop()
            speech.cleanup()
        }
    }

    private var appShell: some View {
        HStack(spacing: 0) {
            if taskRailVisible {
                taskSidebar
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Rectangle()
                    .fill(ArkeyTheme.stroke)
                    .frame(width: 1)
            }
            mainSurface
        }
        .animation(reduceMotion ? .easeOut(duration: 0.08) : .easeOut(duration: 0.16), value: taskRailVisible)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var mainSurface: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(ArkeyTheme.stroke)
                .frame(height: 1)

            VStack(spacing: 12) {
                if store.isCodexMicroLab {
                    CodexMicroLabConfiguratorView(store: store)
                    CodexMicroMappingWorkspaceView(store: store)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .layoutPriority(1)
                } else {
                    if let restriction = store.restrictionMessage {
                        restrictionCard(restriction)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    keyboardWorkspace
                        .frame(maxHeight: .infinity)
                        .layoutPriority(1)
                    LiquidDockStackView(store: store)
                    composer
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 14)
        }
        .background(ArkeyTheme.canvas)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var keyboardWorkspace: some View {
        VStack(spacing: 0) {
            if !store.isCodexMicroLab {
                HStack(spacing: 8) {
                    Image(systemName: "keyboard")
                        .foregroundStyle(ArkeyTheme.textTertiary)
                    if let action = store.selectedAction {
                        Label(action.title, systemImage: action.kind.symbol)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(ArkeyTheme.textSecondary)
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(ArkeyTheme.surfaceHover, in: Capsule())
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(height: 36)

                Rectangle()
                    .fill(ArkeyTheme.stroke)
                    .frame(height: 1)
            }

            KeyboardStageView(store: store)
                .padding(12)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .arkeyPanel(radius: 16)
        .help(store.isCodexMicroLab ? "选择槽位后点击实体键位" : "选择动作后点击键位，或把动作拖到键位")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                toggleTaskSidebar()
            } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(ArkeyIconButtonStyle(tone: taskRailVisible ? .selected : .neutral))
            .help(taskRailVisible ? "隐藏任务侧边栏" : "显示任务侧边栏")
            .accessibilityLabel(taskRailVisible ? "隐藏任务侧边栏" : "显示任务侧边栏")
            .keyboardShortcut("s", modifiers: [.command, .control])

            Text(headerTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ArkeyTheme.textPrimary)
                .lineLimit(1)
                .help("\(headerTitle) · \(workspaceSubtitle)")

            Spacer()
            statusMenu

            Button {
                updateCenterVisible = true
            } label: {
                Image(systemName: updates.hasAvailableUpdate ? "arrow.down.circle.fill" : "arrow.down.circle")
            }
            .buttonStyle(ArkeyUpdateButtonStyle(isAvailable: updates.hasAvailableUpdate))
            .help(updates.hasAvailableUpdate ? "有新的 ARkey 版本可下载" : "打开软件更新")
            .accessibilityLabel(updates.hasAvailableUpdate ? "有新的 ARkey 版本可下载" : "打开软件更新")

            Button {
                diagnosticCenterVisible = true
            } label: {
                Image(systemName: "stethoscope")
            }
            .buttonStyle(ArkeyIconButtonStyle())
            .help("打开诊断中心")
            .accessibilityLabel("打开诊断中心")

            Button {
                firmwareToolVisible = true
            } label: {
                Image(systemName: "cpu")
            }
            .buttonStyle(ArkeyIconButtonStyle())
            .help("打开固件工具")
            .accessibilityLabel("打开固件工具")

            Button {
                showOnboarding = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(ArkeyIconButtonStyle())
            .help("设置与引导")
            .accessibilityLabel("设置与引导")
            .keyboardShortcut(",", modifiers: .command)

            Button { Task { await notch.toggle() } } label: {
                Image(systemName: notch.isExpanded ? "capsule.tophalf.filled" : "capsule")
            }
            .buttonStyle(ArkeyIconButtonStyle(tone: notch.isExpanded ? .selected : .neutral))
            .help(notch.isExpanded ? "收起 ARkey Island" : "展开 ARkey Island")
            .accessibilityLabel(notch.isExpanded ? "收起 ARkey Island" : "展开 ARkey Island")

            Button {
                developerDrawerVisible.toggle()
            } label: {
                Image(systemName: developerDrawerVisible ? "sidebar.right" : "lightbulb.led")
            }
            .buttonStyle(ArkeyIconButtonStyle(tone: developerDrawerVisible ? .selected : .neutral))
            .help("开发者灯效抽屉")
            .accessibilityLabel(developerDrawerVisible ? "隐藏开发者灯效抽屉" : "显示开发者灯效抽屉")
            .keyboardShortcut("l", modifiers: [.command, .option])
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }

    private var statusMenu: some View {
        Menu {
            Button("刷新连接") { Task { await store.refresh() } }
            Button("修复后台服务") { Task { await store.repairDaemonAndRefresh() } }
            Divider()
            Text(connectionSummary)
            Text(store.profile.name)
            Text("\(store.profile.controls.count) controls · \(store.profile.ledCount) RGB")
            Divider()
            Text(store.message)
        } label: {
            statusPill
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(connectionSummary)
        .accessibilityLabel(connectionSummary)
    }

    private var statusPill: some View {
        ZStack {
            Circle()
                .fill(statusColor)
                .frame(width: 18, height: 18)
            Image(systemName: connectionNeedsAttention ? "exclamationmark" : "checkmark")
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(.black.opacity(0.72))
        }
        .frame(width: 28, height: 28)
        .background(ArkeyTheme.surface, in: Circle())
        .overlay(Circle().stroke(ArkeyTheme.stroke, lineWidth: 0.75))
    }

    private func restrictionCard(_ text: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(restrictionTitle)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.78))
                .help(text)
                .accessibilityLabel(restrictionTitle)
                .accessibilityHint(text)
            Spacer()
            Button(restrictionActionTitle) {
                performRestrictionAction()
            }
            .buttonStyle(ArkeyControlButtonStyle(tone: .accent, compact: true))
            Button {
                store.restrictionDismissed = true
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(ArkeyIconButtonStyle(size: 26))
            .help("暂时关闭此提醒")
            .accessibilityLabel("暂时关闭连接提醒")
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(ArkeyTheme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(ArkeyTheme.warning.opacity(0.24)))
    }

    private var taskSidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image("arkey", bundle: .module)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityLabel("Arkey")
                Text("Arkey")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ArkeyTheme.textPrimary)
                Spacer()
                Button {
                    Task { await store.loadImportCandidates() }
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(ArkeyIconButtonStyle(size: 28))
                .help("导入当前 workspace 的 Codex 任务")
                .accessibilityLabel("导入 Codex 任务")
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            .padding(.horizontal, 14)
            .frame(height: 54)

            Rectangle()
                .fill(ArkeyTheme.stroke)
                .frame(height: 1)

            HStack {
                Text("任务")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ArkeyTheme.textSecondary)
                Spacer()
                Menu {
                    ForEach(TaskSortMode.allCases) { mode in
                        Button {
                            Task { await store.persistSortMode(mode) }
                        } label: {
                            if store.sortMode == mode {
                                Label(sortLabel(mode), systemImage: "checkmark")
                            } else {
                                Text(sortLabel(mode))
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ArkeyTheme.textSecondary)
                        .frame(width: 26, height: 24)
                        .background(ArkeyTheme.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("任务排序：\(sortLabel(store.sortMode))")
                .accessibilityLabel("任务排序：\(sortLabel(store.sortMode))")
            }
            .padding(.horizontal, 14)
            .padding(.top, 13)
            .padding(.bottom, 7)

            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(store.sortedTasks) { task in
                        TaskSidebarRow(task: task, store: store)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
        }
        .frame(width: ArkeyTheme.sidebarWidth)
        .background(ArkeyTheme.sidebar)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !store.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(store.attachments, id: \.self) { attachment in
                            attachmentChip(attachment)
                        }
                    }
                }
            }

            TextEditor(text: $store.composerText)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(ArkeyTheme.textPrimary)
                .scrollContentBackground(.hidden)
                .focused($composerFocused)
                .frame(minHeight: 40, maxHeight: 72)
                .padding(.horizontal, 4)
                .accessibilityLabel("发送给当前 Agent 的消息")
                .accessibilityHint("输入文字，Command Return 发送")
                .overlay(alignment: .topLeading) {
                    if store.composerText.isEmpty {
                        Text("下一步…")
                            .font(.system(size: 13))
                            .foregroundStyle(ArkeyTheme.textTertiary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }

            HStack(spacing: 6) {
                Button { chooseAttachments() } label: {
                    Image(systemName: "paperclip")
                }
                .buttonStyle(ArkeyIconButtonStyle(size: 28))
                .help("选择附件")
                .accessibilityLabel("选择附件")

                pttButton
                voiceStatus

                Spacer()

                Button { Task { await store.sendComposer() } } label: {
                    if store.isSending {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.up")
                    }
                }
                .buttonStyle(ArkeyIconButtonStyle(tone: .accent, size: 30))
                .disabled(composerSendDisabled)
                .help(composerSendDisabled ? "输入文字或添加附件后即可发送" : "发送到当前 Agent（⌘↩）")
                .accessibilityLabel(store.isSending ? "正在发送" : "发送到当前 Agent")
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(10)
        .background(ArkeyTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    composerFocused ? ArkeyTheme.accent.opacity(0.55) : (composerHovered ? ArkeyTheme.strokeStrong : ArkeyTheme.stroke),
                    lineWidth: composerFocused ? 1 : 0.75
                )
        }
        .shadow(color: .black.opacity(0.18), radius: composerFocused ? 18 : 10, y: 5)
        .onHover { composerHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: composerHovered)
        .animation(.easeOut(duration: 0.12), value: composerFocused)
    }

    private var pttButton: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(pttBackground)
            Image(systemName: speech.isLocked ? "lock.fill" : "waveform")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(voiceColor)
        }
        .frame(width: 28, height: 28)
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    speech.isCapturing ? voiceColor.opacity(0.55) : (pttHovered ? ArkeyTheme.strokeStrong : .clear),
                    lineWidth: 0.75
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .scaleEffect(pttPointerDown && !reduceMotion ? 0.94 : 1)
        .onHover { pttHovered = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pttPointerDown else { return }
                    pttPointerDown = true
                    if speech.state == .idle || speech.state == .ready || speech.state == .error {
                        composerBeforeSpeech = store.composerText
                    }
                    speech.pressBegan()
                }
                .onEnded { _ in
                    pttPointerDown = false
                    speech.pressEnded()
                }
        )
        .focusable()
        .onKeyPress(.space) {
            toggleVoiceCapture()
            return .handled
        }
        .help("按住录音；350 ms 内双击锁定；识别完成后仍需 Send")
        .accessibilityLabel("Push to talk，\(speech.state.rawValue)")
        .accessibilityHint("按住录音；键盘空格可切换录音")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toggleVoiceCapture() }
        .animation(.easeOut(duration: 0.10), value: pttHovered)
        .animation(.easeOut(duration: 0.08), value: pttPointerDown)
    }

    @ViewBuilder
    private var voiceStatus: some View {
        if speech.state != .idle {
            HStack(spacing: 4) {
                Circle().fill(voiceColor).frame(width: 5, height: 5)
                Text(speech.state.rawValue.uppercased())
            }
            .font(.system(size: 7, weight: .bold, design: .monospaced))
            .foregroundStyle(voiceColor)
        }
    }

    private var commandSurfaceBackground: some View {
        ArkeyTheme.window
        .ignoresSafeArea()
    }

    private var voiceColor: Color {
        switch speech.state {
        case .recording, .locked: ArkeyTheme.accent
        case .processing, .ready: .white
        case .error: ArkeyTheme.danger
        case .idle: .white.opacity(0.72)
        }
    }

    private var pttBackground: Color {
        if speech.isCapturing { return voiceColor.opacity(0.17) }
        if pttPointerDown { return ArkeyTheme.surfacePressed }
        if pttHovered { return ArkeyTheme.surfaceHover }
        return .clear
    }

    private var composerSendDisabled: Bool {
        (store.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && store.attachments.isEmpty)
            || store.isSending
    }

    private var workspaceSubtitle: String {
        if store.isCodexMicroLab { return "Local hardware configuration" }
        guard let task = store.selectedTask else { return store.profile.name }
        var parts = [task.state.title]
        if let effort = task.reasoningEffort { parts.append(effort) }
        if task.serviceTier != nil { parts.append("fast") }
        return parts.joined(separator: " · ")
    }

    private var headerTitle: String {
        store.isCodexMicroLab ? "Codex Micro Lab" : (store.selectedTask?.title ?? "Command surface")
    }

    private var statusColor: Color {
        if store.isCodexMicroLab || (store.isUSBV2Ready && store.appServerReady) {
            return ArkeyTheme.accent
        }
        if store.transport == .unavailable { return ArkeyTheme.danger }
        return ArkeyTheme.warning
    }

    private var connectionNeedsAttention: Bool {
        !store.isCodexMicroLab && !(store.isUSBV2Ready && store.appServerReady)
    }

    private var connectionSummary: String {
        if store.isUSBV2Ready && store.appServerReady { return "Keyboard and Codex connected" }
        if store.isUSBV2Ready { return "Keyboard connected · Codex waiting" }
        switch store.transport {
        case .usb: return "USB requires attention"
        case .bluetooth: return "Bluetooth · limited controls"
        case .simulator: return "Simulator"
        case .unavailable: return "Keyboard unavailable"
        }
    }

    private var restrictionTitle: String {
        if store.transport == .bluetooth { return "仅蓝牙连接" }
        if store.transport != .usb { return "未识别 USB 键盘" }
        if store.deviceSupport == "via-only" { return "固件不支持任务键" }
        if store.deviceSupport != "arkey" { return "硬件尚未验证" }
        if store.firmwareExtensionVersion != 2 { return "需要 v2 固件" }
        if !store.profileMatches { return "键盘布局不匹配" }
        if !store.authenticated { return "需要登录 Codex" }
        if !store.appServerReady { return "Codex 未连接" }
        return "连接需要处理"
    }

    private var restrictionActionTitle: String {
        if store.transport != .usb { return "刷新" }
        if store.deviceSupport != "arkey"
            || store.firmwareExtensionVersion != 2
            || !store.profileMatches {
            return "查看"
        }
        if !store.authenticated { return "登录" }
        return "修复"
    }

    private func performRestrictionAction() {
        if store.transport != .usb {
            Task { await store.refresh() }
            return
        }
        if store.deviceSupport != "arkey"
            || store.firmwareExtensionVersion != 2
            || !store.profileMatches
            || !store.authenticated {
            showOnboarding = true
            return
        }
        Task { await store.repairDaemonAndRefresh() }
    }

    private func sortLabel(_ mode: TaskSortMode) -> String {
        switch mode {
        case .priority: "Priority"
        case .recent: "Recent"
        case .pinned: "Pinned"
        case .custom: "Custom"
        }
    }

    private func attachmentChip(_ attachment: URL) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "photo")
                .font(.system(size: 9, weight: .medium))
            Text(attachment.lastPathComponent)
                .lineLimit(1)
                .frame(maxWidth: 150)
            Button {
                store.attachments.removeAll { $0 == attachment }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(ArkeyIconButtonStyle(size: 18))
            .help("移除 \(attachment.lastPathComponent)")
            .accessibilityLabel("移除附件 \(attachment.lastPathComponent)")
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(ArkeyTheme.textSecondary)
        .padding(.leading, 8)
        .padding(.trailing, 3)
        .frame(height: 25)
        .background(ArkeyTheme.surfaceHover, in: Capsule())
        .overlay(Capsule().stroke(ArkeyTheme.stroke, lineWidth: 0.75))
        .help(attachment.lastPathComponent)
    }

    private func toggleTaskSidebar() {
        if developerDrawerVisible {
            developerDrawerVisible = false
            taskRailVisible = true
        } else {
            taskRailVisible.toggle()
        }
    }

    private func toggleVoiceCapture() {
        if speech.isCapturing {
            speech.stopRecording()
        } else {
            composerBeforeSpeech = store.composerText
            speech.startRecording()
        }
    }

    private var workflowRequest: String? {
        guard let action = store.requestedUIAction,
              action != "toggle_sidebar",
              action != "navigate_back",
              action != "navigate_forward" else { return nil }
        return action
    }

    private func mergeVoiceTranscript(_ transcript: String) -> String {
        let base = composerBeforeSpeech
        guard !base.isEmpty else { return transcript }
        let separator = base.last?.isWhitespace == true ? "" : " "
        return base + separator + transcript
    }

    private func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.prompt = "添加到 Composer"
        guard panel.runModal() == .OK else { return }
        store.attachments = panel.urls
        store.message = "已选择 \(store.attachments.count) 张本地图片；仅随下一次 Send 进入 App Server input。"
    }

    private func presentTransientMessage(_ message: String, severity: CommandSurfaceMessageSeverity) {
        let value = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        transientMessageTask?.cancel()
        withAnimation(reduceMotion ? .easeOut(duration: 0.08) : .easeOut(duration: 0.16)) {
            transientMessageSeverity = severity
            transientMessage = value
        }
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: value,
                .priority: severity == .error
                    ? NSAccessibilityPriorityLevel.high.rawValue
                    : NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
        guard severity != .error else { return }
        let duration: UInt64 = severity == .warning ? 5_000_000_000 : 2_600_000_000
        transientMessageTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: duration)
            guard !Task.isCancelled else { return }
            dismissTransientMessage()
        }
    }

    private func dismissTransientMessage() {
        transientMessageTask?.cancel()
        withAnimation(reduceMotion ? .easeOut(duration: 0.08) : .easeOut(duration: 0.16)) {
            transientMessage = nil
        }
    }

    private var transientMessageSymbol: String {
        switch transientMessageSeverity {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var transientMessageColor: Color {
        switch transientMessageSeverity {
        case .info: ArkeyTheme.accent
        case .warning: ArkeyTheme.warning
        case .error: ArkeyTheme.danger
        }
    }

    private var transientMessageAccessibilityLabel: String {
        guard let transientMessage else { return "" }
        switch transientMessageSeverity {
        case .info: return transientMessage
        case .warning: return "提醒：\(transientMessage)"
        case .error: return "错误：\(transientMessage)"
        }
    }
}

private struct TaskSidebarRow: View {
    let task: AgentTaskSlot
    @ObservedObject var store: CommandSurfaceStore
    @State private var isHovered = false
    @State private var pendingSelection: Task<Void, Never>?

    private var isSelected: Bool { task.id == store.selectedTaskId }
    private var pendingCount: Int { task.pendingApprovalCount + task.pendingStructuredRequestCount }
    private var stateColor: Color {
        task.state == .unassigned
            ? ArkeyTheme.textTertiary
            : Color(arkeyHex: store.semanticHex(for: task.state))
    }

    var body: some View {
        Button {
            handleTaskClick()
        } label: {
            HStack(spacing: 9) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().stroke(Color.white.opacity(0.20), lineWidth: 0.5))

                Text(task.title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(ArkeyTheme.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 2)

                if let attentionSymbol {
                    Image(systemName: attentionSymbol)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(stateColor)
                }

                if pendingCount > 0 {
                    Text("\(pendingCount)")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.black.opacity(0.75))
                        .frame(minWidth: 17, minHeight: 17)
                        .background(ArkeyTheme.warning, in: Circle())
                } else if task.pinned && !isHovered {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(ArkeyTheme.textTertiary)
                }

                Color.clear.frame(width: 18, height: 1)
            }
            .padding(.vertical, 7)
        }
        .buttonStyle(ArkeySidebarButtonStyle(isSelected: isSelected))
        .overlay(alignment: .trailing) {
            Menu {
                taskActions
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ArkeyTheme.textSecondary)
                    .frame(width: 27, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(isHovered ? 1 : 0.34)
            .help("更多任务操作")
            .accessibilityLabel("\(task.title) 的更多操作")
            .padding(.trailing, 4)
        }
        .onHover { isHovered = $0 }
        .onDisappear { pendingSelection?.cancel() }
        .contextMenu { taskActions }
        .accessibilityLabel("\(task.title)，\(task.state.title)")
        .accessibilityHint("单击选择，双击在 Codex 中前置；更多菜单可固定任务")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help("\(task.title) · \(taskSummary)")
    }

    private var attentionSymbol: String? {
        switch task.state {
        case .requiresInput: "exclamationmark.circle.fill"
        case .error: "xmark.octagon.fill"
        default: nil
        }
    }

    private var taskSummary: String {
        var parts = [task.state.title]
        if let effort = task.reasoningEffort { parts.append(effort) }
        if pendingCount > 0 { parts.append("\(pendingCount) 项待处理") }
        return parts.joined(separator: " · ")
    }

    private func handleTaskClick() {
        let clickCount = max(1, NSApp.currentEvent?.clickCount ?? 1)
        pendingSelection?.cancel()

        if clickCount >= 2 {
            pendingSelection = nil
            Task { await store.chooseTask(task.id, bringToFront: true) }
        } else {
            pendingSelection = Task {
                try? await Task.sleep(nanoseconds: 220_000_000)
                guard !Task.isCancelled else { return }
                await store.chooseTask(task.id)
            }
        }
    }

    @ViewBuilder
    private var taskActions: some View {
        Button("在 Codex 中前置") {
            Task { await store.chooseTask(task.id, bringToFront: true) }
        }
        Button(task.pinned ? "取消固定" : "固定任务") {
            Task { await store.togglePinned(task.id) }
        }
        if store.sortMode == .custom {
            Divider()
            Button("向上移动") { Task { await store.moveCustomTask(task.id, delta: -1) } }
            Button("向下移动") { Task { await store.moveCustomTask(task.id, delta: 1) } }
        }
    }
}
