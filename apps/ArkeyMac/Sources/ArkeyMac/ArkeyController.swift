import Foundation

struct ArkeyStatus: Decodable {
    let running: Bool
    let device: String?
    let support: String?
    let state: Int
    let transport: ArkeyTransport?
    let extensionVersion: Int?
    let profileId: String?
    let layoutHash: String?
    let appServerRunning: Bool?
    let authenticated: Bool?
    let firmwareRevision: Int?
    let bindingRevision: Int?
    let layoutMatches: Bool?
    let fullControl: Bool?
    let appServer: String?

    private enum CodingKeys: String, CodingKey {
        case running, device, support, state, transport, extensionVersion
        case profileId, layoutHash, appServerRunning, authenticated
        case firmwareRevision, bindingRevision
        case layoutMatches, fullControl, appServer
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        running = try container.decodeIfPresent(Bool.self, forKey: .running) ?? false
        device = try container.decodeIfPresent(String.self, forKey: .device)
        support = try container.decodeIfPresent(String.self, forKey: .support)
        state = try container.decodeIfPresent(Int.self, forKey: .state) ?? 0
        transport = try container.decodeIfPresent(ArkeyTransport.self, forKey: .transport)
        extensionVersion = try container.decodeIfPresent(Int.self, forKey: .extensionVersion)
        profileId = try container.decodeIfPresent(String.self, forKey: .profileId)
        layoutHash = try container.decodeIfPresent(String.self, forKey: .layoutHash)
        appServerRunning = try container.decodeIfPresent(Bool.self, forKey: .appServerRunning)
        authenticated = try container.decodeIfPresent(Bool.self, forKey: .authenticated)
        firmwareRevision = try container.decodeIfPresent(Int.self, forKey: .firmwareRevision)
        bindingRevision = try container.decodeIfPresent(Int.self, forKey: .bindingRevision)
        layoutMatches = try container.decodeIfPresent(Bool.self, forKey: .layoutMatches)
        fullControl = try container.decodeIfPresent(Bool.self, forKey: .fullControl)
        appServer = try container.decodeIfPresent(String.self, forKey: .appServer)
    }
}

enum EffectPreview: String, CaseIterable, Identifiable {
    case thinking, tool, streaming, complete, error

    var id: String { rawValue }
    var title: String {
        switch self {
        case .thinking: "思考"
        case .tool: "工具调用"
        case .streaming: "流式输出"
        case .complete: "完成"
        case .error: "错误"
        }
    }
    var detail: String {
        switch self {
        case .thinking: "随机按键，较慢"
        case .tool: "随机按键，较快"
        case .streaming: "等待逐键事件"
        case .complete: "绿色完成波纹"
        case .error: "红色错误闪烁"
        }
    }
    var symbol: String {
        switch self {
        case .thinking: "brain.head.profile"
        case .tool: "hammer"
        case .streaming: "text.cursor"
        case .complete: "checkmark.circle"
        case .error: "exclamationmark.triangle"
        }
    }
}

@MainActor
final class ArkeyController: ObservableObject {
    @Published var status: ArkeyStatus?
    @Published var isBusy = false
    @Published var message = "正在读取 ARkey 状态…"
    @Published var sampleText = "ARkey is testing code();"
    @Published var previewDuration = 5.0

    var isReady: Bool { status?.running == true && status?.support == "arkey" }

    func refresh() async {
        await perform("状态已刷新") {
            self.status = try await Self.loadStatusWithDaemonRepair()
        }
    }

    func start() async {
        await perform("后台服务已启动") { _ = try await ArkeyCommand.run(["start"]) }
        await refresh()
    }

    func repairDaemon() async {
        await perform("后台服务已修复，正在重新检测设备") {
            _ = try await ArkeyCommand.run(["start"])
        }
        await refresh()
    }

    func stop() async {
        await perform("后台服务已停止，原灯效已恢复") { _ = try await ArkeyCommand.run(["stop"]) }
        status = nil
    }

    func restore() async {
        await perform("已请求恢复原灯效") { _ = try await ArkeyCommand.run(["restore"]) }
        await refresh()
    }

    func testRandom() async {
        await perform("随机测试运行 5 秒后自动恢复") { _ = try await ArkeyCommand.run(["test"]) }
    }

    func preview(_ effect: EffectPreview) async {
        let milliseconds = Int(previewDuration * 1000)
        await perform("正在预览「\(effect.title)」") {
            _ = try await ArkeyCommand.run(["preview", effect.rawValue, String(milliseconds)])
        }
    }

    func playText() async {
        guard !sampleText.isEmpty else { return }
        await perform("正在按字符映射点亮按键") {
            _ = try await ArkeyCommand.run(["text", sampleText])
        }
    }

    func performAgentAction(_ action: AgentControlAction) async {
        await perform("已向前台 Agent 输入 \(action.title)") {
            try await AgentControlService.send(action)
            if self.isReady {
                _ = try? await ArkeyCommand.run(["preview", action.previewEffect.rawValue, "900"])
            }
        }
    }

