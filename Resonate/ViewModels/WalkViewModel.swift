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
    /// A "stop" alert, shown for a few seconds.
    private(set) var alert: ObstacleAlert?
    /// The latest "what's ahead" summary, refreshed every few seconds.
    private(set) var summary: ObstacleAlert?
    /// Walk or don't walk, while a pedestrian signal is in view and the user is about to cross.
    var signal: SignalReading? { signalMatters ? signalTracker.state : nil }

    /// Following a route: only at a crossing the route uses. Walking freely: only while standing still,
    /// the way people wait at a curb (LiDAR phones; otherwise always).
    private var signalMatters: Bool {
        if let navigation { return navigation.isNearCrossing }
        return isStandingStill ?? true
    }

    /// Recent positions from the camera, to tell when the user has stopped.
    private var recentPoses: [(time: Date, position: SIMD3<Double>)] = []
    /// "up" or "down" while the user is on stairs (LiDAR phones), from the last 2 seconds of movement.
    private var climbingDirection: String? {
        // Only right after stairs were seen: otherwise lifting the phone while walking looks like climbing.
        guard Date.now.timeIntervalSince(narrator.lastStairsSeen) < 15,
              let first = recentPoses.first, let last = recentPoses.last,
              last.time.timeIntervalSince(first.time) >= 1.6 else { return nil }
        let middle = recentPoses[recentPoses.count / 2]
        let rise = last.position.y - first.position.y
        let moved = last.position - first.position
        let horizontal = (moved.x * moved.x + moved.z * moved.z).squareRoot()
        // Steps rise about 17 cm for every 28 cm forward, steadily: a ramp or hill is far gentler, an
        // elevator rises without moving forward, and lifting the phone rises all at once.
        let firstHalf = middle.position.y - first.position.y, secondHalf = last.position.y - middle.position.y
        let steady = firstHalf * rise > 0 && secondHalf * rise > 0
            && min(abs(firstHalf), abs(secondHalf)) >= abs(rise) * 0.25
        guard abs(rise) >= 0.35, horizontal >= 0.5, (TerrainAnalyzer.stairsMinGrade...1.2).contains(abs(rise) / horizontal),
              steady else { return nil }
        return rise > 0 ? "up" : "down"
    }

    private var isStandingStill: Bool? {
        guard let first = recentPoses.first, let last = recentPoses.last,
              last.time.timeIntervalSince(first.time) >= 1.5 else { return recentPoses.isEmpty ? nil : false }
        let maxMove = recentPoses.map { $0.position - first.position }.map { ($0.x * $0.x + $0.z * $0.z).squareRoot() }.max() ?? 0
        return maxMove < 0.4
    }
    private(set) var navigation: NavigationEngine?
    private(set) var isRerouting = false
    private(set) var sceneDescription: String?
    private(set) var isDescribing = false
    private(set) var isStarting = true

    private let detection: any ObstacleDetectionServicing
    private let location: any LocationServicing
    private let routing: any RoutingServicing
    private let describer: any SceneDescriptionServicing
    private let feedback: FeedbackCenter
    private let routingPreferences: RoutingPreferences
    private var lastRerouteAt: Date = .distantPast
    private var tracker = ObstacleTracker()
    private var narrator = WalkNarrator()
    private var signalTracker = WalkSignalTracker()
    /// Whether the current signal state has been said since it started to matter.
    private var signalAnnounced = false
    /// "You're on the stairs" is said once per flight.
    private var saidOnStairs = false
    private var alertShownAt: Date = .distantPast
    /// What the last summary was about, so its distances can be redrawn every frame.
    private var summaryAdvice: WalkNarrator.PathAdvice = .clear
    private var summaryObstacles: [UUID] = []

    /// How long a "stop" alert stays on screen.
    private let alertDisplayTime: TimeInterval = 4

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
    /// What the sheet shows: a stop alert first, otherwise the summary when something is worth knowing.
    private var shown: ObstacleAlert? { alert ?? summary.flatMap { $0.severity > .info ? $0 : nil } }

    var tagText: String { isStarting ? "Starting" : shown?.severity.label ?? (isRerouting ? "Rerouting" : "All clear") }
    var tagAccent: Accent { shown?.severity.accent ?? (isRerouting ? .sand : .sage) }
    var deliveryText: String { feedback.preferences.deliveryDescription(for: alert?.severity ?? .headsUp) }

    var headline: String {
        if isStarting { return "Preparing to scan." }
        // Climbing: a steady message instead of re-reading each step.
        if alert == nil, narrator.isOnStairs { return "On the stairs." }
        if let shown { return shown.headline }
        if hasArrived { return "You've arrived." }
        if !cameraAvailable { return "Camera is off. No obstacle alerts." }
        if isRerouting { return "Finding a new route." }
        return "Path looks clear ahead."
    }

    var guidance: String {
        if isStarting { return "Point the phone in front of you when scanning begins." }
        if alert == nil, narrator.isOnStairs { return "Hold the railing and take it one step at a time." }
        if let shown { return shown.guidance }
        if navigation?.isWrongWay == true { return "Turn around. The route is behind you." }
        // The turn coming up and how far away it is, so the card matches what the voice says next
        // (not the turn just made).
        if let next = navigation?.nextStep, let remaining = distanceToNextManeuver, !hasArrived {
            let what = next.maneuver == .arrive ? "Destination" : next.instruction
            return "\(what) in \(DistanceText.short(remaining))."
        }
        // Not on the route yet: how to start.
        if let step = navigation?.currentStep, !hasArrived { return step.instruction }
        return "Keep walking. I'll warn you about obstacles."
    }

    /// Measured along the route, so it counts down as the user walks it.
    private var distanceToNextManeuver: Double? { navigation?.distanceToNextManeuver }

    // MARK: Find door

    /// Where this walk started, and whether the user has clearly left it (outside, GPS settled, moved away).
    private var startPoint: GeoPoint?
    private var hasLeftStart = false
    private var lastAccuracy: Double?

    /// "Find door" shows only when a door is likely nearby: at the start (you may still be inside),
    /// when GPS is poor (probably indoors), and close to the destination.
    var showsFindDoor: Bool {
        if isDescribing || hasArrived || !hasLeftStart { return true }
        if let lastAccuracy, lastAccuracy > Self.indoorAccuracy { return true }
        if let route, let currentLocation, currentLocation.distance(to: route.arrivalPoint) <= Self.nearDestination { return true }
        return false
    }

    /// GPS this inaccurate usually means the phone is inside a building.
    private static let indoorAccuracy = 30.0
    /// Out the door: this far from the start with GPS this good.
    private static let leftStartDistance = 15.0
    private static let outdoorAccuracy = 20.0
    private static let nearDestination = 40.0

    private func noteLocation(_ fix: LocationFix) {
        lastAccuracy = fix.accuracy
        guard fix.accuracy <= Self.outdoorAccuracy else { return }
        guard let startPoint else {
            self.startPoint = fix.point
            return
        }
        if fix.point.distance(to: startPoint) >= Self.leftStartDistance { hasLeftStart = true }
    }

    var guidanceIcon: Maneuver {
        if let shown { return shown.guidanceIcon }
        if let navigation, navigation.distanceToNextManeuver != nil, let next = navigation.nextStep { return next.maneuver }
        return navigation?.currentStep?.maneuver ?? .straight
    }

    // MARK: Running

    func run() async {
        isStarting = true
        let generation = feedback.screenGeneration
        let granted = await detection.requestPermission()
        guard generation == feedback.screenGeneration, !Task.isCancelled else { return }
        cameraAvailable = granted
        let overview = isNavigating ? "Beginning route. " : ""
        // Which way to face first ("Turn left."), so the walk starts in the route's direction.
        var facing = ""
        if let route, let turn = await startOrientation(for: route) { facing = "\(turn) " }
        guard generation == feedback.screenGeneration, !Task.isCancelled else { return }
        let scanning = granted
            ? "Beginning to scan the area. Point the phone in front of you."
            : AppError.permissionDenied(.camera).spokenMessage + (isNavigating ? " Directions still work." : "")
        await feedback.announce(overview + facing + scanning, priority: .navigation)
        await feedback.waitForSpeech()
        guard generation == feedback.screenGeneration, !Task.isCancelled else { return }
        isStarting = false
        async let obstacles: Void = watchObstacles(generation: generation)
        async let directions: Void = followRoute(generation: generation)
        _ = await (obstacles, directions)
    }

    private func watchObstacles(generation: Int) async {
        guard cameraAvailable, generation == feedback.screenGeneration, !Task.isCancelled else { return }
        for await frame in detection.frames() {
            guard generation == feedback.screenGeneration, !Task.isCancelled else { return }
            let now = Date.now
            // Things that belong together are one (a person with a bag, a cyclist, a group of people),
            // and anything that stays put is just an obstacle, so its name doesn't keep changing.
            var grouped = frame
            grouped.objects = SceneGrouping.group(frame.objects).map(ObjectCatalog.forWalking)
            // Each thing is recognized once, then followed by position.
            let tracks = tracker.update(with: grouped, now: now)
            // Only what matters is drawn; boxes keep their identity so they don't flicker.
            objects = tracks.filter { track in
                guard track.isVisible, track.tier >= .important else { return false }
                // On stairs, don't keep redrawing the steps as the phone tilts.
                return !(narrator.isOnStairs && (track.category == .stairs || track.label == ObstacleTracker.genericLabel))
            }.map(\.object)
            imageSize = frame.imageSize
            if alert != nil, now.timeIntervalSince(alertShownAt) >= alertDisplayTime { alert = nil }

            if let pose = frame.pose {
                recentPoses.append((now, pose.origin))
                recentPoses.removeAll { now.timeIntervalSince($0.time) > 2 }
            }
            // Climbing or going down: the phone's height keeps changing while the user moves forward.
            if let direction = climbingDirection {
                narrator.noteClimbing(now: now)
                if !saidOnStairs {
                    saidOnStairs = true
                    await feedback.announce("You're on the stairs, going \(direction). Hold the railing.", priority: .navigation)
                }
            } else if !narrator.isOnStairs {
                saidOnStairs = false
            }
            // Read out only where it matters; otherwise keep tracking quietly, so arriving at the
            // crossing says the current state.
            if let change = signalTracker.update(frame.signal, now: now) ?? (signalMatters && !signalAnnounced ? signalTracker.state : nil),
               signalMatters {
                signalAnnounced = true
                await feedback.announce(change.spoken, priority: .navigation)
            }
            if !signalMatters { signalAnnounced = false }

            // What's on screen changes every few seconds, but its distances stay current.
            if summary != nil {
                let current = summaryObstacles.compactMap { id in tracks.first { $0.id == id } }
                summary = WalkNarrator.summary(advice: summaryAdvice, obstacles: current)
            }

            let outputs = narrator.update(tracks: tracks, clearance: frame.clearance,
                                          canSpeak: !feedback.isSpeaking && !isDescribing, now: now)
            for output in outputs {
                switch output {
                case .urgent(let next):
                    alert = next
                    alertShownAt = now
                    await feedback.deliverUrgent(next)
                case .summary(let next, let speak, let advice, let obstacles):
                    summary = next
                    summaryAdvice = advice
                    summaryObstacles = obstacles
                    if speak { await feedback.speakSummary(next) }
                case .pulse:
                    feedback.proximityPulse()
                }
            }
        }
    }

    private func followRoute(generation: Int) async {
        guard generation == feedback.screenGeneration, !Task.isCancelled else { return }
        guard navigation != nil else {
            await watchLocation(generation: generation)
            return
        }

        for await fix in location.updates() {
            guard generation == feedback.screenGeneration, !Task.isCancelled else { return }
            noteLocation(fix)
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

    /// Free walking: location only decides when "Find door" shows.
    private func watchLocation(generation: Int) async {
        guard await location.requestAuthorization() else { return }
        for await fix in location.updates() {
            guard generation == feedback.screenGeneration, !Task.isCancelled else { return }
            noteLocation(fix)
            currentLocation = fix.point
        }
    }

    /// Which way to turn to face the way the route starts ("Turn left."), or nil when already facing it
    /// or the compass doesn't answer.
    private func startOrientation(for route: Route) async -> String? {
        guard let bearing = route.initialBearing, let heading = await currentHeading() else { return nil }
        return RouteWording.orientation(heading: heading, routeBearing: bearing)
    }

    /// Which way the phone faces, or nil if the compass doesn't answer within 2 seconds.
    private func currentHeading() async -> Double? {
        let reading = Task { () -> Double? in
            for await heading in location.headings() { return heading }
            return nil
        }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(2))
            reading.cancel()
        }
        defer { timeout.cancel() }
        return await reading.value
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
            // Last few meters: look for the door with the camera, once "You've arrived" has been said.
            if cameraAvailable {
                for _ in 0..<30 where feedback.isSpeaking { try? await Task.sleep(for: .milliseconds(200)) }
                await findDoor()
            }
        case .hazardAhead:
            await feedback.announce(text, priority: .safety, haptic: .headsUp)
        case .wrongWay:
            await feedback.announce(text, priority: .navigation, haptic: .headsUp)
        case .approaching, .backOnRoute, .rightWay:
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
            let facing = await startOrientation(for: fresh).map { "\($0) " } ?? ""
            guard generation == feedback.screenGeneration, !Task.isCancelled else { return }
            await feedback.announce("New route. \(facing)\(fresh.spokenOverview)", priority: .navigation)
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

    /// Clears the description from the screen a few seconds after it's been read out.
    private func clearDescription(_ text: String) async {
        try? await Task.sleep(for: .milliseconds(500))
        // Up to two minutes of reading, then a short pause to take it in.
        for _ in 0..<600 where feedback.isSpeaking { try? await Task.sleep(for: .milliseconds(200)) }
        try? await Task.sleep(for: .seconds(4))
        if sceneDescription == text { sceneDescription = nil }
    }

    func describeScene() async {
        await describe(.outdoor, intro: "Looking around.", failure: "I couldn't describe the scene right now.")
    }

    /// Where the door is, whether it's open, and how to open it. Runs on arrival, or from the button.
    func findDoor() async {
        await describe(.door, intro: "Looking for a door. Hold the phone up and turn slowly.",
                       failure: "I couldn't look for the door right now. Try again in a moment.")
    }

    private func describe(_ setting: SceneSetting, intro: String, failure: String) async {
        guard !isDescribing else { return }
        isDescribing = true
        defer { isDescribing = false }
        feedback.stopSpeech()
        let generation = feedback.screenGeneration
        await feedback.announce(intro, priority: .info)
        // Give the user a moment to point the phone at the building.
        if setting == .door { try? await Task.sleep(for: .seconds(2)) }
        do {
            guard let jpeg = await detection.latestFrameJPEG() else { throw AppError.server(message: "The camera isn't ready yet.") }
            let text = try await describer.describe(jpeg: jpeg, setting: setting)
            // Left the screen while waiting: say nothing.
            guard generation == feedback.screenGeneration, !Task.isCancelled else { return }
            sceneDescription = text
            await feedback.announce(text, priority: .snapshot)
            Task { await clearDescription(text) }
        } catch {
            guard generation == feedback.screenGeneration, !Task.isCancelled else { return }
            await feedback.announce(failure, priority: .info)
        }
    }
}
