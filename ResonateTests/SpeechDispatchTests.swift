import Foundation
import Testing
@testable import Resonate

/// Guards the "voice sample is silent" bug: a method that only lived in a protocol extension was called
/// through `any SpeechServicing`, so the empty default ran instead of the real service.
@MainActor
struct SpeechDispatchTests {
    final class Spy: SpeechServicing {
        var previews: [(String, String?)] = []
        var isSpeaking = false
        var lastSpoken: String?
        func speak(_ text: String, priority: SpeechPriority, fragments: [String]?) async {}
        func stop() {}
        func repeatLast() async {}
        func prewarm(_ phrases: [String]) async {}
        func preview(_ text: String, voiceID: String?) async { previews.append((text, voiceID)) }
    }

    @Test func voiceSamplesReachTheRealService() async {
        let spy = Spy()
        let model = PersonalizeViewModel(mode: .settings, preferences: UserPreferences()) { _ in }
        await model.preview(name: "Bella", voiceID: "bella-id", using: spy as any SpeechServicing)
        #expect(spy.previews.count == 1)
        #expect(spy.previews.first?.1 == "bella-id")
    }
}
