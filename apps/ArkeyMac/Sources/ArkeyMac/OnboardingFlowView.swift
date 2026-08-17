import AppKit
import SwiftUI

struct OnboardingFlowView: View {
    @ObservedObject var store: CommandSurfaceStore
    @ObservedObject var speech: SpeechCoordinator
    @Binding var isPresented: Bool
    @AppStorage("arkey.onboarding.completed") private var onboardingCompleted = false
    @AppStorage("arkey.workspace.root") private var workspaceRoot = ""
    @State private var stepIndex = 0
    @State private var isBusy = false
    @State private var preflightMessage = "尚未运行固件 preflight。"
    @State private var loginMessage = "将复用当前 ~/.codex 的 ChatGPT 登录。"
    @State private var recommendedBindingsExpanded = false

    private let steps: [(String, String)] = [
        ("设备检测", "cable.connector"),
        ("Firmware / Profile", "cpu"),
        ("ChatGPT 登录", "person.crop.circle.badge.checkmark"),
        ("项目根目录", "folder"),
        ("麦克风与语音", "waveform"),
        ("快速绑定", "keyboard"),
        ("灯效校准", "lightbulb.led")
    ]

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(ArkeyTheme.stroke).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(steps[stepIndex].0)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(ArkeyTheme.textPrimary)
                        Text("\(stepIndex + 1) / \(steps.count)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(ArkeyTheme.textTertiary)
                            .accessibilityLabel("步骤 \(stepIndex + 1)，共 \(steps.count) 步")
                    }
                    Spacer()
                    Button("跳过设置") { finish(skipped: true) }
                        .buttonStyle(ArkeyControlButtonStyle(compact: true))
                }
                .padding(26)

                ScrollView {
                    stepContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 26)
                        .padding(.bottom, 24)
                }

                Rectangle().fill(ArkeyTheme.stroke).frame(height: 1)
                HStack {
                    Button("上一步") { stepIndex = max(0, stepIndex - 1) }
                        .disabled(stepIndex == 0)
                        .buttonStyle(ArkeyControlButtonStyle())
                    Spacer()
                    if isBusy { ProgressView().controlSize(.small) }
                    Button(stepIndex == steps.count - 1 ? "进入 Command Surface" : "继续") {
                        if stepIndex == steps.count - 1 { finish(skipped: false) }
                        else { stepIndex += 1 }
                    }
                    .buttonStyle(ArkeyControlButtonStyle(tone: .accent))
                }
                .padding(18)
            }
        }
        .frame(width: 880, height: 590)
        .background(ArkeyTheme.window)
        .preferredColorScheme(.dark)
        .onChange(of: stepIndex) { oldStep, newStep in
            if newStep == 5 {
                store.setQuickBindingEnabled(true)
            } else if oldStep == 5 {
                store.setQuickBindingEnabled(false)
            }
        }
        .onDisappear {
            store.setQuickBindingEnabled(false)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Arkey setup", systemImage: "sparkles.rectangle.stack")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ArkeyTheme.textPrimary)
                .padding(.bottom, 16)
            ForEach(steps.indices, id: \.self) { index in
                Button {
                    stepIndex = index
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: steps[index].1)
                            .frame(width: 17)
                        Text(steps[index].0)
                        Spacer()
                        if index < stepIndex { Image(systemName: "checkmark").font(.caption.bold()) }
                    }
                }
                .buttonStyle(ArkeySidebarButtonStyle(isSelected: index == stepIndex))
                .foregroundStyle(index == stepIndex ? ArkeyTheme.textPrimary : ArkeyTheme.textSecondary)
                .accessibilityAddTraits(index == stepIndex ? .isSelected : [])
            }
            Spacer()
        }
        .padding(22)
        .frame(width: 225)
        .background(ArkeyTheme.sidebar)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch stepIndex {
        case 0: deviceStep
        case 1: firmwareStep
        case 2: loginStep
        case 3: workspaceStep
        case 4: speechStep
        case 5: bindingStep
        default: lightingStep
        }
    }

    private var deviceStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            callout(
                title: deviceTitle,
                detail: deviceDetail,
                color: store.isUSBV2Ready ? ArkeyTheme.accent : ArkeyTheme.warning,
                symbol: store.isUSBV2Ready ? "checkmark.circle.fill" : "cable.connector"
            )
            detailGrid([
                ("设备", store.profile.name),
                ("控件", "\(store.profile.controls.count) physical"),
                ("RGB", "\(store.profile.ledCount) LEDs"),
                ("传输", store.transport.rawValue.uppercased())
            ])
            Button("修复并重新检测") {
                Task {
                    isBusy = true
                    await store.repairDaemonAndRefresh()
                    isBusy = false
                }
            }
            .buttonStyle(ArkeyControlButtonStyle(tone: .accent))
        }
    }

    private var firmwareStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            callout(
                title: store.firmwareExtensionVersion == 2 ? "ARkey v2 已就绪" : "建议准备 v2 firmware",
                detail: "仅检查目标、配置和恢复条件；不会刷写。",
                color: store.firmwareExtensionVersion == 2 ? ArkeyTheme.accent : ArkeyTheme.warning,
                symbol: "shield.lefthalf.filled"
            )
            Text(preflightMessage)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
                .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Button("运行 Firmware Preflight") { runFirmwarePreflight() }
                    .buttonStyle(ArkeyControlButtonStyle(tone: .accent))
                Button("打开 Recovery 指引") { openRecoveryGuide() }
                    .buttonStyle(ArkeyControlButtonStyle())
            }
            Text("真实刷写仍需再次确认。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var loginStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            callout(
                title: store.authenticated ? "ChatGPT 已登录" : "连接 Codex App Server",
                detail: loginMessage,
                color: store.authenticated ? ArkeyTheme.accent : ArkeyTheme.textSecondary,
                symbol: "person.crop.circle.badge.checkmark"
            )
            Text("通过 Codex App Server 登录 · 不保存凭据或对话")
                .foregroundStyle(.secondary)
                .help("daemon 通过 codex app-server 建立会话，ARkey 不保存 token、prompt 或回复")
            HStack {
                Button("使用 ChatGPT 登录") { startLogin() }
                    .buttonStyle(ArkeyControlButtonStyle(tone: .accent))
                Button("刷新状态") { Task { await store.refresh() } }
                    .buttonStyle(ArkeyControlButtonStyle())
            }
        }
    }

    private var workspaceStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            callout(
                title: "选择默认项目根目录",
                detail: "仅管理显式注册或导入的任务。",
                color: ArkeyTheme.accent,
                symbol: "folder.badge.gearshape"
            )
            HStack {
                Image(systemName: "folder")
                Text(workspaceRoot.isEmpty ? "未选择" : workspaceRoot)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("选择…") { chooseWorkspace() }
                    .buttonStyle(ArkeyControlButtonStyle(compact: true))
            }
            .padding(13)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var speechStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            callout(
                title: speech.permissionStatus.isAuthorized ? "语音权限已允许" : "启用 Push to talk",
                detail: "按住说话；识别只填入输入框，不会自动发送。",
                color: speech.permissionStatus.isAuthorized ? ArkeyTheme.accent : ArkeyTheme.warning,
                symbol: "waveform.badge.microphone"
            )
            detailGrid([
                ("麦克风 + Speech", speech.permissionStatus.rawValue),
                ("Recognizer", speech.isRecognizerAvailable ? "available" : "unavailable")
            ])
            Button("请求麦克风与语音识别权限") { speech.requestPermissions() }
                .buttonStyle(ArkeyControlButtonStyle(tone: .accent))
        }
    }

    private var bindingStep: some View {
        VStack(alignment: .leading, spacing: 15) {
            callout(
                title: "快速绑定建议",
                detail: "选择功能后按实体键。",
                color: ArkeyTheme.accent,
                symbol: "keyboard.badge.ellipsis"
            )
            HStack(spacing: 10) {
                Circle()
                    .fill(store.isCapturing ? ArkeyTheme.accent : ArkeyTheme.warning)
                    .frame(width: 8, height: 8)
                Text("当前：\(store.selectedAction?.title ?? "无可绑定功能")")
                    .font(.callout.monospaced().weight(.semibold))
                Spacer()
                Button(store.continuousBindingMode ? "停止连续绑定" : "开始连续绑定") {
                    store.setQuickBindingEnabled(!store.continuousBindingMode)
                }
                .buttonStyle(ArkeyControlButtonStyle(tone: store.continuousBindingMode ? .selected : .accent))
            }
            .padding(11)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            DisclosureGroup("推荐布局（\(defaultBindings.count)）", isExpanded: $recommendedBindingsExpanded) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 8)], spacing: 8) {
                    ForEach(Array(defaultBindings.enumerated()), id: \.offset) { _, item in
                        HStack {
                            Text(item.0).font(.caption.monospaced().bold())
                            Spacer()
                            Text(item.1).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
                    }
                }
                .padding(.top, 8)
            }
            .help("推荐布局不会自动应用；也可在主界面拖动任意动作到可绑定控件")
            .accessibilityHint("推荐布局不会自动应用")
        }
    }

    private var lightingStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            callout(
                title: "校准语义覆盖与全局氛围",
                detail: "任务灯显示状态，全局光仅作氛围。",
                color: Color(arkeyHex: "#00FF4C"),
                symbol: "lightbulb.led.fill"
            )
            HStack(spacing: 12) {
                calibrationSwatch("Thinking", "#304FFE", .shallowBreath)
                calibrationSwatch("Complete", "#00FF4C", .riseFade)
                calibrationSwatch("Input", "#FF6D00", .doublePulse)
                calibrationSwatch("Error", "#FF0033", .doublePulse)
            }
            Button(store.isPreviewing ? "停止校准" : "预览校准灯") {
                Task {
                    if store.isPreviewing { await store.stopLightingPreview() }
                    else {
                        store.developerEffect.target = .globalAtmosphere
                        store.developerEffect.hexColor = "#304FFE"
                        store.developerEffect.primitive = .shallowBreath
                        await store.previewLighting()
                    }
                }
            }
            .buttonStyle(ArkeyControlButtonStyle(tone: store.isPreviewing ? .danger : .accent))
        }
    }

    private var deviceDetail: String {
        switch store.transport {
        case .usb where store.deviceSupport == "arkey": "USB ARkey Raw HID 已出现；v2 与 profile hash 匹配后开放完整任务键和灯效同步。"
        case .usb where store.deviceSupport == "via-only": "检测到 VIA Raw HID，但不是 ARkey 协议；当前不能接管任务键或同步单键任务灯。"
        case .usb: "检测到未知 USB Raw HID；当前不能将其视为 ARkey firmware。"
        case .bluetooth: "Bluetooth 可继续正常打字，但本协议没有硬件任务键接管或灯效同步。"
        case .simulator: "正在使用模拟布局；可设计和预览绑定。"
        case .unavailable: "请用 USB 连接 Q6 Pro，或跳过后在主界面继续使用模拟布局。"
        }
    }

    private var deviceTitle: String {
        switch store.transport {
        case .usb where store.deviceSupport == "arkey": "已检测到 ARkey USB 设备"
        case .usb where store.deviceSupport == "via-only": "已检测到 VIA-only USB 设备"
        case .usb: "已检测到未知 USB 设备"
        case .bluetooth: "已检测到 Bluetooth 键盘"
        case .simulator: "正在使用模拟布局"
        case .unavailable: "尚未检测到目标键盘"
        }
    }

    private var defaultBindings: [(String, String)] {
        [("F1–F6", "Agent Keys"), ("F7", "Approve"), ("F8", "Decline"), ("F9", "PTT"), ("F10", "Send"), ("F11", "Continue"), ("F12", "Fast"), ("Knob", "Reasoning")]
    }

    private func runFirmwarePreflight() {
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                let output = try await ArkeyCommand.rpc("firmware.preflight", payload: [
                    "profileId": store.profile.profileId,
                    "layoutHash": store.profile.layoutHash,
                    "dryRun": true
                ])
                preflightMessage = output
            } catch {
                preflightMessage = "Preflight 未通过：\(error.localizedDescription)\n未执行任何 flash。"
            }
        }
    }

    private func startLogin() {
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                let output = try await ArkeyCommand.rpc("account.login.start")
                if let data = output.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let rawURL = json["verificationUrl"] as? String ?? json["authUrl"] as? String ?? json["url"] as? String,
                   let url = URL(string: rawURL) {
                    NSWorkspace.shared.open(url)
                    if let userCode = json["userCode"] as? String {
                        loginMessage = "已打开设备登录页；请输入验证码 \(userCode)。完成后 ARkey 会自动刷新登录状态。"
                    } else {
                        loginMessage = "已在浏览器打开官方登录页，等待 App Server 完成通知。"
                    }
                } else {
                    loginMessage = "登录请求已发送，等待 App Server 完成通知。"
                }
            } catch {
                loginMessage = error.localizedDescription
            }
        }
    }

    private func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "设为项目根目录"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        workspaceRoot = url.path
        Task {
            do {
                _ = try await ArkeyCommand.rpc("settings.update", payload: ["workspaceRoot": url.path])
            } catch {
                store.publishMessage("项目目录已保存在客户端；daemon 暂未确认：\(error.localizedDescription)", severity: .warning)
            }
        }
    }

    private func openRecoveryGuide() {
        var candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("docs/FIRMWARE.md"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("README.md")
        ]
        if let resourceURL = Bundle.main.resourceURL {
            candidates.insert(
                resourceURL.appendingPathComponent("ArkeyRuntime/docs/FIRMWARE.md"),
                at: 0
            )
        }
        if let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            NSWorkspace.shared.open(url)
        }
    }

    private func finish(skipped: Bool) {
        onboardingCompleted = true
        store.restrictionDismissed = false
        store.message = skipped ? "Onboarding 已跳过；连接限制会持续显示在主界面。" : "Command Surface 设置完成。"
        let stopTask = store.setQuickBindingEnabled(false)
        Task {
            await stopTask?.value
            _ = try? await ArkeyCommand.rpc("settings.update", payload: ["onboardingSkipped": skipped])
        }
        isPresented = false
    }

    private func callout(title: String, detail: String, color: Color, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(color.opacity(0.28)))
    }

    private func detailGrid(_ values: [(String, String)]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                VStack(alignment: .leading, spacing: 4) {
                    Text(value.0).font(.caption).foregroundStyle(.secondary)
                    Text(value.1).font(.callout.monospaced()).lineLimit(1)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func calibrationSwatch(_ title: String, _ hex: String, _ primitive: LightingPrimitive) -> some View {
        Button {
            store.developerEffect.hexColor = hex
            store.developerEffect.primitive = primitive
            store.developerEffect.target = .selectedTask
            Task { await store.previewLighting() }
        } label: {
            VStack(spacing: 8) {
                Circle().fill(Color(arkeyHex: hex)).frame(width: 32, height: 32).shadow(color: Color(arkeyHex: hex), radius: 9)
                Text(title).font(.caption)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(ArkeyTileButtonStyle())
    }
}
