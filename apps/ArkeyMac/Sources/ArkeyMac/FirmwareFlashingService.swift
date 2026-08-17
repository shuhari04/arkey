import Foundation

enum FirmwareBoard: String, CaseIterable, Identifiable {
    case v1Max
    case q6Pro

    var id: String { rawValue }

    var title: String {
        switch self {
        case .v1Max: "Keychron V1 Max ANSI Knob"
        case .q6Pro: "Keychron Q6 Pro ANSI Knob"
        }
    }

    var stockUSBIdentity: String {
        switch self {
        case .v1Max: "3434:0913"
        case .q6Pro: "3434:0660"
        }
    }

    var stockProductName: String {
        switch self {
        case .v1Max: "Keychron V1 Max"
        case .q6Pro: "Keychron Q6 Pro"
        }
    }

    var labProductName: String {
        switch self {
        case .v1Max: "ARkey V1 Max Codex Micro Lab"
        case .q6Pro: "Arkey Codex Micro Lab"
        }
    }

    var firmwareFileName: String {
        switch self {
        case .v1Max: "arkey-v1-max-codex-micro-lab-v0.1.9.bin"
        case .q6Pro: "arkey-q6-pro-codex-micro-lab-v0.1.5.bin"
        }
    }

    var detail: String {
        "刷入后以 Codex Micro Lab USB 身份 303A:8360 工作。DFU 启动器均为 0483:DF11。"
    }
}

@MainActor
final class FirmwareFlashingService: ObservableObject {
    @Published var board: FirmwareBoard = .v1Max
    @Published var normalDeviceFound = false
    @Published var dfuReady = false
    @Published var isBusy = false
    @Published var log = "尚未检测。刷写前请切至 Cable，并使用数据线连接。"
    @Published var lastRefresh = "—"

    private var task: Task<Void, Never>?

    func refresh() {
        guard !isBusy else { return }
        task?.cancel()
        task = Task {
            isBusy = true
            defer { isBusy = false }
            let usb = await Self.run("/usr/sbin/system_profiler", ["SPUSBDataType"])
            let dfu = await Self.run(toolURL("dfu-util")?.path ?? "/usr/bin/false", ["-l"])
            guard !Task.isCancelled else { return }
            // A Lab keyboard is a HID device. Some macOS USB-controller paths
            // omit it from `system_profiler SPUSBDataType` even though IOKit
            // exposes the active 303A:8360 FF00:0061 interface. Prefer the
            // HID match, while retaining stock-name detection for pre-flash
            // keyboards.
            let labHIDFound = CodexMicroLabService().isConnected
            normalDeviceFound = labHIDFound
                || usb.output.localizedCaseInsensitiveContains(board.stockProductName)
                || usb.output.localizedCaseInsensitiveContains(board.stockUSBIdentity)
                || usb.output.localizedCaseInsensitiveContains(board.labProductName)
            dfuReady = dfu.output.localizedCaseInsensitiveContains("0483:df11")
            lastRefresh = Self.timestamp()
            let hidState = labHIDFound ? "已发现 Codex Micro Lab HID（303A:8360 / FF00:0061）。" : "未发现 Codex Micro Lab HID。"
            log = "检测完成（\(lastRefresh)）\n\n=== HID 连接判定 ===\n\(hidState)\n\n=== 正常 USB 模式 ===\n\(Self.compact(usb.output))\n\n=== DFU 检测 ===\n\(Self.compact(dfu.output))"
            ArkeyDiagnostics.shared.record(
                category: .usb,
                name: "firmware.refresh.completed",
                details: [
                    "board": board.rawValue,
                    "labHIDFound": labHIDFound ? "yes" : "no",
                    "normalDeviceFound": normalDeviceFound ? "yes" : "no",
                    "dfuReady": dfuReady ? "yes" : "no",
                ]
            )
        }
    }

    func flash() {
        guard !isBusy else { return }
        task?.cancel()
        task = Task {
            isBusy = true
            defer { isBusy = false }
            let sessionID = ArkeyDiagnostics.shared.beginSession(reason: "firmware.flash.\(board.rawValue)")
            guard dfuReady else {
                log = "未发现 DFU 设备（0483:DF11）。\n\n请切至 Cable，拔下 USB；按住 Esc 再插入 USB。若无效，使用空格下方 Reset。然后点击“重新检测”。"
                ArkeyDiagnostics.shared.record(category: .dfu, severity: .error, name: "firmware.flash.blocked", details: ["board": board.rawValue, "reason": "dfu-not-found"], sessionID: sessionID)
                ArkeyDiagnostics.shared.finishSession(sessionID, uploadAutomatically: board == .v1Max)
                return
            }
            guard let firmware = firmwareURL else {
                log = "安装包内缺少 \(board.firmwareFileName)。请重新安装完整 ARkey App。"
                ArkeyDiagnostics.shared.record(category: .dfu, severity: .error, name: "firmware.flash.blocked", details: ["board": board.rawValue, "reason": "firmware-missing"], sessionID: sessionID)
                ArkeyDiagnostics.shared.finishSession(sessionID, uploadAutomatically: false)
                return
            }
            guard let dfuTool = toolURL("dfu-util") else {
                log = "安装包内缺少 dfu-util。请重新安装完整 ARkey App。"
                ArkeyDiagnostics.shared.record(category: .dfu, severity: .error, name: "firmware.flash.blocked", details: ["board": board.rawValue, "reason": "dfu-tool-missing"], sessionID: sessionID)
                ArkeyDiagnostics.shared.finishSession(sessionID, uploadAutomatically: false)
                return
            }
            log = "正在刷入 \(board.title)…\n固件：\(firmware.lastPathComponent)\n\n请勿拔出 USB。"
            ArkeyDiagnostics.shared.record(category: .dfu, name: "firmware.flash.started", details: ["board": board.rawValue, "firmware": firmware.lastPathComponent], sessionID: sessionID)
            let result = await Self.run(dfuTool.path, ["-d", "0483:DF11", "-a", "0", "-s", "0x08000000:leave", "-D", firmware.path])
            guard !Task.isCancelled else { return }
            if result.status == 0 {
                dfuReady = false
                log = "刷写完成。键盘将自动退出 DFU 并重新枚举。\n\n\(result.output)"
                ArkeyDiagnostics.shared.record(category: .dfu, name: "firmware.flash.completed", details: ["board": board.rawValue, "status": "0"], sessionID: sessionID)
                ArkeyDiagnostics.shared.finishSession(sessionID, uploadAutomatically: false)
                try? await Task.sleep(for: .seconds(2))
                refresh()
            } else {
                log = "刷写失败（退出码 \(result.status)）。未声称成功，键盘仍可重新进入 DFU 后重试。\n\n\(result.output)"
                ArkeyDiagnostics.shared.record(category: .dfu, severity: .error, name: "firmware.flash.failed", details: ["board": board.rawValue, "status": "\(result.status)"], sessionID: sessionID)
                ArkeyDiagnostics.shared.finishSession(sessionID, uploadAutomatically: board == .v1Max)
            }
        }
    }

