import Foundation
import OSLog
import SwiftUI

/// Stands in for the ElevenLabs voice. Keeps a log, and when VoiceOver is running it posts
/// an announcement so the mock app is still usable without sound.
final class MockSpeechService: SpeechServicing {
    private(set) var isSpeaking = false
    private(set) var lastSpoken: String?
    private(set) var log: [(text: String, priority: SpeechPriority)] = []

    func prewarm(_ phrases: [String]) async {}

    func speak(_ text: String, priority: SpeechPriority, fragments: [String]?) async {
        log.append((text, priority))
        lastSpoken = text
        isSpeaking = true
        Log.speech.notice("[\(String(describing: priority), privacy: .public)] \(text, privacy: .public)")
        AccessibilityNotification.Announcement(text).post()
        isSpeaking = false
    }

    func waitUntilFinished() async {}

    func stop() {
        isSpeaking = false
        lastSpoken = nil
    }

    func repeatLast() async {
        guard let lastSpoken else { return }
        await speak(lastSpoken, priority: .info)
    }
}

final class MockSpeechRecognitionService: SpeechRecognitionServicing {
    /// What the mock "hears". Change it in previews to test other searches.
    var scriptedTranscript = "Kroger"
    /// After hearing the script, the mock hears silence for this long, like a user who said one
    /// thing and stopped. Without it the always-listening voice assistant would repeat forever.
    var quietAfterSpeaking: Duration = .seconds(20)
    private var lastSpoke: ContinuousClock.Instant?

    func requestAuthorization() async -> Bool { true }

    func transcribe(endsOnPause: Bool) -> AsyncThrowingStream<String, Error> {
        let now = ContinuousClock.now
        if let lastSpoke, now - lastSpoke < quietAfterSpeaking {
            return AsyncThrowingStream { continuation in
                let task = Task {
                    try? await Task.sleep(for: .seconds(2))
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        lastSpoke = now
        let words = scriptedTranscript
        return AsyncThrowingStream { continuation in
            let task = Task {
                var partial = ""
                for character in words {
                    partial.append(character)
                    continuation.yield(partial)
                    try? await Task.sleep(for: .milliseconds(80))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func stop() {}
    func cancel() {}
}

final class MockHapticsService: HapticsServicing {
    private(set) var played: [HapticCue] = []
    func play(_ cue: HapticCue) { played.append(cue) }
}

final class MockTonesService: TonesServicing {
    private(set) var played: [ToneCue] = []
    func play(_ cue: ToneCue) { played.append(cue) }
}
