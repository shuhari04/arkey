import Foundation
import IOKit.hid

enum CodexMicroLabTarget: Int, CaseIterable, Codable, Identifiable {
    case agent1 = 0
    case agent2
    case agent3
    case agent4
    case agent5
    case agent6
    case command1
    case command2
    case command3
    case command4
    case command5
    case command6
    case encoderPress
    case joystickUp
    case joystickRight
    case joystickDown
    case joystickLeft

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .agent1: "Agent 1"
        case .agent2: "Agent 2"
        case .agent3: "Agent 3"
        case .agent4: "Agent 4"
        case .agent5: "Agent 5"
        case .agent6: "Agent 6"
        case .command1: "Command 1 · ACT06"
        case .command2: "Command 2 · ACT07"
        case .command3: "Command 3 · ACT08"
        case .command4: "Command 4 · ACT09"
        case .command5: "ACT10 · 默认原生 PTT"
        case .command6: "Command 6 · ACT12"
        case .encoderPress: "旋钮按下 · ENC_PRESS"
        case .joystickUp: "方向上"
        case .joystickRight: "方向右"
        case .joystickDown: "方向下"
        case .joystickLeft: "方向左"
        }
    }

    var shortTitle: String {
        switch self {
        case .agent1, .agent2, .agent3, .agent4, .agent5, .agent6: "AG\(rawValue + 1)"
        case .command1: "ACT06"
        case .command2: "ACT07"
        case .command3: "ACT08"
        case .command4: "ACT09"
        case .command5: "ACT10"
        case .command6: "ACT12"
        case .encoderPress: "ENC"
        case .joystickUp: "UP"
        case .joystickRight: "RIGHT"
        case .joystickDown: "DOWN"
        case .joystickLeft: "LEFT"
        }
    }

    var symbol: String {
        switch self {
        case .agent1, .agent2, .agent3, .agent4, .agent5, .agent6: "circle.fill"
        case .command1: "bolt"
        case .command2: "checkmark.circle"
        case .command3: "xmark.circle"
        case .command4: "arrow.up.right"
        case .command5: "mic.fill"
        case .command6: "sparkles"
        case .encoderPress: "button.programmable"
        case .joystickUp: "arrow.up"
        case .joystickRight: "arrow.right"
        case .joystickDown: "arrow.down"
        case .joystickLeft: "arrow.left"
        }
    }

    var configurationHint: String? {
        switch self {
        case .command5:
            "Micro 默认把 ACT10 用于原生语音：按住录音、松开停止，350 ms 内双击可锁定录音。麦克风和转写由 ChatGPT Desktop 处理；如果你在 ChatGPT 设置中改绑了 ACT10，实际动作以该设置为准。"
        default:
            nil
        }
    }
}

struct CodexMicroLabPosition: Codable, Equatable {
    let row: UInt8
    let column: UInt8
}

enum CodexMicroLabVerification: String, Codable, Equatable {
    case verified
    case pendingReadback

    var detail: String {
        switch self {
        case .verified: "已从固件 EEPROM 读回并验证。"
        case .pendingReadback: "配置写入已被 macOS 接受；ChatGPT 正占用 HID 时暂不能读回，稍后可刷新验证。"
        }
    }
}

struct CodexMicroLabSnapshot: Codable, Equatable {
    var mappings: [CodexMicroLabTarget: CodexMicroLabPosition]
    var encoderEnabled: Bool
    var verification: CodexMicroLabVerification

    static let empty = CodexMicroLabSnapshot(mappings: [:], encoderEnabled: false, verification: .pendingReadback)