    func enterDFUFromLabFirmware() {
        guard !isBusy else { return }
        task?.cancel()
        task = Task {
            isBusy = true
            defer { isBusy = false }
            let sessionID = ArkeyDiagnostics.shared.beginSession(reason: "firmware.enter-dfu.\(board.rawValue)")
            log = "正在请求 \(board.title) 进入 DFU…\n\n键盘会暂时断连；请勿拔出 USB。若 Q6 Pro 仍是旧 Lab 固件，请先通过 Esc/Reset 物理进入 DFU 并刷入 v0.1.5。"
            ArkeyDiagnostics.shared.record(category: .dfu, name: "dfu.request.started", details: ["board": board.rawValue], sessionID: sessionID)
            do {
                let lab = CodexMicroLabService()
                try lab.enterDFU()
                log = "键盘已确认 DFU 请求；正在等待 0483:DF11…"
                ArkeyDiagnostics.shared.record(category: .dfu, name: "dfu.request.confirmed", details: ["board": board.rawValue, "route": "report07-ack"], sessionID: sessionID)
            } catch {
                log = "软件进入 DFU 未获键盘确认：\(error.localizedDescription)\n\n可继续使用 Esc 插线或键盘底部 Reset。"
                ArkeyDiagnostics.shared.record(category: .dfu, severity: .error, name: "dfu.request.failed", details: ["board": board.rawValue, "error": error.localizedDescription], sessionID: sessionID)
                ArkeyDiagnostics.shared.finishSession(sessionID, uploadAutomatically: board == .v1Max)
                return
            }
            for attempt in 1...20 {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .milliseconds(250))
                let dfu = await Self.run(toolURL("dfu-util")?.path ?? "/usr/bin/false", ["-l"])
                let found = dfu.output.localizedCaseInsensitiveContains("0483:df11")
                ArkeyDiagnostics.shared.record(category: .dfu, name: "dfu.poll", details: ["board": board.rawValue, "attempt": "\(attempt)", "dfuFound": found ? "yes" : "no"], sessionID: sessionID)
                if found {
                    dfuReady = true
                    normalDeviceFound = false
                    lastRefresh = Self.timestamp()
                    log = "键盘已进入 DFU（0483:DF11），现在可以刷写。\n\n\(Self.compact(dfu.output))"
                    ArkeyDiagnostics.shared.record(category: .dfu, name: "dfu.enumerated", details: ["board": board.rawValue, "attempt": "\(attempt)"], sessionID: sessionID)
                    ArkeyDiagnostics.shared.finishSession(sessionID, uploadAutomatically: false)
                    return
                }
            }
            log = "键盘已确认 DFU 请求，但 5 秒内未检测到 0483:DF11。\n\n请点击“重新检测”；如仍未出现，使用 Esc 插线或底部 Reset。"
            ArkeyDiagnostics.shared.record(category: .dfu, severity: .error, name: "dfu.enumeration.timeout", details: ["board": board.rawValue, "polls": "20", "timeoutSeconds": "5"], sessionID: sessionID)
            ArkeyDiagnostics.shared.finishSession(sessionID, uploadAutomatically: board == .v1Max)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isBusy = false
        log += "\n\n已请求取消；若 dfu-util 已开始传输，请等待其退出后重新检测。"
    }

    var firmwareURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Firmware/\(board.firmwareFileName)")
    }

    private func toolURL(_ name: String) -> URL? {
        Bundle.main.resourceURL?.appendingPathComponent("FirmwareTools/\(name)")
    }

    private static func run(_ executable: String, _ arguments: [String]) async -> (status: Int32, output: String) {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            do {
                try process.run()
                process.waitUntilExit()
                return (process.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
            } catch {
                return (-1, error.localizedDescription)
            }
        }.value
    }

    private static func compact(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未发现相关设备。" : String(trimmed.prefix(5_000))
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }
}
