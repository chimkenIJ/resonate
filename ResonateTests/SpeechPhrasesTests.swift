import CoreGraphics
import Foundation
import Testing
@testable import Resonate

struct SpeechPhrasesTests {
    private let recorded = Set(SpeechPhrases.safety)

    /// Every outdoor alert, for every object type, direction, and distance, can be played from
    /// pre-recorded pieces (so it never waits on the network), and the pieces say the same thing.
    @Test func everyOutdoorAlertIsPrerecorded() throws {
        let labels = ObjectCatalog.entries.values.map { ($0.label, $0.category) }
            + [("Curb drop", .dropOff), ("Drop-off", .dropOff), ("Step up", .stairs), ("Obstacle", .obstacle)]
        var checked = 0
        for (label, category) in labels {
            for x in stride(from: 0.05, through: 0.95, by: 0.1) {
                for distance in stride(from: 0.3, through: 6, by: 0.35) {
                    let object = DetectedObject(label: label, category: category, confidence: 1,
                                                boundingBox: CGRect(x: x - 0.02, y: 0.4, width: 0.04, height: 0.2),
                                                distanceMeters: distance)
                    let alert = try #require(ObstacleAlertComposer.compose(from: [object]))
                    let fragments = try #require(alert.fragments)
                    for fragment in fragments {
                        #expect(recorded.contains(fragment), "Not pre-recorded: \"\(fragment)\"")
                    }
                    #expect(fragments.joined(separator: " ") == alert.spokenText)
                    checked += 1
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
