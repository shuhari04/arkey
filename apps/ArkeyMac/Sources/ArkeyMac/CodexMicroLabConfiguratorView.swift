import SwiftUI

struct CodexMicroLabConfiguratorView: View {
    @ObservedObject var store: CommandSurfaceStore
    @State private var showingConfigurationHint = false
    @State private var showingClearConfirmation = false

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Label("右侧选择 Codex Micro 槽位，再点击左侧 V1 Max 键帽", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ArkeyTheme.textSecondary)
            }

            Text(store.codexMicroSelectionActive ? "待映射：\(store.selectedCodexMicroTarget.title)" : "未选择槽位")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(store.codexMicroSelectionActive ? ArkeyTheme.accent : ArkeyTheme.textTertiary)
                .lineLimit(1)

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                Toggle(
                    "接管旋钮",
                    isOn: Binding(
                        get: { store.codexMicroLabSnapshot.encoderEnabled },
                        set: { enabled in Task { await store.setCodexMicroEncoderEnabled(enabled) } }
                    )
                )
                .toggleStyle(.switch)
                .tint(ArkeyTheme.accent)
                .font(.system(size: 10, weight: .medium))
                .help("Micro 接管旋钮；关闭后恢复 Q6/VIA 映射")
                .accessibilityLabel("接管旋钮")
                .accessibilityHint("开启后旋钮由 Codex Micro 独占")

                if let hint = store.selectedCodexMicroTarget.configurationHint {
                    Button {
                        showingConfigurationHint.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(ArkeyIconButtonStyle(size: 26))
                    .help("查看当前槽位说明")
                    .accessibilityLabel("查看 \(store.selectedCodexMicroTarget.title) 说明")
                    .popover(isPresented: $showingConfigurationHint, arrowEdge: .bottom) {
                        Text(hint)
                            .font(.callout)
                            .foregroundStyle(ArkeyTheme.textPrimary)
                            .padding(14)
                            .frame(width: 330, alignment: .leading)
                            .background(ArkeyTheme.window)
                            .preferredColorScheme(.dark)
                    }
                }

                Label(verificationTitle, systemImage: verificationSymbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(store.codexMicroLabSnapshot.verification == .verified ? ArkeyTheme.accent : ArkeyTheme.warning)
                    .help(store.codexMicroLabSnapshot.verification.detail)
                    .accessibilityLabel(store.codexMicroLabSnapshot.verification.detail)

                Button { Task { await store.refreshCodexMicroLab() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(ArkeyIconButtonStyle(size: 28))
                .help("刷新验证")
                .accessibilityLabel("刷新验证")

                Button(role: .destructive) {
                    showingClearConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(ArkeyIconButtonStyle(tone: .danger, size: 28))
                .disabled(!selectedTargetHasMapping)
                .help(selectedTargetHasMapping ? "清除当前槽位映射" : "当前槽位尚未映射")
                .accessibilityLabel("清除 \(store.selectedCodexMicroTarget.title) 映射")
            }
        }
        .padding(10)
        .foregroundStyle(ArkeyTheme.textPrimary)
        .arkeyPanel(radius: 15, raised: true)
        .help("选择槽位后点击实体键；映射键由 Micro 独占，清除后恢复普通输入")
        .confirmationDialog(
            "清除 \(store.selectedCodexMicroTarget.title) 的映射？",
            isPresented: $showingClearConfirmation
        ) {
            Button("清除映射", role: .destructive) {
                Task { await store.clearCodexMicroTarget() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("原实体键将恢复普通输入。")
        }
    }

    private var selectedTargetHasMapping: Bool {
        store.codexMicroLabSnapshot.mappings[store.selectedCodexMicroTarget] != nil
    }

    private var verificationTitle: String {
        store.codexMicroLabSnapshot.verification == .verified ? "已验证" : "待验证"
    }

    private var verificationSymbol: String {
        store.codexMicroLabSnapshot.verification == .verified
            ? "checkmark.seal.fill"
            : "eye.slash.badge.exclamationmark"
    }
}
