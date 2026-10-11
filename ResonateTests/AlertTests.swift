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
        // With voice on, only immediate danger buzzes.
        #expect(haptics.played.isEmpty)
    }

    @Test func withVoiceOnlyDangerBuzzes() async {
        let (center, _, haptics) = makeCenter(channels: [.voice, .buzzes])
        center.proximityPulse()
        await center.announce("Turn left.", priority: .navigation, haptic: .turnLeft)
        #expect(haptics.played.isEmpty)
        let stop = ObstacleAlert(severity: .stop, headline: "Stop. Post ahead.", guidance: "Veer left.", guidanceIcon: .slightLeft, dedupeKey: "post")
        await center.deliverUrgent(stop)
        #expect(haptics.played == [.stop])
    }

    @Test func withoutVoiceTurnsStillBuzz() async {
        let (center, _, haptics) = makeCenter(channels: [.buzzes])
        await center.announce("Turn left.", priority: .navigation, haptic: .turnLeft)
        #expect(haptics.played == [.turnLeft])
    }

    @Test func respectsTheChosenChannels() async {
        let (center, speech, haptics) = makeCenter(channels: [.buzzes])
        await center.deliver(bike)
        #expect(speech.log.isEmpty)
        #expect(haptics.played == [.headsUp])
    }
}
