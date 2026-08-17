import SwiftUI

struct CodexMicroEndpointPreferenceKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]

    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct CodexMicroMappingWorkspaceView: View {
    @ObservedObject var store: CommandSurfaceStore

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Label("实体键盘", systemImage: "keyboard")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ArkeyTheme.textSecondary)
                    Menu {
                        Button("跟随当前设备") { store.selectKeyboardPreview(nil) }
                        Divider()
                        ForEach(store.availableKeyboardProfiles, id: \.profileId) { profile in
                            Button(profile.name) { store.selectKeyboardPreview(profile.profileId) }
                        }
                    } label: {
                        Label(store.displayedKeyboardProfile.name, systemImage: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .menuStyle(.borderlessButton)
                }
                KeyboardStageView(store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .arkeyPanel(radius: 18)

            VStack(alignment: .leading, spacing: 8) {
                Label("Codex Micro 槽位", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ArkeyTheme.textSecondary)
                CodexMicroOfficialLayoutView(store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .padding(12)
            .frame(width: 292)
            .frame(maxHeight: .infinity)
            .arkeyPanel(radius: 18, raised: true)
        }
        .overlayPreferenceValue(CodexMicroEndpointPreferenceKey.self) { anchors in
            GeometryReader { proxy in
                Canvas { context, _ in
                    for (target, position) in store.codexMicroLabSnapshot.mappings {
                        let row = Int(position.row)
                        let column = Int(position.column)
                        let control = store.displayedKeyboardProfile.controls.first { candidate in
                            candidate.matrixRow == row && candidate.matrixColumn == column
                        }
                        guard let control,
                        let stageAnchor = anchors["keyboard-stage"],
                        let targetAnchor = anchors["target-\(target.rawValue)"] else { continue }

                        let stageFrame = proxy[stageAnchor]
                        let stageGeometry = StageGeometry(profile: store.displayedKeyboardProfile, size: stageFrame.size)
                        let controlFrame = stageGeometry.frame(for: control)
                        let source = CGPoint(
                            x: stageFrame.minX + controlFrame.midX,
                            y: stageFrame.minY + controlFrame.midY
                        )
                        let targetFrame = proxy[targetAnchor]
                        let destination = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
                        let bend = max(42, (destination.x - source.x) * 0.42)
                        var path = Path()
                        path.move(to: source)
                        path.addCurve(
                            to: destination,
                            control1: CGPoint(x: source.x + bend, y: source.y),
                            control2: CGPoint(x: destination.x - bend, y: destination.y)
                        )
                        let active = store.codexMicroSelectionActive && store.selectedCodexMicroTarget == target
                        context.stroke(
                            path,
                            with: .color(active ? ArkeyTheme.accent : ArkeyTheme.accent.opacity(0.48)),
                            style: StrokeStyle(lineWidth: active ? 2.4 : 1.35, lineCap: .round)
                        )
                        let dotRadius: CGFloat = active ? 3.5 : 2.5
                        for point in [source, destination] {
                            context.fill(
                                Path(ellipseIn: CGRect(
                                    x: point.x - dotRadius,
                                    y: point.y - dotRadius,
                                    width: dotRadius * 2,
                                    height: dotRadius * 2
                                )),
                                with: .color(active ? ArkeyTheme.accent : ArkeyTheme.accent.opacity(0.72))
                            )
                        }
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .help("可在左上角切换 V1 Max 或 Q6 Pro 预览；不会改动当前设备的实际硬件配置。")
    }
}

private struct CodexMicroOfficialLayoutView: View {
    @ObservedObject var store: CommandSurfaceStore

    private let agentRows: [[CodexMicroLabTarget]] = [
        [.agent3, .agent4, .agent5, .agent6],
    ]
    private let directionTargets: [CodexMicroLabTarget] = [.joystickUp, .joystickLeft, .joystickDown, .joystickRight]

    var body: some View {
        VStack(spacing: 8) {
            Text("Codex Micro")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)

            // Mirrors the official physical order: sensor, two live Agent
            // keys, dial; then four Agents, four command actions, and the
            // touch/PTT/Codex row.
            HStack(spacing: 7) {
                surfaceDial(light: true)
                targetTile(.agent1, agent: true)
                targetTile(.agent2, agent: true)
                targetTile(.encoderPress, shape: .knob)
            }

            ForEach(Array(agentRows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 7) {
                    ForEach(row) { target in targetTile(target, agent: true) }
                }
            }

            HStack(spacing: 7) {
                targetTile(.command1)
                targetTile(.command2)
                targetTile(.command3)
                targetTile(.command4)
            }

            HStack(spacing: 7) {
                surfaceDial(light: false)
                targetTile(.command5, wide: true)
                targetTile(.command6)
            }

            joystick

            HStack(spacing: 6) {
                Image(systemName: store.codexMicroLabSnapshot.verification == .verified ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                Text(store.codexMicroLabSnapshot.verification == .verified ? "固件已读回" : "等待固件确认")
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(store.codexMicroLabSnapshot.verification == .verified ? ArkeyTheme.accent : ArkeyTheme.warning)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Color.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(ArkeyTheme.stroke))
    }

    private enum TileShape { case key, knob }

    private func surfaceDial(light: Bool) -> some View {
        Circle()
            .fill(light ? Color.white.opacity(0.92) : Color.black.opacity(0.72))
            .overlay(Circle().stroke(ArkeyTheme.strokeStrong, lineWidth: 0.75))
            .frame(width: 48, height: 48)
            .accessibilityHidden(true)
    }

    private var joystick: some View {
        HStack(spacing: 7) {
            Text("JOYSTICK")
                .font(.system(size: 7, weight: .black, design: .monospaced))
                .foregroundStyle(ArkeyTheme.textTertiary)
            ForEach(directionTargets) { target in targetTile(target, compact: true) }
        }
    }

    private func targetTile(
        _ target: CodexMicroLabTarget,
        wide: Bool = false,
        compact: Bool = false,
        agent: Bool = false,
        shape: TileShape = .key
    ) -> some View {
        let selected = store.codexMicroSelectionActive && store.selectedCodexMicroTarget == target
        let mappedControl = mappedControlLabel(for: target)
        return Button {
            store.selectCodexMicroTarget(target)
        } label: {
            VStack(spacing: compact ? 2 : 4) {
                Image(systemName: target.symbol)
                    .font(.system(size: compact ? 10 : 13, weight: .semibold))
                    .foregroundStyle(agent ? ArkeyTheme.accent.opacity(0.9) : (selected ? Color.white : ArkeyTheme.textSecondary))
                Text(target.shortTitle)
                    .font(.system(size: compact ? 7 : 9, weight: .black, design: .monospaced))
                    .lineLimit(1)
                if !compact {
                    Text(mappedControl ?? "未映射")
                        .font(.system(size: 7, weight: .medium))
                        .foregroundStyle(mappedControl == nil ? ArkeyTheme.textTertiary : ArkeyTheme.accent)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(selected ? Color.white : ArkeyTheme.textSecondary)
            .frame(maxWidth: .infinity, minHeight: shape == .knob ? 58 : (compact ? 42 : 58))
            .background(
                Group {
                    if shape == .knob {
                        Circle().fill(selected ? ArkeyTheme.accent.opacity(0.32) : ArkeyTheme.surfaceRaised)
                    } else {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(selected ? ArkeyTheme.accent.opacity(0.32) : ArkeyTheme.surfaceRaised)
                    }
                }
            )
            .overlay {
                Group {
                    if shape == .knob {
                        Circle().stroke(selected ? ArkeyTheme.accent : ArkeyTheme.strokeStrong, lineWidth: selected ? 1.6 : 0.75)
                    } else {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(selected ? ArkeyTheme.accent : ArkeyTheme.strokeStrong, lineWidth: selected ? 1.6 : 0.75)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: wide ? .infinity : nil)
        .anchorPreference(key: CodexMicroEndpointPreferenceKey.self, value: .bounds) {
            ["target-\(target.rawValue)": $0]
        }
        .help(mappedControl.map { "\(target.title) 当前映射到 \($0)" } ?? "选择 \(target.title)")
        .accessibilityLabel(target.title)
        .accessibilityValue(mappedControl.map { "已映射到 \($0)" } ?? "未映射")
    }

    private func mappedControlLabel(for target: CodexMicroLabTarget) -> String? {
        guard let position = store.codexMicroLabSnapshot.mappings[target] else { return nil }
        return store.displayedKeyboardProfile.controls.first(where: {
            $0.matrixRow == Int(position.row) && $0.matrixColumn == Int(position.column)
        }).map { $0.label.isEmpty ? $0.id : $0.label }
    }
}
