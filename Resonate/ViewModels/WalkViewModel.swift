import Foundation
import Observation

/// Outdoor walking: obstacle alerts always, plus spoken turn-by-turn when following a route.
/// Turn-by-turn reroutes on its own when the user drifts off the route.
@Observable
final class WalkViewModel {
    enum Mode {
        case freeWalk
        case navigating(Route)
    }

    private(set) var objects: [DetectedObject] = []
    private(set) var currentLocation: GeoPoint?
    private(set) var imageSize: CGSize?
    private(set) var cameraAvailable = true
    private(set) var alert: ObstacleAlert?
    private(set) var navigation: NavigationEngine?
    private(set) var isRerouting = false
    private(set) var sceneDescription: String?
    private(set) var isDescribing = false

    private let detection: any ObstacleDetectionServicing
    private let location: any LocationServicing
    private let routing: any RoutingServicing
    private let describer: any SceneDescriptionServicing
    private let feedback: FeedbackCenter
    private let routingPreferences: RoutingPreferences
    private var lastRerouteAt: Date = .distantPast

    /// Don't ask for a new route more often than this.
    private let rerouteInterval: TimeInterval = 20

    init(mode: Mode, services: AppServices, feedback: FeedbackCenter, routingPreferences: RoutingPreferences = RoutingPreferences()) {
        if case .navigating(let route) = mode {
            navigation = NavigationEngine(route: route)
        }
        self.detection = services.obstacleDetection
        self.location = services.location
        self.routing = services.routing
        self.describer = services.sceneDescription
        self.feedback = feedback
        self.routingPreferences = routingPreferences
    }

    // MARK: Display

    var previewSource: CameraPreviewSource { detection.previewSource }
    var route: Route? { navigation?.route }
    var isNavigating: Bool { navigation != nil }
    var hasArrived: Bool { navigation?.hasArrived ?? false }
    var backLabel: String { isNavigating ? "Back to route" : "Back to home" }
    var tagText: String { alert?.severity.label ?? (isRerouting ? "Rerouting" : "All clear") }
    var tagAccent: Accent { alert?.severity.accent ?? (isRerouting ? .sand : .sage) }
    var deliveryText: String { feedback.preferences.deliveryDescription(for: alert?.severity ?? .headsUp) }

    var headline: String {
        if let alert { return alert.headline }
        if hasArrived { return "You've arrived." }
        if !cameraAvailable { return "Camera is off. No obstacle alerts." }
        if isRerouting { return "Finding a new route." }
        return "Path looks clear ahead."
    }

    var guidance: String {
        if let alert { return alert.guidance }
        if let step = navigation?.currentStep, !hasArrived {
            return step.distanceMeters > 0
                ? "\(step.instruction). \(DistanceText.short(step.distanceMeters))."
                : step.instruction
        }
        return "Keep walking. I'll warn you about obstacles."
    }

    var guidanceIcon: Maneuver {
        alert?.guidanceIcon ?? navigation?.currentStep?.maneuver ?? .straight
    }

    // MARK: Running

    func run() async {
        let generation = feedback.screenGeneration
        if let route {
            await feedback.announce("Walking to \(route.destination.name). \(route.spokenSummary).", priority: .navigation)
        } else {
            await feedback.announce("Watching ahead. I'll warn you about obstacles.", priority: .navigation)
        }
        async let obstacles: Void = watchObstacles(generation: generation)
        async let directions: Void = followRoute(generation: generation)
        _ = await (obstacles, directions)
    }

    private func watchObstacles(generation: Int) async {
        let granted = await detection.requestPermission()
        guard generation == feedback.screenGeneration, !Task.isCancelled else { return }
        guard granted else {
            cameraAvailable = false
            await feedback.announce(AppError.permissionDenied(.camera).spokenMessage + " Directions still work.", priority: .navigation)
            return
        }
        for await frame in detection.frames() {
            guard generation == feedback.screenGeneration, !Task.isCancelled else { return }
            objects = frame.objects
            imageSize = frame.imageSize
            if let next = ObstacleAlertComposer.compose(from: frame.objects) {
                alert = next
                await feedback.deliver(next)
            } else {
                alert = nil
            }
        }
    }

    private func followRoute(generation: Int) async {
        guard generation == feedback.screenGeneration, !Task.isCancelled else { return }
        guard let first = navigation?.route.steps.first else { return }
        await feedback.announce(first.spoken, priority: .navigation)

        for await fix in location.updates() {
            guard generation == feedback.screenGeneration, !Task.isCancelled else { return }
            guard var engine = navigation, !engine.hasArrived else { break }
            currentLocation = fix.point
            let events = engine.update(fix)
            navigation = engine
            for event in events {
                guard generation == feedback.screenGeneration, !Task.isCancelled else { return }
                await handle(event, engine: engine, at: fix)
            }
        }
    }

    private func handle(_ event: NavigationEngine.Event, engine: NavigationEngine, at fix: LocationFix) async {
        let text = engine.announcement(for: event)
        switch event {
        case .offRoute:
            await feedback.announce(text, priority: .navigation, haptic: .headsUp)
            await reroute(from: fix.point)
        case .reached(let index):
            await feedback.announce(text, priority: .navigation, haptic: haptic(for: engine.route.steps[index].maneuver))
        case .arrived:
            await feedback.announce(text, priority: .navigation, haptic: .arrived)
        case .hazardAhead:
            await feedback.announce(text, priority: .safety, haptic: .headsUp)
        case .approaching, .backOnRoute:
            await feedback.announce(text, priority: .navigation)
        }
    }

    private func reroute(from point: GeoPoint) async {
        let generation = feedback.screenGeneration
        guard let destination = route?.destination, !isRerouting,
              Date.now.timeIntervalSince(lastRerouteAt) >= rerouteInterval else { return }
        isRerouting = true
        lastRerouteAt = .now
        defer { isRerouting = false }
        do {
            let fresh = try await routing.route(from: point, to: destination, preferences: routingPreferences)
            guard generation == feedback.screenGeneration, !Task.isCancelled else { return }
            navigation = NavigationEngine(route: fresh)
            let first = fresh.steps.first.map { " \($0.spoken)" } ?? ""
            await feedback.announce("New route.\(first)", priority: .navigation)
        } catch {
            guard generation == feedback.screenGeneration, !Task.isCancelled else { return }
            let message = (error as? AppError)?.spokenMessage ?? "I couldn't find a new route. Keep to a safe spot and try again."
            await feedback.announce(message, priority: .navigation)
        }
    }

    private func haptic(for maneuver: Maneuver) -> HapticCue {
        switch maneuver {
        case .left, .slightLeft, .sharpLeft: .turnLeft
        case .right, .slightRight, .sharpRight: .turnRight
        default: .tap
        }
    }

    // MARK: Actions

    func repeatLast() async {
        await feedback.repeatLast()
    }

    func describeScene() async {
        guard !isDescribing else { return }
        isDescribing = true
        defer { isDescribing = false }
        feedback.stopSpeech()
        let generation = feedback.screenGeneration
        await feedback.announce("Looking around.", priority: .info)
        do {
            guard let jpeg = await detection.latestFrameJPEG() else { throw AppError.server(message: "The camera isn't ready yet.") }
            let text = try await describer.describe(jpeg: jpeg, setting: .outdoor)
            guard generation == feedback.screenGeneration, !Task.isCancelled else { return }
            sceneDescription = text
            await feedback.announce(text, priority: .snapshot)
        } catch {
            guard generation == feedback.screenGeneration, !Task.isCancelled else { return }
            await feedback.announce("I couldn't describe the scene right now.", priority: .info)
        }
    }
}
