import AVFoundation
import Foundation
import Speech

/// Voice input for destination search with SFSpeechRecognizer. Runs on-device when the phone
/// supports it, so it works offline and audio never leaves the phone.
///
/// The microphone is on only while listening:
/// - `stop()` (the user taps the mic again, or they pause) turns the mic off at once and finishes
///   with what was heard.
/// - `cancel()` (leaving the screen) turns it off and discards the result.
final class LiveSpeechRecognitionService: SpeechRecognitionServicing {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    private var watchdog: Task<Void, Never>?
    private var lastTranscript = ""
    private var lastChange = Date.now

    /// Stop after the words haven't changed for this long (background noise doesn't count).
    private let silenceTimeout: TimeInterval = 1.6
    /// Stop after this long if nothing at all was heard.
    private let noSpeechTimeout: TimeInterval = 6
    /// Never listen longer than this.
    private let maxDuration: TimeInterval = 12
    /// After the mic is off, wait this long for the recognizer's final result.
    private let finalResultGrace: Duration = .milliseconds(1500)

    var isListening: Bool { engine != nil }

    func requestAuthorization() async -> Bool {
        let speechAllowed = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speechAllowed else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    func transcribe() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            do {
                try start(continuation)
            } catch {
                continuation.finish(throwing: error)
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.teardown() }
            }
        }
    }

    func stop() {
        guard engine != nil || continuation != nil else { return }
        turnOffMicrophone()
        // Give the recognizer a moment to deliver its final transcript, then end regardless.
        let grace = finalResultGrace
        Task { [weak self] in
            try? await Task.sleep(for: grace)
            self?.teardown()
        }
    }

    func cancel() {
        task?.cancel()
        teardown()
    }

    // MARK: - Lifecycle

    private func start(_ continuation: AsyncThrowingStream<String, Error>.Continuation) throws {
        teardown()
        guard let recognizer, recognizer.isAvailable else {
            throw AppError.server(message: "Voice input isn't available right now. You can type the place instead.")
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = false
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let engine = AVAudioEngine()
        Self.installTap(on: engine.inputNode, feeding: request)
        engine.prepare()
        try engine.start()

        self.engine = engine
        self.request = request
        self.continuation = continuation
        lastTranscript = ""
        lastChange = .now
        task = Self.recognize(with: recognizer, request: request, continuation: continuation) { [weak self] text in
            guard let self else { return }
            Task { @MainActor in self.noteTranscript(text) }
        }
        startWatchdog()
    }

    private func noteTranscript(_ text: String) {
        guard text != lastTranscript else { return }
        lastTranscript = text
        lastChange = .now
    }

    private func startWatchdog() {
        let started = Date.now
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.engine != nil else { return }
                let now = Date.now
                let heard = !self.lastTranscript.isEmpty
                let paused = heard && now.timeIntervalSince(self.lastChange) >= self.silenceTimeout
                let nothing = !heard && now.timeIntervalSince(started) >= self.noSpeechTimeout
                if paused || nothing || now.timeIntervalSince(started) >= self.maxDuration {
                    self.stop()
                    return
                }
            }
        }
    }

    /// Stops recording and releases the microphone (the orange indicator goes away).
    private func turnOffMicrophone() {
        watchdog?.cancel()
        watchdog = nil
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        request?.endAudio()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func teardown() {
        turnOffMicrophone()
        request = nil
        task = nil
        continuation?.finish()
        continuation = nil
    }

    // These run on audio and recognition threads, so they're built outside the main actor.

    private nonisolated static func installTap(on input: AVAudioInputNode, feeding request: SFSpeechAudioBufferRecognitionRequest) {
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
    }

    private nonisolated static func recognize(
        with recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest,
        continuation: AsyncThrowingStream<String, Error>.Continuation,
        onTranscript: @escaping @Sendable (String) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            if let result {
                let text = result.bestTranscription.formattedString
                continuation.yield(text)
                onTranscript(text)
                if result.isFinal { continuation.finish() }
            } else if let error {
                // "No speech detected" and cancellation end the stream quietly;
                // the caller treats empty text as "didn't hear anything".
                let code = (error as NSError).code
                if [1110, 216, 301, 203].contains(code) {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
