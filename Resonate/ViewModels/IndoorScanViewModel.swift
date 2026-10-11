import Foundation
import Observation

/// Getting around indoors: what's in front, left to right, and where the doors are. It never says
/// where to go.
/// Starts by mapping the room: the user stands and turns in a circle, and nothing about obstacles is
/// said, buzzed, or outlined until it's done. After that, updates, "Stop" alerts, and routes come from
/// the room map together with what the camera sees now (IndoorMap), measured from where the user is
/// going: the way they're walking, or where the phone faces when they stand still. Quiet unless
/// something changed (see IndoorNavigator).
///
/// The card shows exactly what was last said, nothing else: every line goes through `speak`.
@Observable
final class IndoorScanViewModel {
    private(set) var snapshot: IndoorSnapshot?
    private(set) var scene: IndoorComposer.Result?
    /// What was last said, word for word: the card's text.
    private(set) var shownText = ""
    /// The last camera description (the room, or how to open a door).
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
    /// The card's text: exactly what was last said.
    var headline: String { shownText }
    var miniMap: [MiniMapItem] { scene?.miniMap ?? [] }

    /// Only what matters is outlined: doors, things in the path, people nearby, and the door being guided to.
    /// Nothing while mapping.
    var overlayObjects: [DetectedObject] {
        guard !isMapping, let snapshot, let scene else { return [] }
        return snapshot.objects.filter { scene.relevant.contains($0.id) }
    }

    func run() async {
        let generation = feedback.screenGeneration
        guard scanner.isSupported else {
            await speak(unsupportedMessage, priority: .info)
            return
        }
        let granted = await scanner.requestPermission()
        guard generation == feedback.screenGeneration, !Task.isCancelled else { return }
        guard granted else {
            cameraAvailable = false
            await speak(AppError.permissionDenied(.camera).spokenMessage, priority: .info)
            return
        }
        await speak("Indoors. Stand still, hold the phone up, and turn slowly in a full circle, so I can map the room.")

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
                    await speak("Room mapped.")
                } else if !saidKeepTurning, elapsed >= 12, map.coverage < 0.5 {
                    saidKeepTurning = true
                    await speak("Keep turning slowly.")
                }
            }

            // Of the scanning tips, only "too dark" is worth saying, once.
            if let tip = next.coaching, tip.contains("dark"), !saidDarkTip {
                saidDarkTip = true
                await speak(tip, priority: .info)
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
            shownText = alert.spokenText
            await feedback.deliverUrgent(alert)
        case .say(let pieces):
            await speak(pieces.joined(separator: " "))
        case .describeDoor, .lookForDoor:
            // The camera description says where a door is, or how to open the one in front.
            await describe(.door, intro: nil, failure: nil)
        }
    }

    // MARK: Actions

    /// Where the doors are (ends mapping early if it's still going).
    func findDoor() async {
        guard let scene else {
            await speak("I'm still scanning. Turn slowly in a full circle.")
            return
        }
        isMapping = false
        feedback.stopSpeech()
        for output in IndoorNavigator.findDoor(scene) {
            await handle(output)
        }
    }

    /// Says the card's text again.
    func repeatLast() async {
        guard !shownText.isEmpty else { return }
        await speak(shownText, priority: .info)
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
            await speak(intro, priority: .info)
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
            await speak(text, priority: .snapshot)
        } catch {
            guard generation == feedback.screenGeneration, !Task.isCancelled else { return }
            if let failure { await speak(failure, priority: .info) }
        }
    }

    /// Says `text` as whole sentences (pieces recorded separately could drop a word, like the number
    /// in "4 steps") and shows exactly that on the card. Whatever was playing stops first, so the card
    /// and the voice change at the same moment. (Automatic updates only come when nothing is playing.)
    private func speak(_ text: String, priority: SpeechPriority = .navigation) async {
        feedback.stopSpeech()
        shownText = text
        await feedback.announce(text, priority: priority)
    }
}
