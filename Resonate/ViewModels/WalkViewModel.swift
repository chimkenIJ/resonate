import Foundation
import Observation

/// Outdoor walking: obstacle alerts always, plus spoken turn-by-turn when following a route.
@Observable
final class WalkViewModel {
    enum Mode {
        case freeWalk
        case navigating(Route)
    }

    let mode: Mode
    private(set) var objects: [DetectedObject] = []
    private(set) var alert: ObstacleAlert?
    private(set) var stepIndex = 0
    private(set) var hasArrived = false
    private(set) var sceneDescription: String?
    private(set) var isDescribing = false

    private let detection: any ObstacleDetectionServicing
    private let location: any LocationServicing
    private let describer: any SceneDescriptionServicing
    private let feedback: FeedbackCenter

    /// How close (meters) the user must be to the next step's start before it is announced.
    private let stepTriggerDistance = 12.0

    init(mode: Mode, services: AppServices, feedback: FeedbackCenter) {
        self.mode = mode
        self.detection = services.obstacleDetection
        self.location = services.location
        self.describer = services.sceneDescription
        self.feedback = feedback
    }

    // MARK: Display

    var route: Route? {
        if case .navigating(let route) = mode { return route }
        return nil
    }

    var isNavigating: Bool { route != nil }
    var backLabel: String { isNavigating ? "Back to route" : "Back to home" }
    var tagText: String { alert?.severity.label ?? "All clear" }
    var tagAccent: Accent { alert?.severity.accent ?? .sage }
    var deliveryText: String { feedback.preferences.deliveryDescription(for: alert?.severity ?? .headsUp) }

    var headline: String {
        if let alert { return alert.headline }
        return hasArrived ? "You've arrived." : "Path looks clear ahead."
    }

    private var currentStep: RouteStep? {
        guard let route, route.steps.indices.contains(stepIndex) else { return nil }
        return route.steps[stepIndex]
    }

    var guidance: String {
        if let alert { return alert.guidance }
        if let step = currentStep, !hasArrived {
            return step.distanceMeters > 0
                ? "\(step.instruction). \(DistanceText.short(step.distanceMeters))."
                : step.instruction
        }
        return "Keep walking. I'll warn you about obstacles."
    }

    var guidanceIcon: Maneuver {
        alert?.guidanceIcon ?? currentStep?.maneuver ?? .straight
    }

    // MARK: Running

    func run() async {
        if let route {
            await feedback.announce("Walking to \(route.destination.name). \(route.spokenSummary).", priority: .navigation)
        } else {
            await feedback.announce("Watching ahead. I'll warn you about obstacles.", priority: .navigation)
        }
        async let obstacles: Void = watchObstacles()
        async let directions: Void = followRoute()
        _ = await (obstacles, directions)
    }

    private func watchObstacles() async {
        for await frame in detection.frames() {
            objects = frame.objects
            if let next = ObstacleAlertComposer.compose(from: frame.objects) {
                alert = next
                await feedback.deliver(next)
            } else {
                alert = nil
            }
        }
    }

    private func followRoute() async {
        guard let route, let first = route.steps.first else { return }
        await feedback.announce(spoken(first), priority: .navigation)

        for await point in location.updates() {
            let next = stepIndex + 1
            guard route.steps.indices.contains(next) else { break }
            guard point.distance(to: route.steps[next].start) < stepTriggerDistance else { continue }

            stepIndex = next
            let step = route.steps[next]
            if step.maneuver == .arrive {
                hasArrived = true
                await feedback.announce("You've arrived at \(route.destination.name).", priority: .navigation, haptic: .arrived)
                break
            }
            await feedback.announce(spoken(step), priority: .navigation, haptic: haptic(for: step.maneuver))
        }
    }

    private func spoken(_ step: RouteStep) -> String {
        step.distanceMeters > 0 ? "\(step.instruction), \(DistanceText.spoken(step.distanceMeters))." : "\(step.instruction)."
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
        await feedback.announce("Looking around.", priority: .info)
        do {
            guard let jpeg = await detection.latestFrameJPEG() else { throw AppError.server(message: "The camera isn't ready yet.") }
            let text = try await describer.describe(jpeg: jpeg, setting: .outdoor)
            sceneDescription = text
            await feedback.announce(text, priority: .info)
        } catch {
            await feedback.announce("I couldn't describe the scene right now.", priority: .info)
        }
    }
}
