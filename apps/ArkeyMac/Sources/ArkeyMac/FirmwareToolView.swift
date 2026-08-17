import SwiftUI

struct FirmwareToolView: View {
    @ObservedObject var flasher: FirmwareFlashingService
    @Environment(\.dismiss) private var dismiss
    @State private var showConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("固件工具")
                        .font(.system(size: 22, weight: .bold))
                    Text("内置 DFU 刷写，仅支持 V1 Max ANSI Knob 和 Q6 Pro ANSI Knob。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
            }

            Picker("目标键盘", selection: $flasher.board) {
                ForEach(FirmwareBoard.allCases) { board in
                    Text(board.title).tag(board)
                }
            }
            .pickerStyle(.segmented)
            .disabled(flasher.isBusy)
            .onChange(of: flasher.board) { _, _ in flasher.refresh() }

            HStack(spacing: 12) {
                stateCard("USB 工作模式", value: flasher.normalDeviceFound ? "已发现" : "未发现", symbol: "keyboard", active: flasher.normalDeviceFound)
                stateCard("DFU 模式", value: flasher.dfuReady ? "可刷写" : "未进入", symbol: "arrow.down.circle", active: flasher.dfuReady)
                stateCard("目标固件", value: flasher.firmwareURL == nil ? "缺失" : "已内置", symbol: "shippingbox", active: flasher.firmwareURL != nil)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("操作步骤")
                    .font(.headline)
                Text("V1 Max Lab v0.1.9 与 Q6 Pro Lab v0.1.5 可点“软件进入 DFU”；否则：切到 Cable，按住 Esc 后插入 USB，或按键盘底部 Reset。看到“可刷写”后开始。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(flasher.board.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack(spacing: 10) {
                Button {
                    flasher.refresh()
                } label: {
                    Label("重新检测", systemImage: "arrow.clockwise")
                }
                .disabled(flasher.isBusy)

                Button {
                    flasher.enterDFUFromLabFirmware()
                } label: {
                    Label("软件进入 DFU", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!flasher.normalDeviceFound || flasher.dfuReady || flasher.isBusy)

                Button(role: .destructive) {
                    showConfirmation = true
                } label: {
                    Label(flasher.isBusy ? "处理中…" : "刷入 Codex Micro Lab", systemImage: "arrow.down.to.line")
                }
                .disabled(!flasher.dfuReady || flasher.firmwareURL == nil || flasher.isBusy)

                if flasher.isBusy {
                    Button("取消") { flasher.cancel() }
                }
                Spacer()
                Text("上次检测：\(flasher.lastRefresh)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(flasher.log)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
                .padding(12)
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(24)
        .frame(minWidth: 720, minHeight: 620)
        .task { flasher.refresh() }
        .confirmationDialog("确认刷写 \(flasher.board.title)？", isPresented: $showConfirmation, titleVisibility: .visible) {
            Button("确认刷入 Codex Micro Lab", role: .destructive) { flasher.flash() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会覆盖键盘当前固件。仅在 DFU 设备已被检测到时继续；刷写期间不要断开 USB。")
        }
    }

    private func stateCard(_ title: String, value: String, symbol: String, active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: symbol).foregroundStyle(active ? Color.green : Color.secondary)
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
