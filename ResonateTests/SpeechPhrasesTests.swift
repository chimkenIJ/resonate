import CoreGraphics
import Foundation
import Testing
@testable import Resonate

struct SpeechPhrasesTests {
    private let recorded = Set(SpeechPhrases.safety)

    /// Every walking alert and summary, for every object type, direction, and distance, can be played
    /// from pre-recorded pieces (so it never waits on the network).
    @Test func everyWalkingPhraseIsPrerecorded() throws {
        let labels = ObjectCatalog.entries.values.map { ($0.label, $0.category) }
            + [("Curb drop", .dropOff), ("Drop-off", .dropOff), ("Step up", .stairs), ("Obstacle", .obstacle),
               (TerrainAnalyzer.stairsUpLabel, .stairs), (TerrainAnalyzer.stairsDownLabel, .stairs),
               (SceneGrouping.cyclist, .vehicle), (SceneGrouping.people, .person)]
        let advice: [WalkNarrator.PathAdvice] = [.clear, .veerLeft, .veerRight, .blocked]
        var checked = 0
        for (label, category) in labels {
            for bearing in stride(from: -60.0, through: 60, by: 7) {
                for distance in stride(from: 0.3, through: 4, by: 0.35) {
                    for approaching in [false, true] {
                        var track = TrackedObstacle(id: UUID(), label: label, category: category,
                                                    boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
                                                    direction: RelativeDirection(bearingDegrees: bearing), lastSeen: .now)
                        track.forward = distance * cos(bearing * .pi / 180)
                        track.lateral = distance * sin(bearing * .pi / 180)
                        track.isApproaching = approaching
                        let alerts = [WalkNarrator.urgentAlert(for: track),
                                      WalkNarrator.summary(advice: advice[checked % 4], obstacles: [track])]
                        for alert in alerts {
                            for fragment in try #require(alert.fragments) {
                                #expect(recorded.contains(fragment), "Not pre-recorded: \"\(fragment)\"")
                            }
                        }
                        checked += 1
                    }
                }
            }
        }
        #expect(checked > 1000)
    }

    @Test func everyIndoorAlertIsPrerecorded() throws {
        let pose = FloorPose(position: .zero, forward: SIMD2(0, -1))
        let labels = ["Chair", "Table", "Stairs", "Couch", "Cabinet", "Person", "Wall"]
        for label in labels {
            for ahead in stride(from: 0.4, through: 1.5, by: 0.1) {
                let element: RoomElement = label == "Wall"
                    ? RoomElement(kind: .wall, label: "Wall", category: .wall, footprint: [SIMD2(-2, -ahead), SIMD2(2, -ahead)])
                    : RoomElement(kind: .object, label: label, category: label == "Stairs" ? .stairs : .furniture,
                                  footprint: [SIMD2(-0.2, -ahead), SIMD2(0.2, -ahead), SIMD2(0.2, -ahead - 0.4), SIMD2(-0.2, -ahead - 0.4)])
                guard let alert = IndoorComposer.compose([element], pose: pose).alert else { continue }
                let fragments = try #require(alert.fragments)
                for fragment in fragments {
                    #expect(recorded.contains(fragment), "Not pre-recorded: \"\(fragment)\"")
                }
                #expect(fragments.joined(separator: " ") == alert.spokenText)
            }
        }
    }

    @Test func phraseListStaysSmall() {
        // Recorded once per phone; keep it well inside a free ElevenLabs quota.
        #expect(SpeechPhrases.safety.joined().count < 5_000)
    }
}
