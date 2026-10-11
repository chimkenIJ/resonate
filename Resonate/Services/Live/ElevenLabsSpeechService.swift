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
/// - One voice, one sentence at a time; what's said next is decided by `SpeechQueue` (safety cuts in,
///   newer messages replace the rest of older ones).
/// - Safety alerts are built from pre-recorded pieces, so they play with no network wait, even offline.
/// - If the network is down and a phrase was never recorded, the phone's built-in voice says it
///   rather than leaving the user in silence. A message that falls back stays in that voice.
final class ElevenLabsSpeechService: NSObject, SpeechServicing, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    private let client: EdgeFunctionClient
    private var store = SpeechClipStore()
    private var voiceID: String?

    func selectVoice(_ id: String?) {
        guard voiceID != id else { return }
        // Don't stop what's playing: choosing a voice also plays its sample, and stopping here cut it off.
        // Anything spoken from now on uses the new voice.
        voiceID = id
        store = SpeechClipStore(voiceVersion: id ?? "matilda-v1")
        Task { await prewarm(SpeechPhrases.safety) }
    }

    /// True while a voice sample is playing or loading; background recording waits for it.
    private var isPreviewing = false

    func preview(_ text: String, voiceID: String?) async {
        guard !Task.isCancelled else { return }
        stop()
        isPreviewing = true
        let id = UUID()
        workerID = id
        isSpeaking = true
        worker = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            defer {
                if self.workerID == id {
                    self.isSpeaking = false
                    self.worker = nil
                    self.isPreviewing = false
                }
            }
            do {
                let data = try await self.fetch(text, timeout: 8, voiceID: voiceID)
                if Task.isCancelled { return }
                await self.playClips([data])
            } catch {
                if !Task.isCancelled { await self.speakOnDevice(text) }
            }
        }
    }

    func availableVoices() async throws -> [SpeechVoice] {
        nonisolated struct Body: Encodable, Sendable { let action = "voices" }
        nonisolated struct Response: Decodable, Sendable { let voices: [SpeechVoice] }
        return try await client.post("speak", body: Body(), as: Response.self).voices
    }

    private let deviceVoice = AVSpeechSynthesizer()
    private var deviceUtterance: AVSpeechUtterance?
    private var player: AVAudioPlayer?
    private var finished: CheckedContinuation<Void, Never>?
    private var queue = SpeechQueue()
    private var worker: Task<Void, Never>?
    /// The next sentence, fetched while the current one plays.
    private var prefetched: (text: String, task: Task<Data, Error>)?
    /// The message that fell back to the phone's voice, so its other sentences use it too.
    private var deviceVoiceMessage: Int?
    private var workerID = UUID()

    private(set) var isSpeaking = false
    private(set) var lastSpoken: String?

    /// Phrases up to this length are kept on the phone after the first time.
    private let cacheLimit = 200

    init(client: EdgeFunctionClient) {
        self.client = client
        super.init()
        deviceVoice.delegate = self
    }

    // MARK: SpeechServicing

    func speak(_ text: String, priority: SpeechPriority, fragments: [String]?) async {
        guard !Task.isCancelled else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        switch queue.enqueue(text, priority: priority, fragments: fragments) {
        case .ignored:
            return
        case .interruptNow:
            cutAudio()
        case .play:
            // A voice sample is playing: the app's own speech takes over.
            if isPreviewing { cutAudio() }
        }
        lastSpoken = text
        startWorkerIfIdle()
    }

    func waitUntilFinished() async {
        while let worker, !Task.isCancelled { await worker.value }
    }

    func stop() {
        lastSpoken = nil
        queue.clear()
        cutAudio()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func repeatLast() async {
        guard let lastSpoken else { return }
        await speak(lastSpoken, priority: .info, fragments: nil)
    }

    func prewarm(_ phrases: [String]) async {
        let store = self.store
        let voiceID = self.voiceID
        let missing = phrases.filter { !store.contains($0) }
        guard !missing.isEmpty else { return }
        Log.speech.notice("Recording \(missing.count) safety phrases in the app voice")
        // One at a time in the background, leaving ElevenLabs room for anything spoken now.
        // Pauses while a voice sample plays, and stops if the voice changes again.
        for phrase in missing {
            while isPreviewing { try? await Task.sleep(for: .milliseconds(200)) }
            guard self.voiceID == voiceID else { return }
            if let data = try? await fetch(phrase, timeout: 15, voiceID: voiceID) { store.store(data, for: phrase) }
        }
        Log.speech.notice("Safety phrases ready: \(phrases.filter(store.contains).count)/\(phrases.count)")
    }

    // MARK: Playback queue

    /// Plays the queue one sentence at a time until it's empty.
    private func startWorkerIfIdle() {
        guard worker == nil else { return }
        let id = UUID()
        workerID = id
        isSpeaking = true
        worker = Task { [weak self] in
            while let self, !Task.isCancelled, let sentence = self.queue.next() {
                self.prefetch(self.queue.upcoming)
                await self.play(sentence)
            }
            guard let self, self.workerID == id else { return }
            self.isSpeaking = false
            self.worker = nil
            self.deviceVoiceMessage = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// Silences whatever is playing right now (the app voice and the phone's voice) without touching the queue.
    private func cutAudio() {
        worker?.cancel()
        worker = nil
        player?.stop()
        player = nil
        deviceUtterance = nil
        // Always: an utterance that's queued but hasn't started yet doesn't count as speaking,
        // and would otherwise still be read out after the screen closed.
        deviceVoice.stopSpeaking(at: .immediate)
        resumeFinished()
        prefetched?.task.cancel()
        prefetched = nil
        deviceVoiceMessage = nil
        isSpeaking = false
        isPreviewing = false
        workerID = UUID()
    }

    private func play(_ sentence: SpeechQueue.Sentence) async {
        if deviceVoiceMessage == sentence.message {
            await speakOnDevice(sentence.text)
            return
        }
        if let clips = recordedClips(for: sentence) {
            await playClips(clips)
            return
        }
        do {
            let data: Data
            if let prefetched, prefetched.text == sentence.text {
                self.prefetched = nil
                data = try await prefetched.task.value
            } else {
                // Safety can't wait long: if the voice service is slow, fall back right away.
                data = try await fetch(sentence.text, timeout: sentence.priority == .safety ? 2 : 8, voiceID: voiceID)
            }
            if Task.isCancelled { return }
            if sentence.text.count <= cacheLimit { store.store(data, for: sentence.text) }
            await playClips([data])
        } catch {
            if Task.isCancelled { return }
            Log.speech.error("ElevenLabs unavailable, using the device voice: \(String(describing: error), privacy: .public)")
            deviceVoiceMessage = sentence.message
            await speakOnDevice(sentence.text)
        }
    }

    /// The sentence from clips already on the phone (whole, or from its pre-recorded pieces).
    private func recordedClips(for sentence: SpeechQueue.Sentence) -> [Data]? {
        if let clip = store.data(for: sentence.text) { return [clip] }
        guard let fragments = sentence.fragments else { return nil }
        let clips = fragments.compactMap(store.data(for:))
        return clips.count == fragments.count ? clips : nil
    }

    /// Starts fetching the next sentence so it plays without a gap.
    private func prefetch(_ sentence: SpeechQueue.Sentence?) {
        guard let sentence, prefetched?.text != sentence.text, deviceVoiceMessage != sentence.message,
              recordedClips(for: sentence) == nil else { return }
        prefetched?.task.cancel()
        let voiceID = voiceID
        let timeout: TimeInterval = sentence.priority == .safety ? 2 : 8
        prefetched = (sentence.text, Task { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.fetch(sentence.text, timeout: timeout, voiceID: voiceID)
        })
    }

    private func playClips(_ clips: [Data]) async {
        guard !Task.isCancelled else { return }
        let playbackID = workerID
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
        if workerID == playbackID { player = nil }
    }

    private func speakOnDevice(_ text: String) async {
        guard !Task.isCancelled else { return }
        activateAudioSession()
        let utterance = AVSpeechUtterance(string: text)
        utterance.prefersAssistiveTechnologySettings = true
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        deviceUtterance = utterance
        await withCheckedContinuation { continuation in
            finished = continuation
            deviceVoice.speak(utterance)
        }
    }

    private func fetch(_ text: String, timeout: TimeInterval, voiceID: String?) async throws -> Data {
        try Task.checkCancellation()
        nonisolated struct Body: Encodable, Sendable { let text: String; let voiceID: String? }
        return try await client.postForData("speak", body: Body(text: text, voiceID: voiceID), timeout: timeout)
    }

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        // Don't take over the microphone session while voice search is listening.
        if session.category != .playAndRecord {
            try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        } else {
            // While recording, make sure speech still comes out of the loudspeaker, not the earpiece.
            try? session.overrideOutputAudioPort(.speaker)
        }
        try? session.setActive(true)
    }

    private func resumeFinished() {
        let continuation = finished
        finished = nil
        continuation?.resume()
    }

    // MARK: Delegates (called on the main thread)

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard self.player === player else { return }
        resumeFinished()
    }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        guard self.player === player else { return }
        resumeFinished()
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard deviceUtterance === utterance else { return }
        deviceUtterance = nil
        resumeFinished()
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        guard deviceUtterance === utterance else { return }
        deviceUtterance = nil
        resumeFinished()
    }
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
