import SwiftUI

struct DeveloperLightingDrawer: View {
    @ObservedObject var store: CommandSurfaceStore
    @ObservedObject var controller: ArkeyController
    @Binding var isPresented: Bool
    @AppStorage("arkey.legacyExperiments.enabled") private var legacyExperimentsEnabled = false
    @State private var semanticState: AgentTaskState = .working
    @State private var advancedParametersExpanded = false
    @State private var showingHardwareReason = false

    private var primitives: [LightingPrimitive] {
        if store.developerEffect.target == .globalAtmosphere {
            return LightingPrimitive.allCases
        }
        return [.off, .solid, .shallowBreath, .breath, .doublePulse, .riseFade, .pressFlash]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(ArkeyTheme.stroke)
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    targetSection
                    semanticSection
                    primitiveSection
                    parameterSection
                    hardwareSection
                    legacySection
                }
                .padding(18)
            }
            Divider().overlay(ArkeyTheme.stroke)
            previewBar
        }
        .frame(width: ArkeyTheme.drawerWidth)
        .foregroundStyle(ArkeyTheme.textPrimary)
        .tint(ArkeyTheme.accent)
        .background(ArkeyTheme.sidebar)
        .overlay(alignment: .leading) { Rectangle().fill(ArkeyTheme.stroke).frame(width: 1) }
        .onDisappear { Task { await store.stopLightingPreview() } }
    }

    private var header: some View {
        HStack {
            Text("LIGHT LAB")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(ArkeyTheme.textPrimary)
                .help("共享 EffectSpec · 最长 30 秒")
            Spacer()
            Button {
                Task { await store.stopLightingPreview() }
                isPresented = false
            } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(ArkeyIconButtonStyle())
            .accessibilityLabel("隐藏开发者抽屉")
            .help("隐藏开发者抽屉")
        }
        .padding(16)
    }

    private var targetSection: some View {
        drawerGroup("目标", symbol: "scope") {
            Picker("Target", selection: $store.developerEffect.target) {
                Text("选中键").tag(EffectTarget.selectedKey)
                Text("任务槽").tag(EffectTarget.selectedTask)
                Text("全局氛围").tag(EffectTarget.globalAtmosphere)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("目标")
            if store.developerEffect.target == .selectedKey {
                Picker("物理控件", selection: Binding(
                    get: { store.developerEffect.targetControlId ?? store.selectedControlId ?? store.profile.controls.first?.id },
                    set: { store.developerEffect.targetControlId = $0 }
                )) {
                    Text("跟随当前选择").tag(String?.none)
                    ForEach(store.profile.controls.filter(\.bindable)) { control in
                        Text(control.label.isEmpty ? control.id : control.label).tag(Optional(control.id))
                    }
                }
                .labelsHidden()
                .accessibilityLabel("物理控件")
            }
        }
    }

    private var semanticSection: some View {
        drawerGroup("语义状态", symbol: "circle.hexagongrid.fill") {
            Picker("状态", selection: $semanticState) {
                ForEach(AgentTaskState.allCases) { state in
                    Text(state.title).tag(state)
                }
            }
            .labelsHidden()
            .accessibilityLabel("语义状态")
            .onChange(of: semanticState) { _, state in
                store.developerEffect.hexColor = store.semanticHex(for: state)
                switch state {
                case .unassigned: store.developerEffect.primitive = .off
                case .idle: store.developerEffect.primitive = .shallowBreath
                case .working: store.developerEffect.primitive = .shallowBreath
                case .unread: store.developerEffect.primitive = .riseFade
                case .requiresInput, .error: store.developerEffect.primitive = .doublePulse
                }
            }
            HStack {
                ColorPicker("颜色", selection: effectColorBinding, supportsOpacity: false)
                Text(store.developerEffect.hexColor.uppercased())
                    .font(.caption.monospaced())
                    .foregroundStyle(ArkeyTheme.textSecondary)
            }
        }
    }

    private var primitiveSection: some View {
        drawerGroup("Primitive", symbol: "waveform.path") {
            Picker("效果", selection: $store.developerEffect.primitive) {
                ForEach(primitives) { primitive in
                    Text(primitiveLabel(primitive)).tag(primitive)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityLabel("效果")
            .accessibilityHint(store.developerEffect.target == .globalAtmosphere ? "选择要预览的灯效" : "部分多键效果仅适用于全局氛围")
            .help(store.developerEffect.target == .globalAtmosphere ? "选择灯效" : "Snake、Typing 与 Complete wave 仅用于全局或多键目标")
        }
    }

    private var parameterSection: some View {
        drawerGroup("参数", symbol: "slider.horizontal.3") {
            parameterSlider("亮度", value: $store.developerEffect.brightness, range: 0...1, valueText: percentage(store.developerEffect.brightness))
            parameterSlider("速度", value: $store.developerEffect.speed, range: 0.08...4, valueText: String(format: "%.2fx", store.developerEffect.speed))
            DisclosureGroup("高级", isExpanded: $advancedParametersExpanded) {
                VStack(spacing: 10) {
                    parameterSlider("Phase", value: $store.developerEffect.phase, range: 0...1, valueText: String(format: "%.2f", store.developerEffect.phase))
                    parameterSlider("全局混合", value: $store.developerEffect.atmosphereMix, range: 0...0.3, valueText: percentage(store.developerEffect.atmosphereMix))
                    HStack {
                        Text("时长")
                        Spacer()
                        Text("\(store.developerEffect.durationMs ?? 600) ms")
                            .foregroundStyle(ArkeyTheme.textSecondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: Binding(
                            get: { Double(store.developerEffect.durationMs ?? 600) },
                            set: { store.developerEffect.durationMs = Int($0) }
                        ),
                        in: 100...30_000,
                        step: 100
                    )
                    .accessibilityLabel("时长")
                    .accessibilityValue("\(store.developerEffect.durationMs ?? 600) 毫秒")
                    Stepper("Seed \(store.developerEffect.seed)", value: $store.developerEffect.seed, in: 0...65_535)
                }
                .padding(.top, 8)
            }
        }
    }

    private var hardwareSection: some View {
        drawerGroup("硬件", symbol: "keyboard.badge.ellipsis") {
            Toggle("同步", isOn: $store.hardwarePreviewEnabled)
                .disabled(store.hardwarePreviewDisabledReason != nil)
                .accessibilityLabel("同步硬件预览")
            if let reason = store.hardwarePreviewDisabledReason {
                Button {
                    showingHardwareReason.toggle()
                } label: {
                    Label("当前不可同步", systemImage: "exclamationmark.triangle")
                }
                .buttonStyle(ArkeyControlButtonStyle(compact: true))
                .help(reason)
                .accessibilityLabel("当前不可同步，查看原因")
                .popover(isPresented: $showingHardwareReason, arrowEdge: .trailing) {
                    Text(reason)
                        .font(.callout)
                        .foregroundStyle(ArkeyTheme.textPrimary)
                        .padding(14)
                        .frame(width: 300, alignment: .leading)
                        .background(ArkeyTheme.window)
                        .preferredColorScheme(.dark)
                }
            } else {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(ArkeyTheme.accent)
                    .help("USB v2 · profile hash 已匹配")
                    .accessibilityLabel("USB v2 与 profile hash 已匹配")
            }
        }
    }

    private var legacySection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("启用", isOn: $legacyExperimentsEnabled)
                    .accessibilityLabel("启用 Legacy experiments")
                Text("可能通过 System Events 控制前台应用")
                    .font(.caption2)
                    .foregroundStyle(ArkeyTheme.warning)
                HStack(spacing: 5) {
                    ForEach([AgentControlAction.optionOne, .optionTwo, .optionThree, .yes, .no, .enter]) { action in
                        Button {
                            Task { await controller.performAgentAction(action) }
                        } label: {
                            Image(systemName: action.symbol)
                        }
                        .buttonStyle(ArkeyIconButtonStyle(size: 28))
                        .accessibilityLabel(action.title)
                        .help("Legacy System Events：\(action.title)")
                    }
                }
                .disabled(!legacyExperimentsEnabled)
                HStack {
                    Button("启动 daemon") { Task { await controller.start() } }
                        .buttonStyle(ArkeyControlButtonStyle(compact: true))
                    Button("停止") { Task { await controller.stop() } }
                        .buttonStyle(ArkeyControlButtonStyle(tone: .danger, compact: true))
                    Button("Restore") { Task { await controller.restore() } }
                        .buttonStyle(ArkeyControlButtonStyle(compact: true))
                }
                .disabled(!legacyExperimentsEnabled)
                HStack {
                    Button("随机灯") { Task { await controller.testRandom() } }
                        .buttonStyle(ArkeyControlButtonStyle(compact: true))
                    Button("文本回放") { Task { await controller.playText() } }
                        .buttonStyle(ArkeyControlButtonStyle(compact: true))
                }
                .disabled(!legacyExperimentsEnabled)
                TextField("Legacy 文本回放", text: $controller.sampleText)
                    .disabled(!legacyExperimentsEnabled)
            }
            .padding(.top, 9)
        } label: {
            Label("Legacy experiments", systemImage: "hammer")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ArkeyTheme.textSecondary)
        }
    }

    private var previewBar: some View {
        HStack {
            if store.isPreviewing {
                Button("停止并恢复") { Task { await store.stopLightingPreview() } }
                    .buttonStyle(ArkeyControlButtonStyle(tone: .danger))
                Spacer()
                Text("LIVE")
                    .font(.caption2.bold().monospaced())
                    .foregroundStyle(ArkeyTheme.accent)
            } else {
                Button("预览") {
                    Task { await store.previewLighting() }
                }
                .buttonStyle(ArkeyControlButtonStyle(tone: .accent))
            }
        }
        .padding(14)
        .background(ArkeyTheme.surfaceRaised)
    }

    private var effectColorBinding: Binding<Color> {
        Binding(
            get: { Color(arkeyHex: store.developerEffect.hexColor) },
            set: { store.developerEffect.hexColor = $0.arkeyHex() }
        )
    }

    @ViewBuilder
    private func drawerGroup<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(ArkeyTheme.textSecondary)
                .textCase(.uppercase)
            content()
        }
        .padding(12)
        .arkeyPanel(radius: 13)
    }

    private func parameterSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, valueText: String) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(valueText).foregroundStyle(ArkeyTheme.textSecondary).monospacedDigit()
            }
            Slider(value: value, in: range)
                .accessibilityLabel(title)
                .accessibilityValue(valueText)
        }
    }

    private func percentage(_ value: Double) -> String { "\(Int(value * 100))%" }

    private func primitiveLabel(_ primitive: LightingPrimitive) -> String {
        switch primitive {
        case .off: "Off"
        case .solid: "Solid"
        case .shallowBreath: "Shallow breath"
        case .breath: "Breath"
        case .doublePulse: "Double pulse"
        case .riseFade: "Rise–fade"
        case .pressFlash: "Press flash"
        case .snake: "Snake"
        case .typing: "Typing"
        case .completeWave: "Complete wave"
        }
    }
}
