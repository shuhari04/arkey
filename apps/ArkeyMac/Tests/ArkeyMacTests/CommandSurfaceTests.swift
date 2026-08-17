import Foundation
import Testing
@testable import ArkeyMac

@Suite("ARkey Command Surface")
struct CommandSurfaceTests {
    @Test("canonical Q6 profile has 109 controls, 108 LEDs and one no-LED knob")
    func q6ProfileGeometry() throws {
        let profileURL = repositoryRoot
            .appendingPathComponent("profiles/keychron-q6-pro-ansi.json")
        let data = try Data(contentsOf: profileURL)
        let profile = try JSONDecoder().decode(KeyboardProfileV2.self, from: data)

        #expect(profile.version == 2)
        #expect(profile.controls.count == 109)
        #expect(profile.ledCount == 108)
        #expect(profile.controls.compactMap(\.ledIndex).count == 108)
        let knob = try #require(profile.controls.first(where: { $0.kind == .encoder }))
        #expect(knob.id == "encoder-0")
        #expect(knob.matrixRow == 0)
        #expect(knob.matrixColumn == 13)
        #expect(knob.encoderIndex == 0)
        #expect(knob.ledIndex == nil)
        #expect(profile.controls.first(where: { $0.matrixRow == 2 && $0.matrixColumn == 10 })?.label == "P")
    }

    @Test("keyboard labels scale with key geometry and retain a readable floor")
    func responsiveKeyboardMetrics() {
        let compact = KeyboardStageMetrics(unitScale: 25)
        let reference = KeyboardStageMetrics(unitScale: 34)
        let large = KeyboardStageMetrics(unitScale: 60)
        let oversized = KeyboardStageMetrics(unitScale: 90)

        #expect(compact.contentScale == 1)
        #expect(reference.contentScale == 1)
        #expect(abs(large.contentScale - (60 / 34)) < 0.001)
        #expect(oversized.contentScale == 2.2)
        #expect(large.font(8) > reference.font(8))
        #expect(compact.font(4.8, minimum: 6) == 6)
        #expect(oversized.decorationScale == 1.65)
        #expect(oversized.stroke(1.8) == 1.8)
    }

