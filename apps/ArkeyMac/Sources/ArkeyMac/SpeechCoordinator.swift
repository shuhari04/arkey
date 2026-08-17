@preconcurrency import AVFoundation
import Combine
import Foundation
@preconcurrency import Speech

enum VoicePermissionStatus: String, Codable, CaseIterable, Sendable {
    case notDetermined
    case requesting
    case authorized
    case denied
    case restricted

    var isAuthorized: Bool { self == .authorized }
}

/// Owns one in-memory speech-recognition session for the Command Surface PTT key.
///
/// The coordinator intentionally has no knowledge of the Composer or Codex. It only
/// publishes recognition state/text and never sends a turn, clears an editor, or
/// writes an audio file.
@MainActor
final class SpeechCoordinator: ObservableObject {
    typealias TranscriptHandler = @MainActor (String) -> Void

    @Published private(set) var state: VoiceCaptureState = .idle
    @Published private(set) var permissionStatus: VoicePermissionStatus = .notDetermined
    @Published private(set) var isRecognizerAvailable = false
    @Published private(set) var transcript = ""
    @Published private(set) var finalTranscript: String?
    @Published private(set) var errorMessage: String?

    /// Optional in-memory delivery hooks for a Composer reducer.
    var onPartialTranscript: TranscriptHandler?
    var onFinalTranscript: TranscriptHandler?

    private let audioEngine: AVAudioEngine
    private let recognizer: SFSpeechRecognizer?
    private let doublePressInterval: TimeInterval

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var permissionTask: Task<Void, Never>?
    private var pendingReleaseTask: Task<Void, Never>?
    private var finalResultTimeoutTask: Task<Void, Never>?
    private var firstPressAt: Date?
    private var tapInstalled = false
    private var recognitionSessionID: UUID?

    init(
        locale: Locale = .current,
        doublePressInterval: TimeInterval = 0.35,
        audioEngine: AVAudioEngine = AVAudioEngine()
    ) {
        self.audioEngine = audioEngine
        self.recognizer = SFSpeechRecognizer(locale: locale)
        self.doublePressInterval = doublePressInterval
        refreshPermissionStatus()
    }

    var isCapturing: Bool {
        state == .recording || state == .locked
    }

    var isLocked: Bool { state == .locked }

    /// Re-reads system authorization and current recognizer availability.
    func refreshPermissionStatus() {
        permissionStatus = Self.combinedPermissionStatus(
            speech: SFSpeechRecognizer.authorizationStatus(),
            microphone: AVCaptureDevice.authorizationStatus(for: .audio)
        )
        isRecognizerAvailable = recognizer?.isAvailable ?? false
    }

