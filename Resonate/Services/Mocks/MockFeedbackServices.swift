import Foundation
import SwiftUI

/// Stands in for the ElevenLabs voice. Keeps a log, and when VoiceOver is running it posts
/// an announcement so the mock app is still usable without sound.
final class MockSpeechService: SpeechServicing {
    private(set) var isSpeaking = false
    private(set) var lastSpoken: String?
    private(set) var log: [(text: String, priority: SpeechPriority)] = []

    func speak(_ text: String, priority: SpeechPriority) async {
        log.append((text, priority))
        lastSpoken = text
        isSpeaking = true
        print("[speech:\(priority)] \(text)")
        AccessibilityNotification.Announcement(text).post()
        isSpeaking = false
    }

    func stop() { isSpeaking = false }

    func repeatLast() async {
        guard let lastSpoken else { return }
        await speak(lastSpoken, priority: .info)
    }
}

final class MockSpeechRecognitionService: SpeechRecognitionServicing {
    /// What the mock "hears". Change it in previews to test other searches.
    var scriptedTranscript = "Kroger"

    func requestAuthorization() async -> Bool { true }

    func transcribe() -> AsyncThrowingStream<String, Error> {
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
}

final class MockHapticsService: HapticsServicing {
    private(set) var played: [HapticCue] = []
    func play(_ cue: HapticCue) { played.append(cue) }
}

final class MockTonesService: TonesServicing {
    private(set) var played: [ToneCue] = []
    func play(_ cue: ToneCue) { played.append(cue) }
}