    /// The V1 Max Codex Micro Lab firmware writes these mappings on its first
    /// boot (or after a storage-version migration).  Raw HID input replies are
    /// asynchronous on macOS, so an unavailable readback must not leave the
    /// physical preview blank before ARkey has any locally cached change.
    static let v1MaxDefaults = CodexMicroLabSnapshot(
        mappings: [
            .agent1: .init(row: 1, column: 15),       // PgUp
            .agent2: .init(row: 2, column: 15),       // PgDn
            .command5: .init(row: 3, column: 15),     // Home / ACT10
            .encoderPress: .init(row: 0, column: 15), // knob press
        ],
        encoderEnabled: true,
        verification: .pendingReadback
    )
}

enum CodexMicroLabError: LocalizedError {
    case deviceNotFound
    case cannotOpen(Int32)
    case writeFailed(Int32)
    case responseTimeout
    case invalidResponse
    case firmwareRejected(UInt8)
    case readbackMismatch

    var errorDescription: String? {
        switch self {
        case .deviceNotFound: "未发现 Codex Micro Lab（303A:8360 / FF00）。请使用 USB 连接实验固件。"
        case .cannotOpen(let code): "无法以非独占方式打开 Codex Micro Lab（IOKit \(code)）。"
        case .writeFailed(let code): "Codex Micro Lab 配置未写入（IOKit \(code)）。"
        case .responseTimeout: "键盘没有返回配置确认；ARkey 未更新预览。"
        case .invalidResponse: "键盘返回了无法识别的配置响应；ARkey 未更新预览。"
        case .firmwareRejected(let status): "键盘拒绝了配置写入（状态 \(status)）；ARkey 未更新预览。"
        case .readbackMismatch: "写入后的固件映射与请求不一致；ARkey 未更新预览。"
        }
    }
}

enum CodexMicroLabProtocol {
    static let vendorID = 0x303A
    static let productID = 0x8360
    static let usagePage = 0xFF00
    static let usage = 0x61
    static let reportID: UInt8 = 0x07
    static let codexReportID: UInt8 = 0x06
    static let reportSize = 64
    static let magic: UInt8 = 0xA7
    static let version: UInt8 = 1

    /// Lab firmware presents a shared VID/PID. The V1 build retains a board
    /// name while the established Q6 build uses the generic Lab name, so this
    /// is the only safe profile discriminator available to the app.
    static func keyboardProfileID(forProductName productName: String?) -> String {
        let name = productName?.lowercased() ?? ""
        if name.contains("v1 max") {
            return "keychron-v1-max-ansi-knob"
        }
        return "keychron-q6-pro-ansi"
    }

    enum Opcode: UInt8 {
        case hello = 0x01
        case mappings = 0x02
        case set = 0x04
        case clear = 0x05
        case encoder = 0x06
        case enterDFU = 0x08
        case ack = 0x7F
    }

    struct Packet: Equatable {
        let opcode: UInt8
        let sequence: UInt8
        let payload: [UInt8]
    }

    static func encode(opcode: Opcode, sequence: UInt8, payload: [UInt8] = []) -> [UInt8] {
        precondition(payload.count <= reportSize - 6)
        var report = [UInt8](repeating: 0, count: reportSize)
        report[0] = reportID
        report[1] = magic
        report[2] = version
        report[3] = opcode.rawValue
        report[4] = sequence
        report[5] = UInt8(payload.count)
        report.replaceSubrange(6..<(6 + payload.count), with: payload)
        return report
    }

    static func decode(_ bytes: [UInt8], callbackReportID: UInt8? = nil) -> Packet? {
        // IOKit exposes V1 Max reports in more than one shape: it can split
        // Report ID 07 into the callback argument, leave a 00 placeholder in
        // the buffer, or include both.  Treat A7 within the first four bytes
        // as the protocol body and reconstruct the canonical 07+A7 frame.
        var candidates: [[UInt8]] = [bytes]
        if callbackReportID == reportID, bytes.first != reportID {
            candidates.append([reportID] + bytes)
        }
        for offset in 0..<min(4, bytes.count) where bytes[offset] == magic {
            candidates.append([reportID] + bytes.dropFirst(offset))
        }
        for report in candidates {
            guard report.count >= 6,
                  report[0] == reportID,
                  report[1] == magic,
                  report[2] == version else { continue }
            let length = Int(report[5])
            guard length <= report.count - 6 else { continue }
            return Packet(opcode: report[3], sequence: report[4], payload: Array(report[6..<(6 + length)]))
        }
        return nil
    }