    private func perform(_ success: String, operation: () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await operation()
            message = success
        } catch {
            message = error.localizedDescription
        }
    }

    private static func loadStatusWithDaemonRepair() async throws -> ArkeyStatus {
        do {
            return try await loadStatus()
        } catch {
            guard shouldAttemptDaemonRepair(error) else { throw error }
            _ = try? await ArkeyCommand.run(["start"])
            try await Task.sleep(nanoseconds: 700_000_000)
            return try await loadStatus()
        }
    }

    private static func loadStatus() async throws -> ArkeyStatus {
        let output = try await ArkeyCommand.run(["status"])
        guard let data = output.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ArkeyStatus.self, from: data) else {
            throw ArkeyCommandError.failed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return decoded
    }

    private static func shouldAttemptDaemonRepair(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        return text.contains("daemon is stopped")
            || text.contains("no supported usb keyboard")
            || text.contains("cannot open device")
            || text.contains("connection refused")
            || text.contains("no such file")
            || text.contains("arkey.sock")
    }
}

enum ArkeyCommandError: LocalizedError {
    case missingCLI
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .missingCLI: "ARkey 内置运行时不可用。请从最新版 ARkey V1 Max 安装包重新安装应用；无需运行 npm install。"
        case .failed(let output): output.isEmpty ? "ARkey 命令执行失败" : output
        }
    }
}

enum ArkeyCommand {
    static func run(_ arguments: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let command = try resolveCommand(arguments)
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: command.executable)
            process.arguments = command.arguments
            process.environment = [
                "PATH": "/opt/homebrew/opt/node@22/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": NSHomeDirectory()
            ]
            process.standardOutput = output
            process.standardError = output
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let text = String(decoding: data, as: UTF8.self)
            guard process.terminationStatus == 0 else {
                throw ArkeyCommandError.failed(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return text
        }.value
    }

    @MainActor
    static func rpc(_ method: String, payload: [String: Any] = [:]) async throws -> String {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let json = String(decoding: data, as: UTF8.self)
        return try await run(["rpc", method, json])
    }

    static func resolveCommand(_ arguments: [String]) throws -> (executable: String, arguments: [String]) {
        let fileManager = FileManager.default
        let home = NSHomeDirectory()
        let bundledNode: String? = Bundle.main.resourceURL.map {
            $0.appendingPathComponent("ArkeyRuntime/node/bin/node").path(percentEncoded: false)
        }
        let nodeCandidates = [
            bundledNode,
            "/opt/homebrew/opt/node@22/bin/node",
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node"
        ].compactMap { $0 }
        let bundledCLI: String? = Bundle.main.resourceURL.map {
            $0.appendingPathComponent("ArkeyRuntime/dist/src/cli.js").path(percentEncoded: false)
        }
        let cliCandidates: [String?] = [
            bundledCLI,
            "\(fileManager.currentDirectoryPath)/dist/src/cli.js",
            "\(home)/.arkey/app/dist/src/cli.js",
            "/opt/homebrew/lib/node_modules/arkey/dist/src/cli.js",
            "/usr/local/lib/node_modules/arkey/dist/src/cli.js"
        ]
        if let node = nodeCandidates.first(where: { fileManager.isExecutableFile(atPath: $0) }),
           let cli = cliCandidates.compactMap({ $0 }).first(where: { fileManager.isReadableFile(atPath: $0) }) {
            return (node, [cli] + arguments)
        }

        let shimCandidates = ["/opt/homebrew/bin/arkey", "/usr/local/bin/arkey"]
        if let shim = shimCandidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return (shim, arguments)
        }

        throw ArkeyCommandError.missingCLI
    }
}

final class ArkeyEventObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var output: Pipe?
    private var buffer = Data()

    func start(
        onLine: @escaping @Sendable (String) -> Void,
        onTermination: @escaping @Sendable (Int32) -> Void
    ) throws {
        stop()
        let command = try ArkeyCommand.resolveCommand(["observe", "--jsonl"])
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.environment = [
            "PATH": "/opt/homebrew/opt/node@22/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory()
        ]
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.append(data, onLine: onLine)
        }
        process.terminationHandler = { [weak self] process in
            self?.flush(onLine: onLine)
            onTermination(process.terminationStatus)
        }
        try process.run()
        lock.lock()
        self.process = process
        self.output = output
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let process = self.process
        let output = self.output
        self.process = nil
        self.output = nil
        buffer.removeAll(keepingCapacity: false)
        lock.unlock()
        output?.fileHandleForReading.readabilityHandler = nil
        if process?.isRunning == true {
            process?.terminate()
        }
    }

    private func append(_ data: Data, onLine: @escaping @Sendable (String) -> Void) {
        lock.lock()
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer.prefix(upTo: newline))
            buffer.removeSubrange(...newline)
        }
        lock.unlock()
        for line in lines where !line.isEmpty {
            onLine(String(decoding: line, as: UTF8.self))
        }
    }

    private func flush(onLine: @escaping @Sendable (String) -> Void) {
        lock.lock()
        let final = buffer
        buffer.removeAll(keepingCapacity: false)
        lock.unlock()
        if !final.isEmpty {
            onLine(String(decoding: final, as: UTF8.self))
        }
    }

    deinit {
        stop()
    }
}
