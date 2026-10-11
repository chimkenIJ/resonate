import Foundation

/// Every piece a safety alert can be built from. The voice service records these once in the app's
/// ElevenLabs voice and keeps them on the phone, so alerts never wait on the network and still work
/// offline. Keep this in sync with WalkNarrator and IndoorComposer (a test checks it).
nonisolated enum SpeechPhrases {
    static var safety: [String] {
        var phrases = Set<String>()

        // Things.
        phrases.formUnion(ObjectCatalog.entries.values.map(\.label))
        phrases.formUnion(["Curb drop", "Drop-off", "Step up", "Obstacle", TerrainAnalyzer.stairsUpLabel, TerrainAnalyzer.stairsDownLabel])
        phrases.formUnion(SceneGrouping.labels)
        phrases.formUnion(["Wall", "Door", "Doorway", "Chair", "Table", "Couch", "Bed", "Cabinet", "Fridge", "Stove",
                           "Oven", "Sink", "Dishwasher", "Washer", "Toilet", "Bathtub", "Fireplace", "TV", "Stairs", "Object", "Person", "People", "Animal", "Bag"])

        // Where.
        let directions: [RelativeDirection] = [.left, .slightlyLeft, .ahead, .slightlyRight, .right]
        phrases.formUnion(directions.map { "\($0.spoken)," })
        phrases.insert("right in front of you.")
        // Indoors: "Door" "5 steps" "ahead, on your left." and how to turn.
        phrases.formUnion((1...IndoorComposer.maxSteps).map { IndoorComposer.steps(Double($0) * IndoorComposer.stepLength) })
        phrases.formUnion(stride(from: -180.0, through: 180, by: 5).map { "\(IndoorComposer.phrase(for: $0))." })
        phrases.formUnion(stride(from: -180.0, through: 180, by: 5).map { IndoorComposer.turn(toward: $0).text })
        phrases.formUnion(["Clear ahead.", "It's closed.", "It's open.", "You're at the door.", "You're at the doorway.",
                           "Walk straight through.", "Found a door.", "I haven't found a door yet.", "I lost the door.",
                           "Turn slowly, and I'll tell you when I see one.", "Stopped guiding.", "Find the railing."])

        // How far (alerts and summaries only mention things within about 20 feet).
        phrases.formUnion(stride(from: 0.1, through: 6.5, by: 0.02).map { "\(DistanceText.spoken($0))." })

        // Walking: urgent alerts ("Stop. Car approaching from the right.") and summaries ("Path clear.").
        phrases.insert("Stop.")
        phrases.formUnion(directions.map { "\($0.spoken)." })
        phrases.formUnion(["approaching from the left.", "approaching from the right.", "coming toward you."])
        phrases.formUnion([WalkNarrator.PathAdvice.clear, .veerLeft, .veerRight, .blocked].map(\.rawValue))
        phrases.formUnion(["Wait for it to pass.", "Watch the edge.", "Watch the step.",
                           "Find the railing."])

        // Pedestrian signals.
        phrases.formUnion([SignalReading.walk.spoken, SignalReading.dontWalk.spoken])

        // What to do (indoors).
        phrases.formUnion([
            "Step right to pass.", "Step left to pass.",
            "Turn left or right.", IndoorComposer.closedDoorGuidance,
        ])

        // Navigation phrases that should also work offline.
        phrases.formUnion([
            "You're off the route. Finding a new one.", "You're back on the route.",
            "Turn around. You're walking away from the route.", "That's the right way.",
            "You're on the stairs, going up. Hold the railing.", "You're on the stairs, going down. Hold the railing.",
            "Raised curb ahead. Watch the edge.", "Steps ahead.",
            "Watching ahead. I'll warn you about obstacles.",
        ])
        return phrases.sorted()
    }
}
