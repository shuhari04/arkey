import CoreFoundation
import Foundation
import IOKit.hid

private let vendorID = 0x303A
private let productID = 0x8360
private let usagePage = 0xFF00
private let usage = 0x61
private let reportID: UInt8 = 0x07
private let reportSize = 64
private let magic: UInt8 = 0xA7

private enum Opcode: UInt8 {
    case hello = 0x01
    case mappings = 0x02
    case set = 0x04
    case enterDFU = 0x08
    case ack = 0x7F
}

private struct Packet {
    let opcode: UInt8
    let sequence: UInt8
    let payload: [UInt8]
}

private final class Capture {
    let sequence: UInt8
    var packet: Packet?
    init(sequence: UInt8) { self.sequence = sequence }
}

private func hexPrefix(_ bytes: [UInt8], limit: Int = 16) -> String {
    bytes.prefix(limit).map { String(format: "%02X", $0) }.joined(separator: " ")
}

private let callback: IOHIDReportCallback = { context, result, _, _, callbackReportID, report, length in
    // Keep an unfiltered trace in the diagnostic log.  V1 Max has exposed
    // both body-only and 00/07-prefixed callback buffers on macOS.
    guard result == kIOReturnSuccess, let context else { return }
    let capture = Unmanaged<Capture>.fromOpaque(context).takeUnretainedValue()
    let bytes = Array(UnsafeBufferPointer(start: report, count: length))
    print("RX_REPORT callback_id=\(callbackReportID) length=\(length) prefix=\(hexPrefix(bytes))")
    guard let packet = decode(bytes, callbackReportID: UInt8(truncatingIfNeeded: callbackReportID)), packet.sequence == capture.sequence else { return }
    capture.packet = packet
    if let runLoop = CFRunLoopGetCurrent() { CFRunLoopStop(runLoop) }
}

private func encode(_ opcode: Opcode, sequence: UInt8, payload: [UInt8] = []) -> [UInt8] {
    var report = [UInt8](repeating: 0, count: reportSize)
    report[0] = reportID
    report[1] = magic
    report[2] = 1
    report[3] = opcode.rawValue
    report[4] = sequence
    report[5] = UInt8(payload.count)
    report.replaceSubrange(6..<(6 + payload.count), with: payload)
    return report
}

private func decode(_ bytes: [UInt8], callbackReportID: UInt8? = nil) -> Packet? {
    var candidates: [[UInt8]] = [bytes]
    if callbackReportID == reportID, bytes.first != reportID {
        candidates.append([reportID] + bytes)
    }
    for offset in 0..<min(4, bytes.count) where bytes[offset] == magic {
        candidates.append([reportID] + bytes.dropFirst(offset))
    }
    for framed in candidates {
        guard framed.count >= 6, framed[0] == reportID, framed[1] == magic, framed[2] == 1 else { continue }
        let count = Int(framed[5])
        guard count <= framed.count - 6 else { continue }
        return Packet(opcode: framed[3], sequence: framed[4], payload: Array(framed[6..<(6 + count)]))
    }
    return nil
}

private func setReport(_ device: IOHIDDevice, report: [UInt8]) -> IOReturn {
    var output = report
    return IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(reportID), &output, output.count)
}

private func transact(_ device: IOHIDDevice, opcode: Opcode, sequence: UInt8, payload: [UInt8] = []) -> Packet? {
    guard let runLoop = CFRunLoopGetCurrent() else { return nil }
    let capture = Capture(sequence: sequence)
    var input = [UInt8](repeating: 0, count: reportSize)
    return input.withUnsafeMutableBufferPointer { buffer in
        IOHIDDeviceRegisterInputReportCallback(
            device,
            buffer.baseAddress!,
            buffer.count,
            callback,
            Unmanaged.passUnretained(capture).toOpaque()
        )
        IOHIDDeviceScheduleWithRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
        defer { IOHIDDeviceUnscheduleFromRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue) }
        let status = setReport(device, report: encode(opcode, sequence: sequence, payload: payload))
        guard status == kIOReturnSuccess else {
            print("SET_REPORT=FAIL iokit=\(status)")
            return nil
        }
        print("SET_REPORT=PASS report_id=\(reportID) length=\(reportSize) buffer_includes_report_id=yes opcode=\(opcode.rawValue) sequence=\(sequence)")
        let deadline = Date().addingTimeInterval(0.9)
        while capture.packet == nil && Date() < deadline {
            CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.025, true)
        }
        return capture.packet
    }
}

private func firstMapping(_ packet: Packet) -> (target: UInt8, row: UInt8, column: UInt8)? {
    guard packet.opcode == Opcode.mappings.rawValue, packet.payload.count >= 2 else { return nil }
    let count = Int(packet.payload[0])
    guard packet.payload.count >= 2 + count * 3 else { return nil }
    for index in 0..<count {
        let offset = 2 + index * 3
        let row = packet.payload[offset + 1]
        let column = packet.payload[offset + 2]
        if row != 0xFF && column != 0xFF {
            return (packet.payload[offset], row, column)
        }
    }
    return nil
}

