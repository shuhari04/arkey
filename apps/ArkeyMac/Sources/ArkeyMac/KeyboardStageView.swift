import SwiftUI

struct KeyboardStageView: View {
    @ObservedObject var store: CommandSurfaceStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredControlId: String?
    @State private var dropTargetControlId: String?

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 0.25 : 1.0 / 30.0)) { timeline in
            GeometryReader { proxy in
                let geometry = StageGeometry(profile: store.displayedKeyboardProfile, size: proxy.size)
                ZStack(alignment: .topLeading) {
                    stageBackground
                    ForEach(store.displayedKeyboardProfile.controls) { control in
                        controlView(control, date: timeline.date, geometry: geometry)
                    }
                }
            }
        }
        .aspectRatio(store.displayedKeyboardProfile.maxX / max(1, store.displayedKeyboardProfile.maxY), contentMode: .fit)
        .anchorPreference(key: CodexMicroEndpointPreferenceKey.self, value: .bounds) {
            ["keyboard-stage": $0]
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(store.displayedKeyboardProfile.name) 模拟布局")
    }

    private var stageBackground: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(Color.black.opacity(0.13))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(ArkeyTheme.stroke, lineWidth: 0.75)
            }
    }

    @ViewBuilder
    private func controlView(_ control: KeyboardControl, date: Date, geometry: StageGeometry) -> some View {
        if store.isCodexMicroLab {
            codexMicroControlView(control, date: date, geometry: geometry)
        } else {
            arkeyControlView(control, date: date, geometry: geometry)
        }
    }

    @ViewBuilder
    private func arkeyControlView(_ control: KeyboardControl, date: Date, geometry: StageGeometry) -> some View {
        let frame = geometry.frame(for: control)
        let metrics = KeyboardStageMetrics(unitScale: geometry.unitScale)
        let binding = store.bindings[control.id]
        let selected = store.selectedControlId == control.id
        let recentlyBound = store.lastBoundControlId == control.id
        let hovered = hoveredControlId == control.id
        let dropTargeted = dropTargetControlId == control.id
        let light = store.lightingColor(for: control, at: date)

        Button {
            store.selectedControlId = control.id
            guard let action = store.selectedAction else {
                store.message = "已选择 \(control.label.isEmpty ? control.id : control.label)。请先从动作栏选择一个功能，再进行绑定。"
                return
            }
            Task { await store.requestBinding(to: control.id, actionOverride: action) }
        } label: {
            Group {
                if control.kind == .encoder {
                    reasoningKnob(
                        control: control,
                        binding: binding,
                        light: light,
                        selected: selected,
                        hovered: hovered,
                        dropTargeted: dropTargeted,
                        metrics: metrics
                    )
                } else {
                    keycap(
                        control: control,
                        binding: binding,
                        light: light,
                        selected: selected,
                        hovered: hovered,
                        dropTargeted: dropTargeted,
                        metrics: metrics
                    )
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: frame.width, height: frame.height)
        .contentShape(Rectangle())
        .scaleEffect(hovered && !reduceMotion ? 1.025 : 1)
        .offset(
            x: frame.minX,
            y: frame.minY
                - (recentlyBound && !reduceMotion ? metrics.decoration(5) : 0)
                - (hovered && !reduceMotion ? metrics.decoration(1) : 0)
        )
        .shadow(
            color: recentlyBound
                ? light.opacity(0.8)
                : (dropTargeted ? ArkeyTheme.accent.opacity(0.42) : (hovered ? .black.opacity(0.28) : .clear)),
            radius: metrics.decoration(recentlyBound ? 12 : 7),
            y: metrics.decoration(recentlyBound ? 5 : 3)
        )
        .animation(reduceMotion ? .easeOut(duration: 0.14) : .spring(response: 0.24, dampingFraction: 0.68), value: recentlyBound)
        .animation(.easeOut(duration: 0.12), value: hovered)
        .animation(.easeOut(duration: 0.12), value: dropTargeted)
        .onHover { isHovered in
            if isHovered {
                hoveredControlId = control.id
            } else if hoveredControlId == control.id {
                hoveredControlId = nil
            }
        }
        .dropDestination(for: CommandActionInstance.self) { items, _ in
            guard let action = items.first else { return false }
            store.selectedControlId = control.id
            store.selectAction(action, beginHardwareCapture: false)
            Task { await store.requestBinding(to: control.id, actionOverride: action) }
            dropTargetControlId = nil
            return true
        } isTargeted: { targeted in
            if targeted {
                dropTargetControlId = control.id
            } else if dropTargetControlId == control.id {
                dropTargetControlId = nil
            }
        }
        .contextMenu {
            if let binding {
                if let action = store.selectedAction {
                    Button("用 \(action.title) 替换 \(binding.action.title)") {
                        store.selectedControlId = control.id
                        Task {
                            await store.requestBinding(
                                to: control.id,
                                replacing: true,
                                actionOverride: action
                            )
                        }
                    }
                } else {
                    Button("请先选择替换功能") {}
                        .disabled(true)
                }
                Button("清除绑定", role: .destructive) {
                    Task { await store.removeBinding(control.id) }
                }
            } else if let action = store.selectedAction {
                Button("绑定当前功能") {
                    Task { await store.requestBinding(to: control.id, actionOverride: action) }
                }
            } else {
                Button("请先从动作栏选择功能") {}
                    .disabled(true)
            }
        }
        .help(controlHelp(control: control, binding: binding))
        .accessibilityLabel(accessibilityLabel(control: control, binding: binding))
        .accessibilityHint("点击可绑定当前高亮功能；也可以把 Dock 图标拖到这里")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func codexMicroControlView(_ control: KeyboardControl, date: Date, geometry: StageGeometry) -> some View {
        let frame = geometry.frame(for: control)
        let metrics = KeyboardStageMetrics(unitScale: geometry.unitScale)
        let target = store.codexMicroTarget(for: control)
        let selected = store.selectedControlId == control.id
        let recentlyBound = store.lastBoundControlId == control.id
        let hovered = hoveredControlId == control.id
        let light = target == nil ? store.lightingColor(for: control, at: date) : ArkeyTheme.accent

        Button {
            store.selectedControlId = control.id
            if store.codexMicroSelectionActive { Task { await store.bindCodexMicroTarget(to: control.id) } }
        } label: {
            Group {
                if control.kind == .encoder {
                    codexMicroKnob(
                        control: control,
                        target: target,
                        light: light,
                        selected: selected,
                        hovered: hovered,
                        metrics: metrics
                    )
                } else {
                    codexMicroKeycap(
                        control: control,
                        target: target,
                        light: light,
                        selected: selected,
                        hovered: hovered,
                        metrics: metrics
                    )
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: frame.width, height: frame.height)
        .contentShape(Rectangle())
        .scaleEffect(hovered && !reduceMotion ? 1.025 : 1)
        .offset(
            x: frame.minX,
            y: frame.minY
                - (recentlyBound && !reduceMotion ? metrics.decoration(5) : 0)
                - (hovered && !reduceMotion ? metrics.decoration(1) : 0)
        )
        .shadow(
            color: recentlyBound ? light.opacity(0.8) : (hovered ? .black.opacity(0.28) : .clear),
            radius: metrics.decoration(recentlyBound ? 12 : 7),
            y: metrics.decoration(recentlyBound ? 5 : 3)
        )
        .animation(reduceMotion ? .easeOut(duration: 0.14) : .spring(response: 0.24, dampingFraction: 0.68), value: recentlyBound)
        .animation(.easeOut(duration: 0.12), value: hovered)
        .onHover { isHovered in
            if isHovered {
                hoveredControlId = control.id
            } else if hoveredControlId == control.id {
                hoveredControlId = nil
            }
        }
        .contextMenu {
            if let target {
                Button("清除 \(target.title)", role: .destructive) {
                    Task { await store.clearCodexMicroTarget(target) }
                }
            } else if store.codexMicroSelectionActive {
                Button("绑定 \(store.selectedCodexMicroTarget.title)") {
                    Task { await store.bindCodexMicroTarget(to: control.id) }
                }
            }
        }
        .help(codexMicroAccessibilityLabel(control: control, target: target))
        .accessibilityLabel(codexMicroAccessibilityLabel(control: control, target: target))
        .accessibilityHint(target == nil ? "点击会把当前 Micro 槽位接入该实体键。" : "该键已被 Codex Micro 独占；可通过菜单清除。")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func codexMicroKeycap(
        control: KeyboardControl,
        target: CodexMicroLabTarget?,
        light: Color,
        selected: Bool,
        hovered: Bool,
        metrics: KeyboardStageMetrics
    ) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: metrics.content(min(8, 4 + control.width)), style: .continuous)
                .fill(light.opacity(target == nil ? (hovered ? 0.15 : 0.08) : (hovered ? 0.46 : 0.38)))
                .overlay {
                    RoundedRectangle(cornerRadius: metrics.content(min(8, 4 + control.width)), style: .continuous)
                        .strokeBorder(
                            interactionStroke(
                                light: light,
                                selected: selected,
                                hovered: hovered,
                                dropTargeted: false,
                                idleOpacity: target == nil ? 0.24 : 0.82
                            ),
                            lineWidth: metrics.stroke(selected ? 1.4 : (hovered ? 1 : 0.75))
                        )
                }
            if let target {
                VStack(spacing: metrics.content(1)) {
                    Image(systemName: target.symbol)
                        .font(.system(size: metrics.font(9), weight: .semibold))
                    Text(target.shortTitle)
                        .font(.system(size: metrics.font(7), weight: .black, design: .monospaced))
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
            } else {
                Text(control.label)
                    .font(.system(size: metrics.font(control.width > 1.4 ? 7 : 8), weight: .medium))
                    .foregroundStyle(.white.opacity(hovered ? 0.74 : 0.48))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(metrics.content(2))
            }
        }
    }

    private func codexMicroKnob(
        control: KeyboardControl,
        target: CodexMicroLabTarget?,
        light: Color,
        selected: Bool,
        hovered: Bool,
        metrics: KeyboardStageMetrics
    ) -> some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.18), Color.black.opacity(0.74)],
                        center: .topLeading,
                        startRadius: metrics.content(1),
                        endRadius: metrics.content(30)
                    )
                )
                .overlay(
                    Circle().stroke(
                        interactionStroke(
                            light: light,
                            selected: selected,
                            hovered: hovered,
                            dropTargeted: false,
                            idleOpacity: target == nil ? 0.45 : 0.82
                        ),
                        lineWidth: metrics.stroke(selected ? 1.6 : (hovered ? 1.2 : 0.9))
                    )
                )
            Circle()
                .trim(from: 0.08, to: 0.92)
                .stroke(
                    light.opacity(target == nil ? 0.45 : 0.92),
                    style: StrokeStyle(
                        lineWidth: metrics.decoration(2),
                        lineCap: .round,
                        dash: [metrics.decoration(2), metrics.decoration(3)]
                    )
                )
                .rotationEffect(.degrees(90))
                .padding(metrics.content(3))
            if let target {
                Text(target.shortTitle)
                    .font(.system(size: metrics.font(7), weight: .black, design: .monospaced))
                    .foregroundStyle(.white)
            }
        }
        .overlay(alignment: .bottom) {
            Text(store.codexMicroLabSnapshot.encoderEnabled ? "MICRO" : "Q6")
                .font(.system(size: metrics.font(4.8, minimum: 6), weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .offset(y: metrics.content(8))
        }
    }

    private func keycap(
        control: KeyboardControl,
        binding: CommandBinding?,
        light: Color,
        selected: Bool,
        hovered: Bool,
        dropTargeted: Bool,
        metrics: KeyboardStageMetrics
    ) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: metrics.content(min(8, 4 + control.width)), style: .continuous)
                .fill(light.opacity(binding == nil ? (hovered ? 0.15 : 0.08) : (hovered ? 0.42 : 0.32)))
                .overlay {
                    RoundedRectangle(cornerRadius: metrics.content(min(8, 4 + control.width)), style: .continuous)
                        .strokeBorder(
                            interactionStroke(
                                light: light,
                                selected: selected,
                                hovered: hovered,
                                dropTargeted: dropTargeted,
                                idleOpacity: binding == nil ? 0.24 : 0.74
                            ),
                            lineWidth: metrics.stroke(dropTargeted ? 1.7 : (selected ? 1.4 : (hovered ? 1 : 0.75)))
                        )
                }
            if let binding {
                VStack(spacing: metrics.content(1)) {
                    Image(systemName: binding.action.kind.symbol)
                        .font(.system(size: metrics.font(9), weight: .semibold))
                    if control.width > 1.35 {
                        Text(binding.action.title)
                            .font(.system(size: metrics.font(7), weight: .medium, design: .rounded))
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.white)
            } else {
                Text(control.label)
                    .font(.system(size: metrics.font(control.width > 1.4 ? 7 : 8), weight: .medium))
                    .foregroundStyle(.white.opacity(hovered ? 0.74 : 0.48))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(metrics.content(2))
            }
        }
    }

    private func reasoningKnob(
        control: KeyboardControl,
        binding: CommandBinding?,
        light: Color,
        selected: Bool,
        hovered: Bool,
        dropTargeted: Bool,
        metrics: KeyboardStageMetrics
    ) -> some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.18), Color.black.opacity(0.74)],
                        center: .topLeading,
                        startRadius: metrics.content(1),
                        endRadius: metrics.content(30)
                    )
                )
                .overlay(
                    Circle().stroke(
                        interactionStroke(
                            light: light,
                            selected: selected,
                            hovered: hovered,
                            dropTargeted: dropTargeted,
                            idleOpacity: 0.66
                        ),
                        lineWidth: metrics.stroke(dropTargeted ? 1.8 : (selected ? 1.6 : (hovered ? 1.2 : 0.9)))
                    )
                )
            Circle()
                .trim(from: 0.08, to: 0.92)
                .stroke(
                    light.opacity(0.92),
                    style: StrokeStyle(
                        lineWidth: metrics.decoration(2),
                        lineCap: .round,
                        dash: [metrics.decoration(2), metrics.decoration(3)]
                    )
                )
                .rotationEffect(.degrees(90))
                .padding(metrics.content(3))
            Capsule()
                .fill(.white.opacity(0.8))
                .frame(width: metrics.content(2), height: metrics.content(8))
                .offset(y: -metrics.content(8))
            if let binding {
                Image(systemName: binding.action.kind.symbol)
                    .font(.system(size: metrics.font(8), weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 8)
                .onEnded { value in
                    Task { await store.cycleReasoning(delta: value.translation.width + value.translation.height > 0 ? 1 : -1) }
                }
        )
    }

    private func interactionStroke(
        light: Color,
        selected: Bool,
        hovered: Bool,
        dropTargeted: Bool,
        idleOpacity: Double
    ) -> Color {
        if dropTargeted { return ArkeyTheme.accent.opacity(0.95) }
        if selected { return Color.white.opacity(0.88) }
        if hovered { return Color.white.opacity(0.40) }
        return light.opacity(idleOpacity)
    }

    private func controlHelp(control: KeyboardControl, binding: CommandBinding?) -> String {
        let name = control.kind == .encoder ? "旋钮（无 LED）" : (control.label.isEmpty ? control.id : control.label)
        if let binding {
            return "\(name)：\(binding.action.title)。点击可用当前动作替换，右键可清除。"
        }
        if let action = store.selectedAction {
            return "将 \(action.title) 绑定到 \(name)"
        }
        return "\(name) 未绑定。请先从下方动作栏选择功能。"
    }

    private func accessibilityLabel(control: KeyboardControl, binding: CommandBinding?) -> String {
        let name = control.kind == .encoder ? "旋钮，无 LED" : (control.label.isEmpty ? control.id : control.label)
        if let binding { return "\(name)，\(binding.active ? "已绑定" : "等待设备同步") \(binding.action.title)" }
        return "\(name)，未绑定"
    }

    private func codexMicroAccessibilityLabel(control: KeyboardControl, target: CodexMicroLabTarget?) -> String {
        let name = control.kind == .encoder ? "旋钮按下，无 LED" : (control.label.isEmpty ? control.id : control.label)
        if let target { return "\(name)，Codex Micro 独占，\(target.title)" }
        return "\(name)，未映射到 Codex Micro"
    }
}