    static func snapshot(from packet: Packet) -> CodexMicroLabSnapshot? {
        guard packet.opcode == Opcode.mappings.rawValue, packet.payload.count >= 2 else { return nil }
        let count = Int(packet.payload[0])
        guard packet.payload.count >= 2 + count * 3 else { return nil }
        var mappings: [CodexMicroLabTarget: CodexMicroLabPosition] = [:]
        for index in 0..<count {
            let offset = 2 + index * 3
            guard let target = CodexMicroLabTarget(rawValue: Int(packet.payload[offset])) else { continue }
            let row = packet.payload[offset + 1]
            let column = packet.payload[offset + 2]
            if row != 0xFF, column != 0xFF {
                mappings[target] = CodexMicroLabPosition(row: row, column: column)
            }
        }
        return CodexMicroLabSnapshot(mappings: mappings, encoderEnabled: packet.payload[1] != 0, verification: .verified)
    }
}

final class CodexMicroLabService {
    private final class InputCapture {
        let sequence: UInt8
        let opcode: CodexMicroLabProtocol.Opcode
        let sessionID: String
        var packet: CodexMicroLabProtocol.Packet?

        init(sequence: UInt8, opcode: CodexMicroLabProtocol.Opcode, sessionID: String) {
            self.sequence = sequence
            self.opcode = opcode
            self.sessionID = sessionID
        }
    }

    private var sequence: UInt8 = 0

    private static let inputCallback: IOHIDReportCallback = { context, result, _, _, callbackReportID, report, reportLength in
        // On macOS, IOHID may expose the report ID separately, or strip it
        // from the callback and provide 0 as the callback ID. The packet
        // decoder handles both framed and body-only forms, so filtering on
        // the callback ID here would discard a valid Report 07 response.
        guard let context else { return }
        let capture = Unmanaged<InputCapture>.fromOpaque(context).takeUnretainedValue()
        let bytes = Array(UnsafeBufferPointer(start: report, count: reportLength))
        ArkeyDiagnostics.shared.record(
            category: .hid,
            severity: result == kIOReturnSuccess ? .info : .warning,
            name: "hid.report.callback",
            details: [
                "opcode": String(format: "0x%02X", capture.opcode.rawValue),
                "sequence": "\(capture.sequence)",
                "callbackReportID": String(format: "0x%02X", callbackReportID),
                "length": "\(reportLength)",
                "prefix": CodexMicroLabService.hexPrefix(bytes),
                "ioResult": "\(result)",
            ],
            sessionID: capture.sessionID
        )
        guard result == kIOReturnSuccess else { return }
        guard let packet = CodexMicroLabProtocol.decode(bytes, callbackReportID: UInt8(truncatingIfNeeded: callbackReportID)),
              packet.sequence == capture.sequence else { return }
        capture.packet = packet
        CFRunLoopStop(CFRunLoopGetCurrent())
    }

    var isConnected: Bool { deviceName != nil }

