import Foundation

/// Repeats a fixed list of items every `interval` until the consumer stops listening.
private func cycling<Element: Sendable>(_ items: [Element], every interval: Duration) -> AsyncStream<Element> {
    AsyncStream { continuation in
        let task = Task {
            var index = 0
            while !Task.isCancelled, !items.isEmpty {
                continuation.yield(items[index % items.count])
                index += 1
                try? await Task.sleep(for: interval)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

final class MockObstacleDetectionService: ObstacleDetectionServicing {
    let depthSource: DepthSource = .lidar

    func frames() -> AsyncStream<DetectionFrame> {
        cycling(SampleData.outdoorFrames, every: .seconds(3))
    }

    func latestFrameJPEG() async -> Data? { Data() }
}

final class MockIndoorScanService: IndoorScanServicing {
    let isSupported = true

    func snapshots() -> AsyncStream<IndoorSnapshot> {
        cycling(SampleData.indoorSnapshots, every: .seconds(3))
    }

    func latestFrameJPEG() async -> Data? { Data() }
}

final class MockSceneDescriptionService: SceneDescriptionServicing {
    func describe(jpeg: Data, setting: SceneSetting) async throws -> String {
        try await Task.sleep(for: .seconds(1))
        switch setting {
        case .indoor:
            return "A classroom about 8 meters long. Rows of desks fill the middle. The door is straight ahead, and there's a whiteboard on the right wall."
        case .outdoor:
            return "A wide sidewalk with trees on the left. A bike is parked about 2 meters ahead. There's a crosswalk with a signal at the corner."
        }
    }
}

final class MockColorRecognitionService: ColorRecognitionServicing {
    func readings() -> AsyncStream<ColorReading> {
        cycling([
            ColorReading(name: "Navy blue", family: "Blue", hex: "#1F2A4D"),
            ColorReading(name: "Forest green", family: "Green", hex: "#2E5E3A"),
            ColorReading(name: "Brick red", family: "Red", hex: "#9A3B2E"),
        ], every: .seconds(2))
    }
}
