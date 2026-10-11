import Foundation
import Observation

/// Getting around indoors: what's in front, left to right, and where the doors are. It never says
/// where to go.
/// Starts by mapping the room: the user stands and turns in a circle, and nothing about obstacles is
/// said, buzzed, or outlined until it's done. After that, updates, "Stop" alerts, and routes come from
/// the room map together with what the camera sees now (IndoorMap), measured from where the user is
/// going: the way they're walking, or where the phone faces when they stand still. Quiet unless
/// something changed (see IndoorNavigator).
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
    private var map = IndoorMap()
    private var saidDarkTip = false
    /// The first look around, before the map is good enough to guide with.
    private(set) var isMapping = true
    private var mappingStarted: Date?
    private var saidKeepTurning = false

    /// Mapping is done once the user has faced this much of a full circle…
    static let mappedCoverage = 0.8
    /// …or after this long, whatever has been mapped.
    static let mappingTimeout: TimeInterval = 30

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
        if isMapping { return "Mapping the room." }
        return scene?.headline ?? "Mapping the room."
    }
    /// What's in front, left to right.
    var guidance: String {
        if isMapping { return "Turn slowly in a full circle. \(Int(map.coverage * 100))% done." }
        return scene?.guidance ?? "I'm finding walls, doors, and furniture."
    }
    var guidanceIcon: Maneuver { isMapping ? .uTurn : .straight }
    var miniMap: [MiniMapItem] { scene?.miniMap ?? [] }
    var coaching: String? { snapshot?.coaching }

    /// Only what matters is outlined: doors, things in the path, people nearby, and the door being guided to.
    /// Nothing while mapping.
    var overlayObjects: [DetectedObject] {
        guard !isMapping, let snapshot, let scene else { return [] }
        return snapshot.objects.filter { scene.relevant.contains($0.id) }
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
        await feedback.announce("Indoors. Stand still, hold the phone up, and turn slowly in a full circle, so I can map the room.",
                                priority: .navigation)

        for await next in scanner.snapshots() {
            guard generation == feedback.screenGeneration, !Task.isCancelled else { return }
            let now = Date.now
            snapshot = next
            // The room map plus what the camera sees now (it feeds the map), from where the user is going.
            map.update(next.elements, live: next.live, pose: next.pose, now: now)
            let scene = IndoorComposer.compose(map.elements, pose: map.heading(next.pose))
            self.scene = scene
            guard !isDescribing else { continue }

            if isMapping {
                let elapsed = now.timeIntervalSince(mappingStarted ?? now)
                if mappingStarted == nil { mappingStarted = now }
                if map.coverage >= Self.mappedCoverage || elapsed >= Self.mappingTimeout {
                    isMapping = false
                    await feedback.say(["Room mapped."])
                } else if !saidKeepTurning, elapsed >= 12, map.coverage < 0.5 {
                    saidKeepTurning = true
                    await feedback.say(["Keep turning slowly."])
                }
            }

            // Scanning tips stay on screen; only "too dark" is worth saying, once.
            if let tip = next.coaching, tip.contains("dark"), !saidDarkTip {
                saidDarkTip = true
                await feedback.announce(tip, priority: .info)
            }

            // Nothing about obstacles until the map is ready.
            guard !isMapping else { continue }
            for output in navigator.update(scene, canSpeak: !feedback.isSpeaking, now: now) {
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
        case .describeDoor, .lookForDoor:
            // The camera description says where a door is, or how to open the one in front.
            await describe(.door, intro: nil, failure: nil)
        }
    }

    // MARK: Actions

    /// Where the doors are (ends mapping early if it's still going).
    func findDoor() async {
        guard let scene else {
            await feedback.say(["I'm still scanning.", "Turn slowly in a full circle."])
            return
        }
        isMapping = false
        feedback.stopSpeech()
        for output in IndoorNavigator.findDoor(scene) {
            await handle(output)
        }
    }

    func repeatLast() async {
        if isMapping {
            await feedback.say(["Keep turning slowly."])
        } else if let roomDescription {
            await feedback.announce(roomDescription, priority: .snapshot)
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