    var deviceName: String? {
        withDevice { device in
            (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "ARkey Codex Micro Lab"
        }
    }

    func setMapping(target: CodexMicroLabTarget, position: CodexMicroLabPosition) throws -> CodexMicroLabSnapshot {
        try acknowledgedWrite(.set, payload: [UInt8(target.rawValue), position.row, position.column])
        guard let snapshot = readMappingsIfAvailable(), snapshot.mappings[target] == position else {
            throw CodexMicroLabError.readbackMismatch
        }
        return snapshot
    }

    func clearMapping(target: CodexMicroLabTarget) throws -> CodexMicroLabSnapshot {
        try acknowledgedWrite(.clear, payload: [UInt8(target.rawValue)])
        guard let snapshot = readMappingsIfAvailable(), snapshot.mappings[target] == nil else {
            throw CodexMicroLabError.readbackMismatch
        }
        return snapshot
    }

    func setEncoderEnabled(_ enabled: Bool) throws -> CodexMicroLabSnapshot {
        try acknowledgedWrite(.encoder, payload: [enabled ? 1 : 0])
        guard let snapshot = readMappingsIfAvailable(), snapshot.encoderEnabled == enabled else {
            throw CodexMicroLabError.readbackMismatch
        }
        return snapshot
    }

    /// Requests the Lab firmware to enter the STM32 ROM DFU bootloader. The
    /// fixed token prevents an arbitrary malformed HID write from resetting a
    /// keyboard. A successful return only means the keyboard ACKed; callers
    /// must independently wait for USB identity 0483:DF11.
    func enterDFU() throws {
        try acknowledgedWrite(.enterDFU, payload: Array("DFU!".utf8))
    }

    func readMappingsIfAvailable() -> CodexMicroLabSnapshot? {
        guard let packet = try? transact(.mappings) else { return nil }
        return CodexMicroLabProtocol.snapshot(from: packet)
    }

    private func acknowledgedWrite(_ opcode: CodexMicroLabProtocol.Opcode, payload: [UInt8]) throws {
        let packet = try transact(opcode, payload: payload)
        guard packet.opcode == CodexMicroLabProtocol.Opcode.ack.rawValue,
              packet.payload.count >= 2,
              packet.payload[0] == opcode.rawValue else { throw CodexMicroLabError.invalidResponse }
        guard packet.payload[1] == 0 else { throw CodexMicroLabError.firmwareRejected(packet.payload[1]) }
    }

    private func transact(
        _ opcode: CodexMicroLabProtocol.Opcode,
        payload: [UInt8] = [],
        timeout: TimeInterval = 0.65
    ) throws -> CodexMicroLabProtocol.Packet {
        let requestSequence = nextSequence()
        let productName = deviceName ?? "未识别产品"
        let sessionID = ArkeyDiagnostics.shared.beginSession(reason: "hid.transaction.\(opcode.rawValue)")
        do {
            guard let result: Result<CodexMicroLabProtocol.Packet, Error> = withOpenDevice({ device in
                let capture = InputCapture(sequence: requestSequence, opcode: opcode, sessionID: sessionID)
            var inputBuffer = [UInt8](repeating: 0, count: CodexMicroLabProtocol.reportSize)
            return inputBuffer.withUnsafeMutableBufferPointer { buffer in
                let context = Unmanaged.passUnretained(capture).toOpaque()
                IOHIDDeviceRegisterInputReportCallback(
                    device,
                    buffer.baseAddress!,
                    buffer.count,
                    Self.inputCallback,
                    context
                )
                guard let runLoop = CFRunLoopGetCurrent() else {
                    return .failure(CodexMicroLabError.invalidResponse)
                }
                IOHIDDeviceScheduleWithRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
                defer { IOHIDDeviceUnscheduleFromRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue) }

                let status = setReport(
                    device,
                    CodexMicroLabProtocol.encode(opcode: opcode, sequence: requestSequence, payload: payload)
                )
                ArkeyDiagnostics.shared.record(
                    category: .hid,
                    severity: status == kIOReturnSuccess ? .info : .error,
                    name: "hid.report07.write",
                    details: [
                        "product": productName,
                        "reportID": "0x07",
                        "opcode": String(format: "0x%02X", opcode.rawValue),
                        "sequence": "\(requestSequence)",
                        "length": "\(CodexMicroLabProtocol.reportSize)",
                        "bufferIncludesReportID": "yes",
                        "prefix": "07 A7 01 \(String(format: "%02X", opcode.rawValue)) \(String(format: "%02X", requestSequence))",
                        "ioResult": "\(status)",
                    ],
                    sessionID: sessionID
                )
                guard status == kIOReturnSuccess else {
                    return .failure(CodexMicroLabError.writeFailed(status))
                }

                let deadline = Date().addingTimeInterval(timeout)
                while capture.packet == nil && Date() < deadline {
                    CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.025, true)
                }
                guard let packet = capture.packet else {
                    return .failure(CodexMicroLabError.responseTimeout)
                }
                ArkeyDiagnostics.shared.record(
                    category: .hid,
                    name: "hid.transaction.confirmed",
                    details: [
                        "opcode": String(format: "0x%02X", opcode.rawValue),
                        "sequence": "\(requestSequence)",
                        "responseOpcode": String(format: "0x%02X", packet.opcode),
                        "responseLength": "\(packet.payload.count)",
                    ],
                    sessionID: sessionID
                )
                return .success(packet)
            }
            }) else { throw CodexMicroLabError.deviceNotFound }
            let packet = try result.get()
            ArkeyDiagnostics.shared.finishSession(sessionID, uploadAutomatically: false)
            return packet
        } catch {
            let isV1 = productName.localizedCaseInsensitiveContains("v1 max")
            let timedOut: Bool
            if case CodexMicroLabError.responseTimeout = error {
                timedOut = true
            } else {
                timedOut = false
            }
            ArkeyDiagnostics.shared.record(
                category: .hid,
                severity: .error,
                name: timedOut ? "configuration.timeout" : "hid.transaction.failed",
                details: [
                    "product": productName,
                    "opcode": String(format: "0x%02X", opcode.rawValue),
                    "sequence": "\(requestSequence)",
                    "error": error.localizedDescription,
                ],
                sessionID: sessionID
            )
            ArkeyDiagnostics.shared.finishSession(sessionID, uploadAutomatically: isV1 && timedOut)
            throw error
        }
    }

    private func nextSequence() -> UInt8 {
        defer { sequence &+= 1 }
        return sequence
    }

    private func setReport(_ device: IOHIDDevice, _ report: [UInt8]) -> IOReturn {
        Self.setReport(device, report: report, reportID: CodexMicroLabProtocol.reportID)
    }

    private static func setReport(_ device: IOHIDDevice, report: [UInt8], reportID: UInt8) -> IOReturn {
        var payload = outputReportBuffer(report, reportID: reportID)
        return IOHIDDeviceSetReport(
            device,
            kIOHIDReportTypeOutput,
            CFIndex(reportID),
            &payload,
            payload.count
        )
    }

    /// IOHID requires the report ID both as the explicit argument and as the
    /// first byte when a descriptor exposes multiple numbered reports.
    static func outputReportBuffer(_ report: [UInt8], reportID: UInt8) -> [UInt8] {
        precondition(report.count == CodexMicroLabProtocol.reportSize)
        precondition(report.first == reportID)
        return report
    }

    private static func hexPrefix(_ bytes: [UInt8]) -> String {
        bytes.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private func withDevice<T>(_ body: (IOHIDDevice) -> T?) -> T? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Int] = [
            kIOHIDVendorIDKey as String: CodexMicroLabProtocol.vendorID,
            kIOHIDProductIDKey as String: CodexMicroLabProtocol.productID,
            kIOHIDPrimaryUsagePageKey as String: CodexMicroLabProtocol.usagePage,
            kIOHIDPrimaryUsageKey as String: CodexMicroLabProtocol.usage
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(manager) else {
            return nil
        }
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        for case let device as IOHIDDevice in devices as NSSet {
            return body(device)
        }
        return nil
    }

    private func withOpenDevice<T>(_ body: (IOHIDDevice) -> T) -> T? {
        withDevice { device in
            let status = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            guard status == kIOReturnSuccess else { return nil }
            defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
            return body(device)
        }
    }
}
