import AVFoundation
import CryptoKit
import Foundation
import OSLog

/// Clips in the app's ElevenLabs voice, kept on the phone (Application Support, not backed up).
/// Each phrase is generated once; after that it plays instantly, offline, and costs nothing.
nonisolated final class SpeechClipStore: @unchecked Sendable {
    private let directory: URL

    /// Bump `voiceVersion` after changing ELEVENLABS_VOICE_ID so old clips aren't mixed with the new voice.
    init(voiceVersion: String = "matilda-v1") {
        var directory = URL.applicationSupportDirectory.appending(path: "speech/\(voiceVersion)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        self.directory = directory
    }

    private func url(for text: String) -> URL {
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(digest).mp3")
    }

    func data(for text: String) -> Data? { try? Data(contentsOf: url(for: text)) }
    func contains(_ text: String) -> Bool { FileManager.default.fileExists(atPath: url(for: text).path()) }
    func store(_ data: Data, for text: String) { try? data.write(to: url(for: text), options: .atomic) }
}

/// The app's voice, from ElevenLabs through the `speak` Edge Function.
///
/// - Safety alerts interrupt anything; navigation interrupts info; otherwise phrases queue (briefly).
/// - Safety alerts are built from pre-recorded pieces, so they play with no network wait, even offline.
/// - If the network is down and a phrase was never recorded, the phone's built-in voice says it
///   rather than leaving the user in silence.
final class ElevenLabsSpeechService: NSObject, SpeechServicing, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    private struct Utterance {
        let text: String
        let priority: SpeechPriority
        let fragments: [String]?
    }

    private let client: EdgeFunctionClient
    private let store = SpeechClipStore()
    private let deviceVoice = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var finished: CheckedContinuation<Void, Never>?
    private var pending: [Utterance] = []
    private var current: Utterance?
    private var worker: Task<Void, Never>?
    private var workerID = UUID()

    private(set) var isSpeaking = false
    private(set) var lastSpoken: String?

    /// Phrases up to this length are kept on the phone after the first time.
    private let cacheLimit = 200
    /// Don't let the queue fall behind what's happening.
    private let maxPending = 2

    init(client: EdgeFunctionClient) {
        self.client = client
        super.init()
        deviceVoice.delegate = self
    }

    // MARK: SpeechServicing

    func speak(_ text: String, priority: SpeechPriority, fragments: [String]?) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        lastSpoken = text
        let utterance = Utterance(text: text, priority: priority, fragments: fragments)

        if let current, !(priority > current.priority || (priority == .safety && current.priority == .safety)) {
            pending.append(utterance)
            if pending.count > maxPending { pending.removeFirst() }
            return
        }
        // More urgent (or a newer safety alert): cut in now, and drop anything less urgent that was waiting.
        if current != nil { interrupt() }
        pending.removeAll { $0.priority < priority }
        pending.insert(utterance, at: 0)
        startWorker()
    }

    func stop() {
        pending.removeAll()
        interrupt()
    }

    func repeatLast() async {
        guard let lastSpoken else { return }
        await speak(lastSpoken, priority: .info, fragments: nil)
    }

    func prewarm(_ phrases: [String]) async {
        let missing = phrases.filter { !store.contains($0) }
        guard !missing.isEmpty else { return }
        Log.speech.notice("Recording \(missing.count) safety phrases in the app voice")
        var index = 0
        // A few at a time, to stay within ElevenLabs' concurrency limit.
        while index < missing.count {
            let batch = missing[index..<min(index + 3, missing.count)]
            await withTaskGroup(of: Void.self) { group in
                for phrase in batch {
                    group.addTask { [self] in
                        if let data = try? await self.fetch(phrase, timeout: 15) { self.store.store(data, for: phrase) }
                    }
                }
            }
            index += 3
        }
        Log.speech.notice("Safety phrases ready: \(phrases.filter(self.store.contains).count)/\(phrases.count)")
    }

    // MARK: Playback queue

    private func startWorker() {
        worker?.cancel()
        let id = UUID()
        workerID = id
        worker = Task { [weak self] in
            while let self, !Task.isCancelled, !self.pending.isEmpty {
                let next = self.pending.removeFirst()
                self.current = next
                self.isSpeaking = true
                await self.play(next)
                if self.workerID == id { self.current = nil }
            }
            guard let self, self.workerID == id else { return }
            self.isSpeaking = false
            self.worker = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func interrupt() {
        worker?.cancel()
        worker = nil
        player?.stop()
        player = nil
        if deviceVoice.isSpeaking { deviceVoice.stopSpeaking(at: .immediate) }
        resumeFinished()
        current = nil
    }

    private func play(_ utterance: Utterance) async {
        if let clip = store.data(for: utterance.text) {
            await playClips([clip])
            return
        }
        if let fragments = utterance.fragments {
            let clips = fragments.compactMap(store.data(for:))
            if clips.count == fragments.count {
                await playClips(clips)
                return
            }
        }
        do {
            // Safety can't wait long: if the voice service is slow, fall back right away.
            let data = try await fetch(utterance.text, timeout: utterance.priority == .safety ? 2 : 8)
            if Task.isCancelled { return }
            if utterance.text.count <= cacheLimit { store.store(data, for: utterance.text) }
            await playClips([data])
        } catch {
            if Task.isCancelled { return }
            Log.speech.error("ElevenLabs unavailable, using the device voice: \(String(describing: error), privacy: .public)")
            await speakOnDevice(utterance.text)
        }
    }

    private func playClips(_ clips: [Data]) async {
        activateAudioSession()
        for clip in clips {
            if Task.isCancelled { return }
            guard let player = try? AVAudioPlayer(data: clip) else { continue }
            player.delegate = self
            self.player = player
            await withCheckedContinuation { continuation in
                finished = continuation
                if !player.play() { resumeFinished() }
            }
        }
        player = nil
    }

    private func speakOnDevice(_ text: String) async {
        activateAudioSession()
        let utterance = AVSpeechUtterance(string: text)
        utterance.prefersAssistiveTechnologySettings = true
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        await withCheckedContinuation { continuation in
            finished = continuation
            deviceVoice.speak(utterance)
        }
    }

    private func fetch(_ text: String, timeout: TimeInterval) async throws -> Data {
        nonisolated struct Body: Encodable, Sendable { let text: String }
        return try await client.postForData("speak", body: Body(text: text), timeout: timeout)
    }

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        // Don't take over the microphone session while voice search is listening.
        if session.category != .playAndRecord {
            try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        }
        try? session.setActive(true)
    }

    private func resumeFinished() {
        let continuation = finished
        finished = nil
        continuation?.resume()
    }

    // MARK: Delegates (called on the main thread)

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { resumeFinished() }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) { resumeFinished() }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { resumeFinished() }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { resumeFinished() }
}

/// Scene descriptions from Gemini, through the `describe` Edge Function. One photo per request; not stored.
final class GeminiSceneDescriptionService: SceneDescriptionServicing {
    private let client: EdgeFunctionClient

    init(client: EdgeFunctionClient) {
        self.client = client
    }

    private nonisolated struct Request: Encodable, Sendable {
        let imageBase64: String
        let setting: String
    }

    private nonisolated struct Response: Decodable, Sendable {
        let description: String
    }

    func describe(jpeg: Data, setting: SceneSetting) async throws -> String {
        guard !jpeg.isEmpty else { throw AppError.server(message: "The camera isn't ready yet.") }
        return try await client.post(
            "describe",
            body: Request(imageBase64: jpeg.base64EncodedString(), setting: setting.rawValue),
            as: Response.self,
            timeout: 25
        ).description
    }
}
