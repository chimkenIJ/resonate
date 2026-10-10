import Foundation

/// Every piece a safety alert can be built from. The voice service records these once in the app's
/// ElevenLabs voice and keeps them on the phone, so alerts never wait on the network and still work
/// offline. Keep this in sync with ObstacleAlertComposer and IndoorComposer (a test checks it).
nonisolated enum SpeechPhrases {
    static var safety: [String] {
        var phrases = Set<String>()

        // Things.
        phrases.formUnion(ObjectCatalog.entries.values.map(\.label))
        phrases.formUnion(["Curb drop", "Drop-off", "Step up", "Obstacle"])
        phrases.formUnion(["Wall", "Door", "Doorway", "Chair", "Table", "Couch", "Bed", "Cabinet", "Fridge", "Stove",
                           "Oven", "Sink", "Dishwasher", "Washer", "Toilet", "Bathtub", "Fireplace", "TV", "Stairs", "Object"])

        // Where.
        let directions: [RelativeDirection] = [.left, .slightlyLeft, .ahead, .slightlyRight, .right]
        phrases.formUnion(directions.map { "\($0.spoken)," })
        phrases.insert("right in front of you.")
        phrases.formUnion((1...3).map { "\(IndoorComposer.steps(Double($0) * IndoorComposer.stepLength)) ahead." })

        // How far (alerts only fire within 6 m).
        phrases.formUnion((1...6).map { "\(DistanceText.spoken(Double($0)))." })

        // What to do.
        phrases.formUnion([
            "Stop. Check the edge with your cane.", "Slow down. Edge ahead.",
            "Stop. Step up right in front of you.", "Slow down. Step up ahead.",
            "Step right to pass.", "Step left to pass.",
            "Stop. It's right in front of you.", "Blocked ahead. Step left or right.",
            "Turn left or right.", "Stairs. Find the railing and check each step with your cane.",
        ])

        // Navigation phrases that should also work offline.
        phrases.formUnion([
            "You're off the route. Finding a new one.", "You're back on the route.",
            "Raised curb ahead. Check the edge with your cane.", "Steps ahead.",
            "Watching ahead. I'll warn you about obstacles.",
        ])
        return phrases.sorted()
    }
}