    @Test("request user input requires a non-empty answer for every unique question")
    func requestUserInputValidation() {
        let questions: [[String: Any]] = [["id": "choice"]]
        let empty: [String: Any] = ["answers": ["choice": ["answers": [String]()]]]
        let blank: [String: Any] = ["answers": ["choice": ["answers": ["   "]]]]
        let wrongShape: [String: Any] = ["answers": ["choice": ["foo": "bar"]]]
        let valid: [String: Any] = ["answers": ["choice": ["answers": ["推荐项"]]]]

        #expect(!WorkflowApprovalValidation.userInputAnswersAreComplete(empty, questions: questions))
        #expect(!WorkflowApprovalValidation.userInputAnswersAreComplete(blank, questions: questions))
        #expect(!WorkflowApprovalValidation.userInputAnswersAreComplete(wrongShape, questions: questions))
        #expect(WorkflowApprovalValidation.userInputAnswersAreComplete(valid, questions: questions))
        #expect(!WorkflowApprovalValidation.userInputAnswersAreComplete(
            valid,
            questions: [["id": "choice"], ["id": "choice"]]
        ))
    }

    @Test("accepted MCP elicitation requires content and required fields")
    func elicitationValidation() {
        let params: [String: Any] = [
            "requestedSchema": ["required": ["name"]],
        ]
        #expect(WorkflowApprovalValidation.elicitationResponseIsValid(
            ["action": "decline"],
            params: params
        ))
        #expect(!WorkflowApprovalValidation.elicitationResponseIsValid(
            ["action": "accept"],
            params: params
        ))
        #expect(!WorkflowApprovalValidation.elicitationResponseIsValid(
            ["action": "accept", "content": ["name": "   "]],
            params: params
        ))
        #expect(WorkflowApprovalValidation.elicitationResponseIsValid(
            ["action": "accept", "content": ["name": "Arkey"]],
            params: params
        ))
    }

    @Test("repeated status text still emits a new UI message event")
    @MainActor
    func repeatedMessageEvent() {
        let store = CommandSurfaceStore(controller: ArkeyController())
        let initialSequence = store.messageSequence
        store.message = "同一错误"
        let firstSequence = store.messageSequence
        store.message = "同一错误"

        #expect(firstSequence == initialSequence + 1)
        #expect(store.messageSequence == firstSequence + 1)
        #expect(store.messageSeverity == .info)

        store.publishMessage("显式错误", severity: .error)
        #expect(store.messageSeverity == .error)
        #expect(store.messageSequence == firstSequence + 2)
    }

    @Test("task stack waits for all six initial Agent Keys before replenishing")
    func initialAgentBatchConsumption() throws {
        var state = DockStackState.initial
        for ordinal in 1...5 {
            let replacement = state.consume(instanceId: "task-agent-\(ordinal)")
            #expect(replacement == nil)
            #expect(!state.actions.contains(where: { $0.id == "task-agent-7" }))
        }

        let seventhCandidate = state.consume(instanceId: "task-agent-6")
        let seventh = try #require(seventhCandidate)
        #expect(seventh.id == "task-agent-7")
        let eighthCandidate = state.consume(instanceId: "task-agent-7")
        let eighth = try #require(eighthCandidate)
        #expect(eighth.id == "task-agent-8")
    }

    @Test("repeatable non-task action returns at stack bottom")
    func repeatableActionReplenishes() throws {
        var state = DockStackState.initial
        let skill = CommandActionInstance(id: "skill-test", kind: .openSkill, title: "Skills", ordinal: nil, enabled: true)
        state.actions.append(skill)
        let replacementCandidate = state.consume(instanceId: skill.id)
        let replacement = try #require(replacementCandidate)
        #expect(replacement.kind == .openSkill)
        #expect(state.actions.last == replacement)

        let review = try #require(state.actions.first(where: { $0.kind == .reviewChanges }))
        #expect(state.consume(instanceId: review.id)?.kind == .reviewChanges)
        let continuation = try #require(state.actions.first(where: { $0.kind == .continueNewTask }))
        #expect(state.consume(instanceId: continuation.id)?.kind == .continueNewTask)
    }

    @Test("capability-gated actions remain visible but disabled by default")
    func disabledCapabilitiesRemainVisible() throws {
        let actions = CommandSurfaceDefaults.initialDock()
        #expect(try #require(actions.first(where: { $0.kind == .togglePlanMode })).enabled == false)
        #expect(try #require(actions.first(where: { $0.kind == .scheduledTasks })).enabled == false)
    }

    @Test("semantic overlay retains the exact 88/12 luminance mix")
    func semanticLuminanceMix() {
        #expect(ArkeyLightingMath.semanticBrightness(1, globalLuminance: 0) == 0.88)
        #expect(ArkeyLightingMath.semanticBrightness(0, globalLuminance: 1) == 0.12)
        #expect(ArkeyLightingMath.semanticBrightness(1, globalLuminance: 1) == 1)
        #expect(ArkeyLightingMath.semanticBrightness(-1, globalLuminance: -1) == 0)
    }

    @Test("Swift client consumes the canonical Micro effect catalog")
    func canonicalEffectCatalog() throws {
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent("profiles/effects-v1.json"))
        let catalog = try JSONDecoder().decode(EffectCatalogDocument.self, from: data)
        #expect(catalog.atmosphereMix == 0.12)
        #expect(catalog.semantics["working"]?.hex == "#304FFE")
        #expect(catalog.semantics["completeUnread"]?.entryPrimitive == .riseFade)
        #expect(catalog.semantics["requiresInput"]?.entryPrimitive == .doublePulse)
        #expect(catalog.voice["recording"]?.hex == "#20E0B2")
    }

    @Test("Codex Micro Lab configuration reports retain the isolated 64-byte framing")
    func codexMicroLabProtocolFraming() {
        let report = CodexMicroLabProtocol.encode(opcode: .set, sequence: 42, payload: [0, 4, 17])
        #expect(report.count == 64)
        #expect(report[0] == CodexMicroLabProtocol.reportID)
        #expect(report[1] == CodexMicroLabProtocol.magic)
        #expect(report[3] == CodexMicroLabProtocol.Opcode.set.rawValue)
        #expect(CodexMicroLabProtocol.decode(report) == .init(opcode: CodexMicroLabProtocol.Opcode.set.rawValue, sequence: 42, payload: [0, 4, 17]))
        let output = CodexMicroLabService.outputReportBuffer(report, reportID: CodexMicroLabProtocol.reportID)
        #expect(output.count == 64)
        #expect(output.first == CodexMicroLabProtocol.reportID)
        let macOSPaddedBody = Array(report.dropFirst()) + [0]
        #expect(CodexMicroLabProtocol.decode(macOSPaddedBody) == .init(opcode: CodexMicroLabProtocol.Opcode.set.rawValue, sequence: 42, payload: [0, 4, 17]))
        let v1PlaceholderBody = [UInt8(0)] + Array(report.dropFirst())
        #expect(CodexMicroLabProtocol.decode(v1PlaceholderBody) == .init(opcode: CodexMicroLabProtocol.Opcode.set.rawValue, sequence: 42, payload: [0, 4, 17]))
        let v1ShortPlaceholderBody = [UInt8(0)] + Array(report.dropFirst().dropLast())
        #expect(CodexMicroLabProtocol.decode(v1ShortPlaceholderBody) == .init(opcode: CodexMicroLabProtocol.Opcode.set.rawValue, sequence: 42, payload: [0, 4, 17]))
        let v1DoublePrefixedBody = [UInt8(0), CodexMicroLabProtocol.reportID] + Array(report.dropFirst().dropLast())
        #expect(CodexMicroLabProtocol.decode(v1DoublePrefixedBody) == .init(opcode: CodexMicroLabProtocol.Opcode.set.rawValue, sequence: 42, payload: [0, 4, 17]))
        #expect(CodexMicroLabTarget.command1.shortTitle == "ACT06")
        #expect(CodexMicroLabTarget.command5.shortTitle == "ACT10")
        #expect(CodexMicroLabTarget.command5.title.contains("原生 PTT"))
        #expect(CodexMicroLabTarget.command5.configurationHint?.contains("350 ms") == true)
        #expect(CodexMicroLabTarget.command6.shortTitle == "ACT12")

        let dfu = CodexMicroLabProtocol.encode(opcode: .enterDFU, sequence: 43, payload: Array("DFU!".utf8))
        #expect(CodexMicroLabProtocol.decode(dfu) == .init(opcode: CodexMicroLabProtocol.Opcode.enterDFU.rawValue, sequence: 43, payload: Array("DFU!".utf8)))
    }

    @Test("V1 Max default Micro map matches the firmware layout")
    func v1MaxCodexMicroDefaults() {
        let snapshot = CodexMicroLabSnapshot.v1MaxDefaults
        #expect(snapshot.mappings[.agent1] == .init(row: 1, column: 15))
        #expect(snapshot.mappings[.agent2] == .init(row: 2, column: 15))
        #expect(snapshot.mappings[.command5] == .init(row: 3, column: 15))
        #expect(snapshot.mappings[.encoderPress] == .init(row: 0, column: 15))
        #expect(snapshot.encoderEnabled)
    }

    @Test("Lab product names select the physical Q6 or V1 profile")
    func codexMicroLabProfileSelection() {
        #expect(CodexMicroLabProtocol.keyboardProfileID(forProductName: "ARkey V1 Max Codex Micro Lab") == "keychron-v1-max-ansi-knob")
        #expect(CodexMicroLabProtocol.keyboardProfileID(forProductName: "Arkey Codex Micro Lab") == "keychron-q6-pro-ansi")
    }

    @Test("Codex Micro Lab snapshot cache survives a pending readback")
    func codexMicroLabSnapshotCache() throws {
        let snapshot = CodexMicroLabSnapshot(
            mappings: [.agent1: .init(row: 4, column: 17)],
            encoderEnabled: true,
            verification: .pendingReadback
        )
        let restored = try JSONDecoder().decode(CodexMicroLabSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(restored == snapshot)
        #expect(restored.verification.detail.contains("暂不能读回"))
    }

    @Test("runtime events update dynamic actions and stop a stale client preview")
    @MainActor
    func runtimeEventSynchronization() throws {
        let store = CommandSurfaceStore(controller: ArkeyController())
        store.isPreviewing = true

        store.handleEventLine(#"{"type":"actions.changed","data":[{"actionId":"plan","enabled":true}]}"#)
        #expect(store.planAvailable)
        #expect(try #require(store.dock.first(where: { $0.kind == .togglePlanMode })).enabled)

        store.handleEventLine(#"{"type":"lighting.preview.stopped","data":{"reason":"device-disconnected"}}"#)
        #expect(!store.isPreviewing)
    }

    @Test("continuous capture rearms only after both binding ACK and physical release")
    func captureRearmGateRequiresBothSignals() {
        var releaseFirst = CaptureRearmGate()
        let releaseBeforeACK = releaseFirst.releaseObserved(token: 41)
        #expect(releaseFirst.hasPendingSignals)
        let releaseThenACK = releaseFirst.bindingCompleted(token: 41)
        #expect(!releaseBeforeACK)
        #expect(releaseThenACK)
        #expect(!releaseFirst.hasPendingSignals)

        var acknowledgementFirst = CaptureRearmGate()
        let acknowledgementBeforeRelease = acknowledgementFirst.bindingCompleted(token: 42)
        #expect(acknowledgementFirst.hasPendingSignals)
        let acknowledgementThenRelease = acknowledgementFirst.releaseObserved(token: 42)
        let duplicateRelease = acknowledgementFirst.releaseObserved(token: 42)
        #expect(!acknowledgementBeforeRelease)
        #expect(acknowledgementThenRelease)
        #expect(!duplicateRelease)
        #expect(acknowledgementFirst.hasPendingSignals)
        acknowledgementFirst.reset()
        #expect(!acknowledgementFirst.hasPendingSignals)
    }

    private var repositoryRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }
}
