import AppKit
import Combine
import Foundation

enum ArkeyDiagnosticCategory: String, Codable, CaseIterable, Identifiable {
    case app
    case update
    case usb
    case hid
    case dfu
    case network

    var id: String { rawValue }

    var title: String {
        switch self {
        case .app: "应用"
        case .update: "更新"
        case .usb: "USB"
        case .hid: "HID"
        case .dfu: "DFU"
        case .network: "网络"
        }
    }
}

enum ArkeyDiagnosticSeverity: String, Codable {
    case info
    case warning
    case error
}

struct ArkeyDiagnosticEvent: Codable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let sessionID: String?
    let category: ArkeyDiagnosticCategory
    let severity: ArkeyDiagnosticSeverity
    let name: String
    let details: [String: String]
}

struct ArkeyDiagnosticSession: Codable, Identifiable, Equatable {
    let id: String
    let reason: String
    let startedAt: Date
    var endedAt: Date?
    var uploadState: String
}

enum ArkeyDiagnosticsError: LocalizedError {
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .exportFailed(let description): "导出诊断日志失败：\(description)"
        }
    }
}

/// A deliberately small flight recorder. It only stores protocol metadata and
/// never records key presses, keyboard serial numbers, complete HID reports,
/// prompt text, or workspace paths.
final class ArkeyDiagnostics: ObservableObject, @unchecked Sendable {
    static let shared = ArkeyDiagnostics()

    static let defaultUploadEndpoint = URL(string: "https://diagnostics.arkey.fun/v1")!
    private static let maximumBytes = 50 * 1024 * 1024
    private static let retention: TimeInterval = 30 * 24 * 60 * 60

    @Published private(set) var sessions: [ArkeyDiagnosticSession] = []
    @Published private(set) var recentEvents: [ArkeyDiagnosticEvent] = []
    @Published private(set) var uploadStatus = "尚未上传诊断日志"

    private let storageURL: URL
    private let uploadEndpoint: URL?
    private let session: URLSession
    private let writerQueue = DispatchQueue(label: "dev.arkey.diagnostics.writer", qos: .utility)
    private let fileManager = FileManager.default
    private var activeSessions: [String: ArkeyDiagnosticSession] = [:]

    init(
        storageURL: URL? = nil,
        uploadEndpoint: URL? = ArkeyDiagnostics.defaultUploadEndpoint,
        session: URLSession = .shared
    ) {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.storageURL = storageURL ?? applicationSupport.appendingPathComponent("ARkey/Diagnostics", isDirectory: true)
        self.uploadEndpoint = uploadEndpoint
        self.session = session
        writerQueue.async { [weak self] in
            self?.prepareStorage()
            self?.reloadFromDiskOnWriterQueue()
        }
    }

