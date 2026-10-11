import Foundation
import Observation

/// "Scan the area": turns on the camera, asks the user to hold the phone in front of them, and
/// describes what's around them. No obstacle detection runs on this screen.
@Observable
final class ScanAreaViewModel {
    private(set) var sceneDescription: String?
    private(set) var isStarting = true
    private(set) var isDescribing = false
    private(set) var cameraAvailable = true

    private let camera: any ObstacleDetectionServicing
    private let describer: any SceneDescriptionServicing
    private let feedback: FeedbackCenter

    /// Time for the camera to settle on what's in front before taking the picture.
    private let settleTime: Duration = .seconds(1.5)

    init(services: AppServices, feedback: FeedbackCenter) {
        self.camera = services.obstacleDetection
        self.describer = services.sceneDescription
        self.feedback = feedback
    }

    var previewSource: CameraPreviewSource { camera.previewSource }

    var headline: String {
        if !cameraAvailable { return "Camera is off." }
        if isStarting { return "Scanning the area." }
        if isDescribing { return "Looking around…" }
        return sceneDescription == nil ? "Ready to scan." : "Around you"
    }

    var guidance: String {
        if !cameraAvailable { return AppError.permissionDenied(.camera).spokenMessage }
        if isStarting || isDescribing { return "Hold the phone in front of you." }
        return "Point the phone somewhere else and tap Scan again."
    }

    /// Keeps the camera on for as long as the screen is open, and describes the area once.
    func run() async {
        let generation = feedback.screenGeneration
        guard await camera.requestPermission() else {
            cameraAvailable = false
            isStarting = false
            await feedback.announce(AppError.permissionDenied(.camera).spokenMessage, priority: .info)
            return
        }
        guard generation == feedback.screenGeneration, !Task.isCancelled else { return }
        // Camera only: no object detection, just pictures for the description.
        let frames = camera.frames(detecting: false)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for await _ in frames {} }
            group.addTask { await self.start(generation: generation) }
            await group.waitForAll() // the camera stream ends when the screen closes
        }
    }

    private func start(generation: Int) async {
        await feedback.announce("Scanning the area. Hold the phone in front of you.", priority: .info)
        await feedback.waitForSpeech()
        try? await Task.sleep(for: settleTime)
        guard generation == feedback.screenGeneration, !Task.isCancelled else { return }
        isStarting = false
        await describe()
    }

    /// Takes a picture and reads out what's in it.
    func describe() async {
        guard cameraAvailable, !isDescribing else { return }
        isDescribing = true
        defer { isDescribing = false }
        feedback.stopSpeech()
        let generation = feedback.screenGeneration
        do {
            guard let jpeg = await camera.latestFrameJPEG() else {
                throw AppError.server(message: "The camera isn't ready yet. Tap Scan again in a moment.")
            }
            let text = try await describer.describe(jpeg: jpeg, setting: .outdoor)
            // Left the screen while waiting: say nothing.
            guard generation == feedback.screenGeneration, !Task.isCancelled else { return }
            sceneDescription = text
            await feedback.announce(text, priority: .snapshot)
        } catch {
            guard generation == feedback.screenGeneration, !Task.isCancelled else { return }
            let message = (error as? AppError)?.spokenMessage ?? "I couldn't describe the area right now. Tap Scan again."
            await feedback.announce(message, priority: .info)
        }
    }

    func repeatLast() async {
        await feedback.repeatLast()
    }
}
