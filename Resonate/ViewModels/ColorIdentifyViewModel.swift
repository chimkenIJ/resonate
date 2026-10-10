import Foundation
import Observation

/// "Telling colors apart": names the color in the middle of the camera view.
@Observable
final class ColorIdentifyViewModel {
    private(set) var reading: ColorReading?

    private let recognizer: any ColorRecognitionServicing
    private let feedback: FeedbackCenter

    init(services: AppServices, feedback: FeedbackCenter) {
        self.recognizer = services.colorRecognition
        self.feedback = feedback
    }

    func run() async {
        await feedback.announce("Point the camera at something. I'll say its color.", priority: .info)
        for await next in recognizer.readings() {
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
