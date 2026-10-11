import CoreGraphics
import Foundation
import Testing
@testable import Resonate

@MainActor
struct FeedbackCenterTests {
    private func makeCenter(channels: Set<AlertChannel>) -> (FeedbackCenter, MockSpeechService, MockHapticsService) {
        let speech = MockSpeechService(), haptics = MockHapticsService()
        var preferences = UserPreferences()
        preferences.alertChannels = channels
        return (FeedbackCenter(speech: speech, haptics: haptics, tones: MockTonesService(), preferences: preferences), speech, haptics)
    }

    private let bike = ObstacleAlert(severity: .headsUp, headline: "Bike ahead.", guidance: "Step right.", guidanceIcon: .slightRight, dedupeKey: "Bike-ahead")

    @Test func doesNotRepeatTheSameObstacleRightAway() async {
        let (center, speech, haptics) = makeCenter(channels: [.voice, .buzzes])
        let start = Date(timeIntervalSince1970: 0)
        #expect(await center.deliver(bike, now: start))
        #expect(await center.deliver(bike, now: start.addingTimeInterval(2)) == false)
        #expect(await center.deliver(bike, now: start.addingTimeInterval(7)))
        #expect(speech.log.count == 2)
        #expect(haptics.played == [.headsUp, .headsUp])
    }

    @Test func respectsTheChosenChannels() async {
        let (center, speech, haptics) = makeCenter(channels: [.buzzes])
        await center.deliver(bike)
        #expect(speech.log.isEmpty)
        #expect(haptics.played == [.headsUp])
    }
}