private func printMappings(_ packet: Packet) {
    guard packet.opcode == Opcode.mappings.rawValue, packet.payload.count >= 2 else {
        print("CONFIG_MAPPINGS=FAIL malformed_response")
        return
    }
    let count = Int(packet.payload[0])
    guard packet.payload.count >= 2 + count * 3 else {
        print("CONFIG_MAPPINGS=FAIL short_payload")
        return
    }
    print("CONFIG_MAPPINGS=PASS targets=\(count) encoder_enabled=\(packet.payload[1])")
    for index in 0..<count {
        let offset = 2 + index * 3
        let target = packet.payload[offset]
        let row = packet.payload[offset + 1]
        let column = packet.payload[offset + 2]
        let value = row == 0xFF || column == 0xFF ? "unassigned" : "row=\(row) column=\(column)"
        print(String(format: "MAPPING target=%02u %@", target, value))
    }
}

print("ARKEY_HID_PROBE_VERSION=2")
print("EXPECTED_DEVICE=303A:8360 usage=FF00:0061 report=07")

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
let matching: [String: Int] = [
    kIOHIDVendorIDKey as String: vendorID,
    kIOHIDProductIDKey as String: productID,
    kIOHIDPrimaryUsagePageKey as String: usagePage,
    kIOHIDPrimaryUsageKey as String: usage,
]
IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
      let devices = IOHIDManagerCopyDevices(manager),
      let firstDevice = (devices as NSSet).allObjects.first else {
    print("DEVICE_FOUND=NO")
    print("DIRECT_CUSTOMIZATION=UNAVAILABLE reason=device_not_found")
    exit(2)
}
let device = firstDevice as! IOHIDDevice
defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
    print("DEVICE_FOUND=YES")
    print("DEVICE_OPEN=FAIL")
    print("DIRECT_CUSTOMIZATION=UNAVAILABLE reason=device_busy_or_permission")
    exit(3)
}
defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }

let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "unknown"
print("DEVICE_FOUND=YES product=\(product)")

guard let hello = transact(device, opcode: .hello, sequence: 0xD1), hello.opcode == Opcode.hello.rawValue else {
    print("CONFIG_HELLO=FAIL no_firmware_response")
    print("DIRECT_CUSTOMIZATION=UNAVAILABLE reason=no_config_protocol_response")
    exit(4)
}
if hello.payload.count >= 5 {
    print("CONFIG_HELLO=PASS targets=\(hello.payload[0]) rows=\(hello.payload[1]) columns=\(hello.payload[2]) encoder_enabled=\(hello.payload[3]) rgb_leds=\(hello.payload[4])")
} else {
    print("CONFIG_HELLO=FAIL malformed_response")
    exit(5)
}

if CommandLine.arguments.contains("--enter-dfu") {
    print("DFU_REQUEST=START confirmation=DFU!")
    guard let ack = transact(device, opcode: .enterDFU, sequence: 0xD5, payload: Array("DFU!".utf8)),
          ack.opcode == Opcode.ack.rawValue, ack.payload.count >= 2,
          ack.payload[0] == Opcode.enterDFU.rawValue, ack.payload[1] == 0 else {
        print("DFU_REQUEST=FAIL no_success_ack")
        exit(10)
    }
    print("DFU_REQUEST=ACKED waiting_for_0483:DF11")
    exit(0)
}

guard let before = transact(device, opcode: .mappings, sequence: 0xD2) else {
    print("CONFIG_MAPPINGS=FAIL no_readback")
    print("DIRECT_CUSTOMIZATION=UNAVAILABLE reason=mapping_readback_failed")
    exit(6)
}
printMappings(before)

let roundtrip = CommandLine.arguments.contains("--roundtrip")
guard roundtrip else {
    print("WRITE_ROUNDTRIP=NOT_RUN")
    print("DIRECT_CUSTOMIZATION=READBACK_SUPPORTED write_not_tested=1")
    exit(0)
}

guard let mapping = firstMapping(before) else {
    print("WRITE_ROUNDTRIP=FAIL reason=no_existing_mapping_for_idempotent_test")
    print("DIRECT_CUSTOMIZATION=UNVERIFIED")
    exit(7)
}
guard let ack = transact(
    device,
    opcode: .set,
    sequence: 0xD3,
    payload: [mapping.target, mapping.row, mapping.column]
), ack.opcode == Opcode.ack.rawValue, ack.payload.count >= 2,
ack.payload[0] == Opcode.set.rawValue, ack.payload[1] == 0 else {
    print("WRITE_ROUNDTRIP=FAIL reason=no_success_ack")
    print("DIRECT_CUSTOMIZATION=UNAVAILABLE reason=firmware_rejected_write")
    exit(8)
}
guard let after = transact(device, opcode: .mappings, sequence: 0xD4),
      let confirmed = firstMapping(after),
      confirmed.target == mapping.target,
      confirmed.row == mapping.row,
      confirmed.column == mapping.column else {
    print("WRITE_ROUNDTRIP=FAIL reason=readback_mismatch")
    print("DIRECT_CUSTOMIZATION=UNAVAILABLE reason=eeprom_readback_mismatch")
    exit(9)
}
print("WRITE_ROUNDTRIP=PASS target=\(mapping.target) row=\(mapping.row) column=\(mapping.column) mode=idempotent")
print("DIRECT_CUSTOMIZATION=SUPPORTED ack=1 readback=1 persistent_mapping_path=1")