    var installationID: String {
        let key = "arkey.diagnostics.installation-id"
        if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty { return saved }
        let value = UUID().uuidString.lowercased()
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    @discardableResult
    func beginSession(reason: String) -> String {
        let now = Date()
        let id = "ARK-\(Self.sessionTimestamp.string(from: now))-\(UUID().uuidString.prefix(8).uppercased())"
        let diagnosticSession = ArkeyDiagnosticSession(id: id, reason: Self.clean(reason), startedAt: now, endedAt: nil, uploadState: "本地")
        writerQueue.async { [weak self] in
            guard let self else { return }
            self.activeSessions[id] = diagnosticSession
            self.writeSessionsOnWriterQueue()
            self.publishStateOnMainQueue()
        }
        record(category: .app, name: "session.started", details: ["reason": reason], sessionID: id)
        return id
    }

    func finishSession(_ id: String, uploadAutomatically: Bool) {
        record(category: .app, name: "session.finished", details: [:], sessionID: id)
        writerQueue.async { [weak self] in
            guard let self, var value = self.activeSessions[id] else { return }
            value.endedAt = Date()
            value.uploadState = uploadAutomatically ? "等待上传" : "仅本地"
            self.activeSessions[id] = value
            self.writeSessionsOnWriterQueue()
            self.publishStateOnMainQueue()
        }
        if uploadAutomatically {
            Task { await uploadSession(id) }
        }
    }

    func recordV1ConfigurationTimeout(details: [String: String]) {
        let sessionID = beginSession(reason: "v1-max.configuration-timeout")
        record(category: .hid, severity: .error, name: "configuration.timeout", details: details, sessionID: sessionID)
        finishSession(sessionID, uploadAutomatically: true)
    }

    func record(
        category: ArkeyDiagnosticCategory,
        severity: ArkeyDiagnosticSeverity = .info,
        name: String,
        details: [String: String] = [:],
        sessionID: String? = nil
    ) {
        let event = ArkeyDiagnosticEvent(
            id: UUID(),
            timestamp: Date(),
            sessionID: sessionID,
            category: category,
            severity: severity,
            name: Self.clean(name),
            details: Self.sanitise(details)
        )
        writerQueue.async { [weak self] in
            guard let self else { return }
            self.appendOnWriterQueue(event)
            self.publishRecentEventOnMainQueue(event)
        }
    }

    func reload() {
        writerQueue.async { [weak self] in self?.reloadFromDiskOnWriterQueue() }
    }

    func events(for sessionID: String? = nil, category: ArkeyDiagnosticCategory? = nil) -> [ArkeyDiagnosticEvent] {
        writerQueue.sync {
            let all = readEventsOnWriterQueue()
            return all.filter { event in
                (sessionID == nil || event.sessionID == sessionID)
                    && (category == nil || event.category == category)
            }.sorted { $0.timestamp > $1.timestamp }
        }
    }

    func exportLogs(to destination: URL) async throws {
        let source = storageURL
        try await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let temporary = destination.deletingLastPathComponent().appendingPathComponent("ARkey-Diagnostics-\(UUID().uuidString).zip")
            try? fileManager.removeItem(at: temporary)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, temporary.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw ArkeyDiagnosticsError.exportFailed("ditto 退出码 \(process.terminationStatus)") }
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: temporary, to: destination)
        }.value
        record(category: .app, name: "diagnostics.exported", details: ["format": "zip"])
    }

    func uploadSession(_ sessionID: String) async {
        guard let uploadEndpoint else { return }
        // Drain pending writes before reading a session, so the triggering
        // timeout is guaranteed to travel with its preceding HID trace.
        writerQueue.sync { }
        let sessionEvents = events(for: sessionID)
        guard !sessionEvents.isEmpty else { return }

        for retry in 0...3 {
            do {
                let token = try await diagnosticToken(baseURL: uploadEndpoint)
                let payload = DiagnosticUploadPayload(
                    schemaVersion: 1,
                    installationID: installationID,
                    session: writerQueue.sync { activeSessions[sessionID] },
                    events: sessionEvents
                )
                var request = URLRequest(url: uploadEndpoint.appendingPathComponent("diagnostics"))
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.httpBody = try JSONEncoder.diagnostic.encode(payload)
                let (_, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                updateUploadState(sessionID: sessionID, state: "已上传")
                DispatchQueue.main.async { self.uploadStatus = "诊断会话 \(sessionID) 已上传" }
                return
            } catch {
                if retry == 3 {
                    updateUploadState(sessionID: sessionID, state: "待重试")
                    DispatchQueue.main.async { self.uploadStatus = "诊断上传失败，将在下次错误时重试：\(error.localizedDescription)" }
                    record(category: .network, severity: .warning, name: "diagnostics.upload.failed", details: ["error": error.localizedDescription], sessionID: sessionID)
                    return
                }
                let nanoseconds = UInt64(5 * (1 << retry)) * 1_000_000_000
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
        }
    }

    private func diagnosticToken(baseURL: URL) async throws -> String {
        let key = "arkey.diagnostics.upload-token"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty { return existing }
        var request = URLRequest(url: baseURL.appendingPathComponent("installations"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder.diagnostic.encode(DiagnosticInstallationRequest(schemaVersion: 1, installationID: installationID, appVersion: ArkeyUpdateService.currentVersion))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        let reply = try JSONDecoder.diagnostic.decode(DiagnosticInstallationReply.self, from: data)
        UserDefaults.standard.set(reply.token, forKey: key)
        return reply.token
    }

    private func updateUploadState(sessionID: String, state: String) {
        writerQueue.async { [weak self] in
            guard let self, var session = self.activeSessions[sessionID] else { return }
            session.uploadState = state
            self.activeSessions[sessionID] = session
            self.writeSessionsOnWriterQueue()
            self.publishStateOnMainQueue()
        }
    }

    private func prepareStorage() {
        try? fileManager.createDirectory(at: storageURL, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: eventsURL, withIntermediateDirectories: true)
        trimOnWriterQueue()
    }

    private var eventsURL: URL { storageURL.appendingPathComponent("events", isDirectory: true) }
    private var sessionsURL: URL { storageURL.appendingPathComponent("sessions.json") }

    private func appendOnWriterQueue(_ event: ArkeyDiagnosticEvent) {
        prepareStorage()
        let day = Self.dayFormatter.string(from: event.timestamp)
        let url = eventsURL.appendingPathComponent("\(day).jsonl")
        guard let data = try? JSONEncoder.diagnostic.encode(event) else { return }
        let line = data + Data([0x0A])
        if !fileManager.fileExists(atPath: url.path) { fileManager.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
        trimOnWriterQueue()
    }

    private func reloadFromDiskOnWriterQueue() {
        prepareStorage()
        if let data = try? Data(contentsOf: sessionsURL), let decoded = try? JSONDecoder.diagnostic.decode([ArkeyDiagnosticSession].self, from: data) {
            activeSessions = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
        }
        publishStateOnMainQueue()
        let events = Array(readEventsOnWriterQueue().sorted { $0.timestamp > $1.timestamp }.prefix(200))
        DispatchQueue.main.async { self.recentEvents = events }
    }

    private func readEventsOnWriterQueue() -> [ArkeyDiagnosticEvent] {
        guard let urls = try? fileManager.contentsOfDirectory(at: eventsURL, includingPropertiesForKeys: nil) else { return [] }
        return urls.filter { $0.pathExtension == "jsonl" }.flatMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] as [ArkeyDiagnosticEvent] }
            return text.split(separator: "\n").compactMap { try? JSONDecoder.diagnostic.decode(ArkeyDiagnosticEvent.self, from: Data($0.utf8)) }
        }
    }

    private func writeSessionsOnWriterQueue() {
        prepareStorage()
        let values = activeSessions.values.sorted { $0.startedAt > $1.startedAt }
        guard let data = try? JSONEncoder.diagnostic.encode(values) else { return }
        let temporary = sessionsURL.appendingPathExtension("tmp")
        try? data.write(to: temporary, options: .atomic)
        try? fileManager.removeItem(at: sessionsURL)
        try? fileManager.moveItem(at: temporary, to: sessionsURL)
    }

    private func trimOnWriterQueue() {
        let cutoff = Date().addingTimeInterval(-Self.retention)
        guard let urls = try? fileManager.contentsOfDirectory(at: eventsURL, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }
        var retained: [(url: URL, date: Date, size: Int)] = []
        for url in urls where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let date = values?.contentModificationDate ?? .distantPast
            if date < cutoff { try? fileManager.removeItem(at: url) }
            else { retained.append((url, date, values?.fileSize ?? 0)) }
        }
        var total = retained.reduce(0) { $0 + $1.size }
        for entry in retained.sorted(by: { $0.date < $1.date }) where total > Self.maximumBytes {
            try? fileManager.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    private func publishStateOnMainQueue() {
        let values = activeSessions.values.sorted { $0.startedAt > $1.startedAt }
        DispatchQueue.main.async { self.sessions = values }
    }

    private func publishRecentEventOnMainQueue(_ event: ArkeyDiagnosticEvent) {
        DispatchQueue.main.async {
            self.recentEvents = Array(([event] + self.recentEvents).prefix(200))
        }
    }

    private static func clean(_ value: String) -> String {
        String(value.prefix(500)).replacingOccurrences(of: "\n", with: " ")
    }

    private static func sanitise(_ details: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in details {
            let lowered = key.lowercased()
            guard !lowered.contains("serial"), !lowered.contains("key"), !lowered.contains("workspace"), !lowered.contains("prompt"), !lowered.contains("raw") else { continue }
            result[clean(key)] = clean(value)
        }
        return result
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let sessionTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

private struct DiagnosticInstallationRequest: Codable {
    let schemaVersion: Int
    let installationID: String
    let appVersion: String
}

private struct DiagnosticInstallationReply: Codable { let token: String }

private struct DiagnosticUploadPayload: Codable {
    let schemaVersion: Int
    let installationID: String
    let session: ArkeyDiagnosticSession?
    let events: [ArkeyDiagnosticEvent]
}

extension JSONEncoder {
    static let diagnostic: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

extension JSONDecoder {
    static let diagnostic: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            for options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] as [ISO8601DateFormatter.Options] {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = options
                if let date = formatter.date(from: value) { return date }
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an ISO-8601 timestamp.")
        }
        return decoder
    }()
}
