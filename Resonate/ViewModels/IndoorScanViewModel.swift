import Foundation
import Observation

@Observable
final class IndoorScanViewModel {
    private(set) var snapshot: IndoorSnapshot?
    private(set) var roomDescription: String?
    private(set) var isDescribing = false
    private(set) var cameraAvailable = true

    private let scanner: any IndoorScanServicing
    private let describer: any SceneDescriptionServicing
    private let feedback: FeedbackCenter

    private var lastKey = ""
    private var lastAnnouncedAt = Date.distantPast
    private var lastCoaching: String?
    private var lastCoachingAt = Date.distantPast

    /// Re-announce the same situation at most this often.
    private let repeatInterval: TimeInterval = 12
    private let coachingInterval: TimeInterval = 8

    init(services: AppServices, feedback: FeedbackCenter) {
        self.scanner = services.indoorScan
        self.describer = services.sceneDescription
        self.feedback = feedback
    }

    var isSupported: Bool { scanner.isSupported }
    var previewSource: CameraPreviewSource { scanner.previewSource }
    var unsupportedMessage: String { AppError.unsupportedDevice(feature: "Scanning indoors").spokenMessage }
    var headline: String {
        if !cameraAvailable { return "Camera is off." }
        return snapshot?.headline ?? "Move the phone slowly around the room."
    }
    var guidance: String { snapshot?.guidance ?? "I'm finding walls, doors, and furniture." }
    var guidanceIcon: Maneuver { snapshot?.guidanceIcon ?? .straight }
    var coaching: String? { snapshot?.coaching }

    func run() async {
        guard scanner.isSupported else {
            await feedback.announce(unsupportedMessage, priority: .info)
            return
        }
        guard await scanner.requestPermission() else {
            cameraAvailable = false
            await feedback.announce(AppError.permissionDenied(.camera).spokenMessage, priority: .info)
            return
        }
        await feedback.announce("Scanning the room. Move the phone slowly from side to side.", priority: .navigation)

        for await next in scanner.snapshots() {
            snapshot = next
            let now = Date.now

            if let alert = next.alert {
                // Something very close in the path: the safety channel, with its own repeat control.
                await feedback.deliver(alert)
            } else if next.announcementKey != lastKey || now.timeIntervalSince(lastAnnouncedAt) >= repeatInterval {
                lastKey = next.announcementKey
                lastAnnouncedAt = now
                await feedback.announce("\(next.headline) \(next.guidance)", priority: .navigation)
            }

            if let tip = next.coaching, tip != lastCoaching || now.timeIntervalSince(lastCoachingAt) >= coachingInterval {
                lastCoachingAt = now
                await feedback.announce(tip, priority: .info)
            }
            lastCoaching = next.coaching
        }
    }

    func repeatLast() async {
        guard let snapshot else { return await feedback.repeatLast() }
        await feedback.announce("\(snapshot.headline) \(snapshot.guidance)", priority: .info)
    }

    func describeRoom() async {
        guard !isDescribing else { return }
        isDescribing = true
        defer { isDescribing = false }
        await feedback.announceOnce(key: "gemini", "Describing sends one photo to Google Gemini to put it into words. Resonate doesn't save it.")
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
