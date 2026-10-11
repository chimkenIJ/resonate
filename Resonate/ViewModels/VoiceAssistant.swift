import Foundation
import OSLog
import Observation

/// Push-to-talk voice assistant (Claude). The user holds the microphone button and talks; when
/// they let go, what they said goes to Claude, the reply is spoken, and the app actions Claude asks
/// for run as App Intents (search, routes, camera screens, settings). The conversation is kept
/// between presses so follow-ups like "the second one" work.
@Observable
final class VoiceAssistant {
    enum State: Equatable {
        case off, listening, thinking, speaking
    }

    private(set) var state: State = .off

    /// Shows the microphone button. On unless the user turns it off. Kept on this phone.
    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if !isEnabled { stop() }
        }
    }

    var isActive: Bool { state != .off }

    @ObservationIgnored private weak var app: AppModel?
    /// The current request: listening, asking Claude, and speaking the reply.
    @ObservationIgnored private var turn: Task<Void, Never>?
    /// The conversation in Messages API form. Only ever appended to (or cleared), never edited.
    @ObservationIgnored private var messages: [JSONValue] = []
    /// Places Claude has seen, by id, so tools can refer to them.
    @ObservationIgnored private var knownPlaces: [String: Place] = [:]
    /// Something to do once the main app is showing (a Siri request during launch).
    @ObservationIgnored private var pendingStart: (() -> Void)?
    @ObservationIgnored private var endAfterTurn = false
    /// The user let go before the microphone had started.
    @ObservationIgnored private var releasedEarly = false
    @ObservationIgnored private var pressStarted = Date.distantPast
    /// True while one of Claude's actions runs, so the screen changes it makes don't stop it.
    @ObservationIgnored private var isRunningTool = false

    private static let enabledKey = "assistant.enabled"
    /// Tool calls Claude can chain for one request ("find Kroger and take me there").
    private let maxToolRounds = 8
    /// Start a fresh conversation past this many messages, so requests stay small.
    private let maxMessages = 80
    /// Shorter presses than this are taken as a tap, not talking.
    private let minimumPress: TimeInterval = 0.4

    init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func attach(to app: AppModel) {
        self.app = app
    }

    // MARK: - Push to talk

    /// The button was pressed: interrupt anything in progress and start listening.
    func beginTalking() {
        guard let app, app.phase == .ready else { return }
        interrupt()
        releasedEarly = false
        pressStarted = .now
        state = .listening
        app.services.haptics.play(.tap)
        turn = Task { await talk(endsOnPause: false) }
    }

    /// The button was let go: stop listening and send what was heard.
    func finishTalking() {
        guard state == .listening else { return }
        releasedEarly = true
        app?.services.speechRecognition.stop()
        app?.services.haptics.play(.tap)
    }

    /// For VoiceOver and Switch Control, where holding is awkward: activate once to talk, again to send.
    func toggleTalking() {
        state == .listening ? finishTalking() : beginTalking()
    }

    /// Siri ("Talk to Resonate"): asks what the user needs and listens until they pause.
    func listenHandsFree() {
        isEnabled = true
        whenReady { [weak self] in
            guard let self else { return }
            interrupt()
            releasedEarly = false
            pressStarted = .distantPast
            state = .speaking
            turn = Task {
                await self.say("What do you need?")
                await self.waitForSpeechToFinish()
                guard !Task.isCancelled else { return }
                await self.talk(endsOnPause: true)
            }
        }
    }

    /// Handles a request that's already in words (from Siri or Shortcuts).
    func start(with request: String) {
        isEnabled = true
        whenReady { [weak self] in
            guard let self else { return }
            interrupt()
            state = .thinking
            turn = Task {
                await self.respond(to: request)
                await self.finishTurn()
            }
        }
    }

    /// Called when the app reaches the main screens.
    func appBecameReady() {
        let start = pendingStart
        pendingStart = nil
        start?()
    }

    /// The user went to another screen themselves: what the assistant was about to say, or was
    /// saying, is out of date. The conversation is kept.
    func screenChanged() {
        guard !isRunningTool, state == .thinking || state == .speaking else { return }
        interrupt()
    }

    /// Stops listening and speaking and forgets the conversation.
    func stop() {
        pendingStart = nil
        interrupt()
        messages = []
        knownPlaces = [:]
        endAfterTurn = false
    }

    private func whenReady(_ action: @escaping () -> Void) {
        if app?.phase == .ready {
            action()
        } else {
            // Launched by Siri before sign-in finished: go once the main app is showing.
            pendingStart = action
        }
    }

    /// Ends the current request without forgetting the conversation.
    private func interrupt() {
        turn?.cancel()
        turn = nil
        if state == .listening { app?.services.speechRecognition.cancel() }
        if state == .speaking || state == .thinking { app?.feedback.stopSpeech() }
        state = .off
    }

    // MARK: - One request

    private func talk(endsOnPause: Bool) async {
        guard let app else { return }
        guard await app.services.speechRecognition.requestAuthorization() else {
            await say(AppError.permissionDenied(.microphone).spokenMessage)
            await finishTurn()
            return
        }
        guard !Task.isCancelled else { return }
        state = .listening
        let text = await listen(endsOnPause: endsOnPause)
        guard !Task.isCancelled else { return }
        if text.isEmpty {
            let wasTap = Date.now.timeIntervalSince(pressStarted) < minimumPress
            await say(wasTap ? "Hold the microphone button while you talk." : "I didn't catch that. Try again.")
        } else {
            await respond(to: text)
        }
        await finishTurn()
    }

    /// Lets the reply finish playing, then goes idle. Forgets the conversation if Claude ended it.
    private func finishTurn() async {
        await waitForSpeechToFinish()
        guard !Task.isCancelled else { return }
        if endAfterTurn {
            endAfterTurn = false
            messages = []
            knownPlaces = [:]
        }
        state = .off
        turn = nil
    }

    /// Waits until the app's voice is quiet.
    private func waitForSpeechToFinish() async {
        await app?.feedback.waitForSpeech()
    }

    /// One utterance. Empty when the user said nothing.
    private func listen(endsOnPause: Bool) async -> String {
        guard let recognizer = app?.services.speechRecognition else { return "" }
        var text = ""
        do {
            let stream = recognizer.transcribe(endsOnPause: endsOnPause)
            // The user may have let go while permission was being checked.
            if releasedEarly { recognizer.stop() }
            for try await partial in stream {
                text = partial
            }
        } catch {
            // Often ends with an error right after the mic turns off; keep what was heard.
            Log.speech.error("Assistant listening ended with: \(String(describing: error), privacy: .public)")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func respond(to text: String) async {
        guard let app else { return }
        if messages.count > maxMessages { messages = [] }
        let checkpoint = messages.count
        state = .thinking
        messages.append([
            "role": "user",
            "content": [
                ["type": "text", "text": .string(appStateNote())],
                ["type": "text", "text": .string(text)],
            ],
        ])

        do {
            for _ in 0..<maxToolRounds {
                let reply = try await app.services.assistant.respond(to: messages)
                try Task.checkCancellation()
                if reply.stopReason == "refusal" {
                    // Leave the declined turn out of the conversation.
                    messages.removeSubrange(checkpoint...)
                    await say("Sorry, I can't help with that one.")
                    return
                }
                messages.append(["role": "assistant", "content": .array(reply.content)])

                let spoken = reply.content
                    .filter { $0["type"]?.stringValue == "text" }
                    .compactMap { $0["text"]?.stringValue }
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !spoken.isEmpty { await say(spoken) }

                guard reply.stopReason == "tool_use" else {
                    if reply.stopReason == "max_tokens", spoken.isEmpty {
                        await say("Sorry, I lost my train of thought. Try asking again.")
                    }
                    return
                }
                // Changing screens stops whatever is playing, so finish this line first.
                await waitForSpeechToFinish()
                state = .thinking
                var results: [JSONValue] = []
                isRunningTool = true
                for call in reply.content where call["type"]?.stringValue == "tool_use" {
                    results.append(await runTool(call))
                }
                isRunningTool = false
                try Task.checkCancellation()
                messages.append(["role": "user", "content": .array(results)])
            }
        } catch {
            // Leave the unfinished request out, so the conversation stays valid for the next one.
            messages.removeSubrange(checkpoint...)
            guard !Task.isCancelled else { return }
            Log.data.error("Assistant request failed: \(String(describing: error), privacy: .public)")
            await say(((error as? AppError) ?? .server(message: "I can't reach the assistant right now. Try again in a moment.")).spokenMessage)
        }
    }

    private func say(_ text: String) async {
        guard let app else { return }
        state = .speaking
        await app.feedback.announce(text, priority: .info)
    }

    // MARK: - Tools

    private func runTool(_ call: JSONValue) async -> JSONValue {
        let name = call["name"]?.stringValue ?? ""
        var result: [String: JSONValue] = ["type": "tool_result", "tool_use_id": call["id"] ?? ""]
        do {
            guard let app else { throw CancellationError() }
            // Every tool is an App Intent (see AssistantToolIntents.swift).
            let output = try await AssistantTools.run(name, input: call["input"] ?? [:], on: app)
            result["content"] = .string(output.jsonText)
        } catch {
            let message = ((error as? AppError) ?? .server(message: "That didn't work. Try again.")).spokenMessage
            result["content"] = .string(JSONValue.object(["error": .string(message)]).jsonText)
            result["is_error"] = true
        }
        return .object(result)
    }

    /// Places Claude has been shown, so tools can refer to them by id.
    func remember(_ places: [Place]) {
        for place in places { knownPlaces[place.id] = place }
    }

    func knownPlace(id: String) -> Place? {
        knownPlaces[id]
    }

    /// Stops once the current reply has been spoken (Claude said goodbye).
    func stopAfterThisTurn() {
        endAfterTurn = true
    }

    /// Where the user is in the app, sent with each request. Claude reads it; the user didn't say it.
    private func appStateNote() -> String {
        guard let app else { return "[App state] Unknown." }
        let router = app.router
        var lines = ["[App state]"]
        switch router.cover {
        case .walk(let route?): lines.append("Screen: navigating to \(route.destination.name), camera on.")
        case .walk(nil): lines.append("Screen: walk mode, camera warning about obstacles.")
        case .indoor: lines.append("Screen: indoor scan camera.")
        case .colors: lines.append("Screen: color naming camera.")
        case .scanArea: lines.append("Screen: scan the area, camera describing the surroundings.")
        case nil:
            var screen = "\(router.tab.title) tab"
            switch router.paths[router.tab]?.last {
            case .folder(let folder): screen += ", \(folder.name) folder"
            case .route(let place): screen += ", route overview to \(place.name)"
            case nil: break
            }
            lines.append("Screen: \(screen).")
        }
        let results = app.search.results
        if !results.isEmpty {
            remember(results)
            let list = results.map { place in
                "\(place.name) (id \(place.id)" + (place.distanceMeters.map { ", \(DistanceText.spoken($0))" } ?? "") + ")"
            }
            lines.append("Search results for \"\(app.search.query)\": \(list.joined(separator: "; ")).")
        }
        let routing = app.preferences.routing
        lines.append("Route settings: avoid stairs \(routing.avoidSteps ? "on" : "off"), tactile paving \(routing.preferTactilePaving ? "on" : "off"), audible crossings \(routing.preferAudioSignals ? "on" : "off").")
        return lines.joined(separator: "\n")
    }
}
