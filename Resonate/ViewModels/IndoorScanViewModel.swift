import Foundation
import Observation

@Observable
final class IndoorScanViewModel {
    private(set) var snapshot: IndoorSnapshot?
    private(set) var roomDescription: String?
    private(set) var isDescribing = false

    private let scanner: any IndoorScanServicing
    private let describer: any SceneDescriptionServicing
    private let feedback: FeedbackCenter

    init(services: AppServices, feedback: FeedbackCenter) {
        self.scanner = services.indoorScan
        self.describer = services.sceneDescription
        self.feedback = feedback
    }

    var isSupported: Bool { scanner.isSupported }
    var unsupportedMessage: String { AppError.unsupportedDevice(feature: "Scanning indoors").spokenMessage }
    var headline: String { snapshot?.headline ?? "Move the phone slowly around the room." }
    var guidance: String { snapshot?.guidance ?? "I'm finding walls, doors, and furniture." }
    var guidanceIcon: Maneuver { snapshot?.guidanceIcon ?? .straight }

    func run() async {
        guard scanner.isSupported else {
            await feedback.announce(unsupportedMessage, priority: .info)
            return
        }
        await feedback.announce("Scanning the room.", priority: .navigation)
        for await next in scanner.snapshots() {
            let changed = next.headline != snapshot?.headline
            snapshot = next
            if changed {
                await feedback.announce("\(next.headline) \(next.guidance)", priority: .navigation)
            }
        }
    }

    func repeatLast() async {
        await feedback.repeatLast()
    }

    func describeRoom() async {
        guard !isDescribing else { return }
        isDescribing = true
        defer { isDescribing = false }
        await feedback.announce("Looking around the room.", priority: .info)
        do {
            guard let jpeg = await scanner.latestFrameJPEG() else { throw AppError.server(message: "The camera isn't ready yet.") }
            let text = try await describer.describe(jpeg: jpeg, setting: .indoor)
            roomDescription = text
            await feedback.announce(text, priority: .info)
        } catch {
            await feedback.announce("I couldn't describe the room right now.", priority: .info)
        }
    }
}
