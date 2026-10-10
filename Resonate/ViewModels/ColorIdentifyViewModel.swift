import Foundation
import Observation

/// "Telling colors apart": names the color in the middle of the camera view.
@Observable
final class ColorIdentifyViewModel {
    private(set) var reading: ColorReading?
    private(set) var cameraAvailable = true

    private let recognizer: any ColorRecognitionServicing
    private let feedback: FeedbackCenter

    init(services: AppServices, feedback: FeedbackCenter) {
        self.recognizer = services.colorRecognition
        self.feedback = feedback
    }

    var previewSource: CameraPreviewSource { recognizer.previewSource }

    func run() async {
        let generation = feedback.screenGeneration
        let granted = await recognizer.requestPermission()
        guard generation == feedback.screenGeneration, !Task.isCancelled else { return }
        guard granted else {
            cameraAvailable = false
            await feedback.announce(AppError.permissionDenied(.camera).spokenMessage, priority: .info)
            return
        }
        await feedback.announce("Point the camera at something. I'll say its color.", priority: .info)
        for await next in recognizer.readings() {
            guard generation == feedback.screenGeneration, !Task.isCancelled else { return }
            let changed = next.name != reading?.name
            reading = next
            if changed { await feedback.announce(next.name, priority: .info) }
        }
    }

    func repeatLast() async {
        guard let reading else { return }
        await feedback.announce(reading.name, priority: .info)
    }
}
