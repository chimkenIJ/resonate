import Foundation
import Testing
@testable import Resonate

struct PreferencesTests {
    @Test func oldPreferencesKeepDefaultVoice() throws {
        let data = Data(#"{"needs":["gettingAround"],"alertChannels":["voice"],"routing":{"avoidSteps":true,"maxIncline":0.08,"preferTactilePaving":true,"preferAudioSignals":true}}"#.utf8)
        let preferences = try JSONDecoder().decode(UserPreferences.self, from: data)
        #expect(preferences.voiceID == nil)
        #expect(preferences.routing.avoidSteps)
    }

    @Test @MainActor func onboardingCommitsRoutingAndVoice() async throws {
        var saved: Data?
        let model = PersonalizeViewModel(mode: .onboarding, preferences: UserPreferences()) { preferences in
            #expect(preferences.routing.maxIncline == 0.04)
            saved = try JSONEncoder().encode(preferences)
        }
        model.routing.avoidSteps = false
        model.routing.maxIncline = 0.04
        #expect(model.routing.maxIncline == 0.04)
        model.voiceID = "selected-voice"
        #expect(saved == nil)
        await model.commit()
        let data = try #require(saved)
        let result = try JSONDecoder().decode(UserPreferences.self, from: data)
        #expect(result.routing.avoidSteps == false)
        #expect(result.routing.maxIncline == 0.04)
        #expect(result.voiceID == "selected-voice")
    }
}