    /// Requests both permissions. Callbacks only update this component's published
    /// state; capture never starts implicitly after the system sheets close.
    func requestPermissions() {
        permissionTask?.cancel()
        permissionStatus = .requesting

        permissionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await Self.requestSpeechAuthorization()
            guard !Task.isCancelled else { return }
            _ = await Self.requestMicrophoneAuthorization()
            guard !Task.isCancelled else { return }
            refreshPermissionStatus()
        }
    }

    /// PTT pointer/key down. A second down within 350 ms locks the active recording;
    /// when already locked, the next down ends capture.
    func pressBegan(at date: Date = Date()) {
        pendingReleaseTask?.cancel()
        pendingReleaseTask = nil

        switch state {
        case .locked:
            firstPressAt = nil
            stopRecording()

        case .recording:
            if let firstPressAt,
               date.timeIntervalSince(firstPressAt) >= 0,
               date.timeIntervalSince(firstPressAt) <= doublePressInterval {
                self.firstPressAt = nil
                state = .locked
            }

        case .idle, .ready, .error:
            firstPressAt = date
            startRecording()

        case .processing:
            break
        }
    }

    /// PTT pointer/key up. A long hold stops immediately. A short first tap waits
    /// only for the rest of the double-press window so a second down can lock it.
    func pressEnded(at date: Date = Date()) {
        guard state == .recording else { return }

        let elapsed = max(0, date.timeIntervalSince(firstPressAt ?? date))
        let remaining = doublePressInterval - elapsed
        guard remaining > 0 else {
            firstPressAt = nil
            stopRecording()
            return
        }

        pendingReleaseTask?.cancel()
        pendingReleaseTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(remaining))
            } catch {
                return
            }
            guard let self, state == .recording else { return }
            firstPressAt = nil
            stopRecording()
        }
    }

    /// Starts a fresh in-memory recognition session without involving double-tap UI.
    func startRecording() {
        refreshPermissionStatus()
        guard permissionStatus == .authorized else {
            publishError(permissionErrorDescription)
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            isRecognizerAvailable = false
            publishError("当前语音识别服务不可用，请稍后重试。")
            return
        }
        guard state != .recording, state != .locked else { return }

        stopAudioInput()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        finalResultTimeoutTask?.cancel()
        finalResultTimeoutTask = nil

        errorMessage = nil
        transcript = ""
        finalTranscript = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        recognitionRequest = request

        let sessionID = UUID()
        recognitionSessionID = sessionID

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errorText = error?.localizedDescription

            Task { @MainActor [weak self] in
                self?.receiveRecognitionResult(
                    sessionID: sessionID,
                    text: text,
                    isFinal: isFinal,
                    errorDescription: errorText
                )
            }
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            terminateRecognition(cancelTask: true)
            publishError("没有检测到可用的麦克风输入。")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        tapInstalled = true

        do {
            audioEngine.prepare()
            try audioEngine.start()
            state = .recording
            isRecognizerAvailable = true
        } catch {
            terminateRecognition(cancelTask: true)
            publishError("无法启动麦克风：\(error.localizedDescription)")
        }
    }

    /// Ends audio input and waits for the recognizer's final result. No Codex turn is
    /// started; consumers must explicitly invoke Send after state becomes `.ready`.
    func stopRecording() {
        guard state == .recording || state == .locked else { return }

        pendingReleaseTask?.cancel()
        pendingReleaseTask = nil
        firstPressAt = nil
        state = .processing
        stopAudioInput()
        recognitionRequest?.endAudio()
        scheduleFinalResultTimeout()
    }

    /// Cancels an active/pending session. Already delivered text is retained so a
    /// caller's Composer and the latest transcript cannot be erased accidentally.
    func cancel() {
        permissionTask?.cancel()
        permissionTask = nil
        pendingReleaseTask?.cancel()
        pendingReleaseTask = nil
        finalResultTimeoutTask?.cancel()
        finalResultTimeoutTask = nil
        firstPressAt = nil
        terminateRecognition(cancelTask: true)
        state = .idle
    }

    /// Returns the Micro-style voice flow to idle only after Composer Send has
    /// succeeded. A ready transcript never starts a Codex turn on its own.
    func markPromptSent() {
        guard state == .ready else { return }
        transcript = ""
        finalTranscript = nil
        errorMessage = nil
        state = .idle
    }

    /// Releases engine/task resources. This is safe to call when a drawer/window
    /// disappears and, like `cancel`, deliberately retains published text.
    func cleanup() {
        cancel()
        onPartialTranscript = nil
        onFinalTranscript = nil
    }

    private var permissionErrorDescription: String {
        switch permissionStatus {
        case .notDetermined:
            "需要先允许麦克风与语音识别权限。"
        case .requesting:
            "正在请求麦克风与语音识别权限。"
        case .denied:
            "麦克风或语音识别权限已被拒绝，请在系统设置中允许 ARkey。"
        case .restricted:
            "此 Mac 限制了麦克风或语音识别权限。"
        case .authorized:
            "语音权限不可用。"
        }
    }

    private func receiveRecognitionResult(
        sessionID: UUID,
        text: String?,
        isFinal: Bool,
        errorDescription: String?
    ) {
        guard recognitionSessionID == sessionID else { return }

        if let text, !text.isEmpty {
            transcript = text
            onPartialTranscript?(text)
        }

        if isFinal {
            finishWithBestAvailableTranscript(text)
            return
        }

        if let errorDescription {
            if state == .processing, !transcript.isEmpty {
                finishWithBestAvailableTranscript(transcript)
            } else {
                terminateRecognition(cancelTask: true)
                publishError("语音识别失败：\(errorDescription)")
            }
        }
    }

    private func finishWithBestAvailableTranscript(_ candidate: String?) {
        let text = (candidate?.isEmpty == false ? candidate : transcript) ?? ""
        finalResultTimeoutTask?.cancel()
        finalResultTimeoutTask = nil
        terminateRecognition(cancelTask: false)

        guard !text.isEmpty else {
            publishError("没有识别到语音内容。")
            return
        }

        transcript = text
        finalTranscript = text
        state = .ready
        onFinalTranscript?(text)
    }

    private func scheduleFinalResultTimeout() {
        finalResultTimeoutTask?.cancel()
        finalResultTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            guard let self, state == .processing else { return }
            if transcript.isEmpty {
                terminateRecognition(cancelTask: true)
                publishError("语音识别等待超时，请重试。")
            } else {
                finishWithBestAvailableTranscript(transcript)
            }
        }
    }

    private func stopAudioInput() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }

    private func terminateRecognition(cancelTask: Bool) {
        stopAudioInput()
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        if cancelTask {
            recognitionTask?.cancel()
        }
        recognitionTask = nil
        recognitionSessionID = nil
    }

    private func publishError(_ message: String) {
        errorMessage = message
        state = .error
    }

    nonisolated private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    nonisolated private static func requestMicrophoneAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    nonisolated private static func combinedPermissionStatus(
        speech: SFSpeechRecognizerAuthorizationStatus,
        microphone: AVAuthorizationStatus
    ) -> VoicePermissionStatus {
        if speech == .denied || microphone == .denied {
            return .denied
        }
        if speech == .restricted || microphone == .restricted {
            return .restricted
        }
        if speech == .authorized, microphone == .authorized {
            return .authorized
        }
        return .notDetermined
    }
}
