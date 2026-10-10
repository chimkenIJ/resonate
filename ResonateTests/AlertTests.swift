import CoreGraphics
import Foundation
import Testing
@testable import Resonate

private func object(_ label: String, _ category: ObjectCategory, x: CGFloat, distance: Double?) -> DetectedObject {
    DetectedObject(label: label, category: category, confidence: 0.9,
                   boundingBox: CGRect(x: x - 0.05, y: 0.4, width: 0.1, height: 0.2), distanceMeters: distance)
}

struct ObstacleAlertComposerTests {
    @Test func ignoresThingsFarAwayOrWithoutDistance() {
        #expect(ObstacleAlertComposer.compose(from: [object("Bike", .vehicle, x: 0.5, distance: 9)]) == nil)
        #expect(ObstacleAlertComposer.compose(from: [object("Bike", .vehicle, x: 0.5, distance: nil)]) == nil)
    }

    @Test func ignoresWallsAndDoors() {
        #expect(ObstacleAlertComposer.compose(from: [object("Wall", .wall, x: 0.5, distance: 1)]) == nil)
    }

    @Test func obstacleOnTheLeftSaysStepRight() throws {
        let alert = try #require(ObstacleAlertComposer.compose(from: [object("Bike", .vehicle, x: 0.3, distance: 2)]))
        #expect(alert.severity == .headsUp)
        #expect(alert.headline == "Bike ahead, slightly left, 2 meters.")
        #expect(alert.guidance == "Step right to pass.")
    }

    @Test func veryCloseMeansStop() throws {
        let alert = try #require(ObstacleAlertComposer.compose(from: [object("Pole", .obstacle, x: 0.5, distance: 1)]))
        #expect(alert.severity == .stop)
    }

    @Test func dropOffOutranksACloserObstacleToTheSide() throws {
        let alert = try #require(ObstacleAlertComposer.compose(from: [
            object("Chair", .furniture, x: 0.9, distance: 2.5),
            object("Curb drop", .dropOff, x: 0.5, distance: 3.5),
        ]))
        #expect(alert.headline.hasPrefix("Curb drop"))
    }
}

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
