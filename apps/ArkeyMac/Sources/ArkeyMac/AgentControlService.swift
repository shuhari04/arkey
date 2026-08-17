import Foundation

enum AgentControlAction: String, CaseIterable, Identifiable {
    case optionOne
    case optionTwo
    case optionThree
    case yes
    case no
    case enter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .optionOne: "1"
        case .optionTwo: "2"
        case .optionThree: "3"
        case .yes: "Yes"
        case .no: "No"
        case .enter: "继续"
        }
    }

    var symbol: String {
        switch self {
        case .optionOne: "1.circle"
        case .optionTwo: "2.circle"
        case .optionThree: "3.circle"
        case .yes: "checkmark.circle"
        case .no: "xmark.circle"
        case .enter: "return"
        }
    }

    var terminalInput: String {
        switch self {
        case .optionOne: "1\n"
        case .optionTwo: "2\n"
        case .optionThree: "3\n"
        case .yes: "y\n"
        case .no: "n\n"
        case .enter: "\n"
        }
    }

    var previewEffect: EffectPreview {
        switch self {
        case .yes, .enter: .complete
        case .no: .error
        case .optionOne, .optionTwo, .optionThree: .tool
        }
    }
}

enum AgentControlService {
    static func send(_ action: AgentControlAction) async throws {
        try await typeIntoFrontmostApp(action)
    }

    private static func typeIntoFrontmostApp(_ action: AgentControlAction) async throws {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", appleScript(for: action)]
            process.standardOutput = output
            process.standardError = output
            try process.run()
            process.waitUntilExit()

            let data = output.fileHandleForReading.readDataToEndOfFile()
            let message = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0 else {
                throw ArkeyCommandError.failed(message.isEmpty ? "无法向前台终端输入，请检查辅助功能权限" : message)
            }
        }.value
    }

    private static func appleScript(for action: AgentControlAction) -> String {
        let text = action.terminalInput.replacingOccurrences(of: "\n", with: "")
        let escaped = text.replacingOccurrences(of: "\"", with: "\\\"")

        if escaped.isEmpty {
            return """
            tell application "System Events"
                key code 36
            end tell
            """
        }

        return """
        tell application "System Events"
            keystroke "\(escaped)"
            key code 36
        end tell
        """
    }
}