struct StageGeometry {
    let profile: KeyboardProfileV2
    let size: CGSize
    private let inset: CGFloat = 15

    private var scale: CGFloat {
        min(
            max(1, size.width - inset * 2) / CGFloat(profile.maxX),
            max(1, size.height - inset * 2) / CGFloat(profile.maxY)
        )
    }

    var unitScale: CGFloat { scale }

    private var origin: CGPoint {
        let content = CGSize(width: CGFloat(profile.maxX) * scale, height: CGFloat(profile.maxY) * scale)
        return CGPoint(x: (size.width - content.width) / 2, y: (size.height - content.height) / 2)
    }

    func frame(for control: KeyboardControl) -> CGRect {
        let gap = max(1.2, scale * 0.055)
        return CGRect(
            x: origin.x + CGFloat(control.x) * scale + gap / 2,
            y: origin.y + CGFloat(control.y) * scale + gap / 2,
            width: max(5, CGFloat(control.width) * scale - gap),
            height: max(5, CGFloat(control.height) * scale - gap)
        )
    }
}

struct KeyboardStageMetrics {
    static let referenceUnitScale: CGFloat = 34

    let contentScale: CGFloat
    let decorationScale: CGFloat

    init(unitScale: CGFloat) {
        contentScale = min(max(unitScale / Self.referenceUnitScale, 1), 2.2)
        decorationScale = min(contentScale, 1.65)
    }

    func font(_ base: CGFloat, minimum: CGFloat? = nil) -> CGFloat {
        max(minimum ?? base, base * contentScale)
    }

    func content(_ base: CGFloat) -> CGFloat {
        base * contentScale
    }

    func decoration(_ base: CGFloat) -> CGFloat {
        base * decorationScale
    }

    func stroke(_ base: CGFloat) -> CGFloat {
        min(1.8, decoration(base))
    }
}
