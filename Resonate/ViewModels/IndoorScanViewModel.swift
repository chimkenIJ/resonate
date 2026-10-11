import Foundation
import Observation

/// Getting around indoors: what's in the way, where the doors are, and guidance to a door.
/// Quiet unless something changed (see IndoorNavigator).
@Observable
final class IndoorScanViewModel {
    private(set) var snapshot: IndoorSnapshot?
    private(set) var scene: IndoorComposer.Result?
    /// A camera description (the room, or how to open a door); cleared a few seconds after it's read.
    private(set) var roomDescription: String?
    private(set) var isDescribing = false
    private(set) var cameraAvailable = true

    private let scanner: any IndoorScanServicing
    private let describer: any SceneDescriptionServicing
    private let feedback: FeedbackCenter
    private var navigator = IndoorNavigator()
    private var saidDarkTip = false

    init(services: AppServices, feedback: FeedbackCenter) {
        self.scanner = services.indoorScan
        self.describer = services.sceneDescription
        self.feedback = feedback
    }

    var isSupported: Bool { scanner.isSupported }
    var previewSource: CameraPreviewSource { scanner.previewSource }
    var unsupportedMessage: String { AppError.unsupportedDevice(feature: "Scanning indoors").spokenMessage }
    var isGuiding: Bool { navigator.isGuiding }

    var headline: String {
        if !cameraAvailable { return "Camera is off." }
        return navigator.guideHeadline ?? scene?.headline ?? "Sweep the phone slowly left and right."
    }
    var guidance: String { navigator.guideGuidance ?? scene?.guidance ?? "I'm finding walls, doors, and furniture." }
    var guidanceIcon: Maneuver { navigator.isGuiding ? navigator.guideIcon : (scene?.guidanceIcon ?? .straight) }
    var miniMap: [MiniMapItem] { scene?.miniMap ?? [] }
    var coaching: String? { snapshot?.coaching }

    /// Only what matters is outlined: doors, things in the path, people nearby, and the door being guided to.
    var overlayObjects: [DetectedObject] {
        guard let snapshot, let scene else { return [] }
        var shown = scene.relevant
        if let target = navigator.guideTarget { shown.insert(target) }
        return snapshot.objects.filter { shown.contains($0.id) }
    }

    func run() async {
        let generation = feedback.screenGeneration
        guard scanner.isSupported else {
            await feedback.announce(unsupportedMessage, priority: .info)
            return
        }
        let granted = await scanner.requestPermission()
        guard generation == feedback.screenGeneration, !Task.isCancelled else { return }
        guard granted else {
            cameraAvailable = false
            await feedback.announce(AppError.permissionDenied(.camera).spokenMessage, priority: .info)
            return
        }
        await feedback.announce("Indoors. Sweep the phone slowly left and right once, then hold it ahead. "
            + "I'll tell you about doors and anything in your way.", priority: .navigation)

        for await next in scanner.snapshots() {
            guard generation == feedback.screenGeneration, !Task.isCancelled else { return }
            snapshot = next
            let scene = IndoorComposer.compose(next.elements, pose: next.pose)
            self.scene = scene
            guard !isDescribing else { continue }

            // Scanning tips stay on screen; only "too dark" is worth saying, once.
            if let tip = next.coaching, tip.contains("dark"), !saidDarkTip {
                saidDarkTip = true
                await feedback.announce(tip, priority: .info)
            }

            for output in navigator.update(scene, canSpeak: !feedback.isSpeaking, now: .now) {
                await handle(output)
            }
        }
    }

    private func handle(_ output: IndoorNavigator.Output) async {
        switch output {
        case .urgent(let alert):
            await feedback.deliverUrgent(alert)
        case .say(let fragments):
            await feedback.say(fragments)
        case .aligned:
            feedback.proximityPulse()
        case .describeDoor, .lookForDoor:
            // The camera description says where a door is, or how to open the one in front.
            await describe(.door, intro: nil, failure: nil)
        }
    }

    // MARK: Actions

    /// Starts (or stops) guidance to the nearest door.
    func toggleFindDoor() async {
        if navigator.isGuiding {
            navigator.stopGuiding()
            feedback.stopSpeech()
            await feedback.say(["Stopped guiding."])
            return
        }
        guard let scene else {
            await feedback.say(["I'm still scanning.", "Sweep the phone slowly left and right."])
            return
        }
        feedback.stopSpeech()
        for output in navigator.startGuiding(scene, now: .now) {
            await handle(output)
        }
    }

    func repeatLast() async {
        if let roomDescription {
            await feedback.announce(roomDescription, priority: .snapshot)
        } else if navigator.isGuiding, let said = navigator.lastGuide {
            await feedback.say(said, priority: .info)
        } else if let scene {
            await feedback.say(scene.summary, priority: .info)
        } else {
            await feedback.repeatLast()
        }
    }

    func describeRoom() async {
        await describe(.indoor, intro: "Looking around the room.", failure: "I couldn't describe the room right now.")
    }

    private func describe(_ setting: SceneSetting, intro: String?, failure: String?) async {
        guard !isDescribing else { return }
        isDescribing = true
        defer { isDescribing = false }
        let generation = feedback.screenGeneration
        if let intro {
            feedback.stopSpeech()
            await feedback.announce(intro, priority: .info)
        } else {
            // Let the current sentence ("You're at the door…") finish first.
            for _ in 0..<30 where feedback.isSpeaking { try? await Task.sleep(for: .milliseconds(200)) }
        }
        do {
            guard let jpeg = await scanner.latestFrameJPEG() else { throw AppError.server(message: "The camera isn't ready yet.") }
            let text = try await describer.describe(jpeg: jpeg, setting: setting)
            // Left the screen while waiting: say nothing.
            guard generation == feedback.screenGeneration, !Task.isCancelled else { return }
            roomDescription = text
            await feedback.announce(text, priority: .snapshot)
            Task { await clearDescription(text) }
        } catch {
            guard generation == feedback.screenGeneration, !Task.isCancelled else { return }
            if let failure { await feedback.announce(failure, priority: .info) }
        }
    }

    /// Clears the description from the screen a few seconds after it's been read out.
    private func clearDescription(_ text: String) async {
        try? await Task.sleep(for: .milliseconds(500))
        for _ in 0..<600 where feedback.isSpeaking { try? await Task.sleep(for: .milliseconds(200)) }
        try? await Task.sleep(for: .seconds(4))
        if roomDescription == text { roomDescription = nil }
    }
}
