import AppIntents

// Siri and Shortcuts entry points. Each one opens the app and hands off to the voice assistant
// or the router, so a user can start Resonate without finding it on the screen. The actions Claude
// can take are App Intents too (AssistantToolIntents.swift); some get Siri phrases below.

/// "Hey Siri, talk to Resonate": opens the app, asks what the user needs, and listens until they pause.
struct TalkToResonateIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to Resonate"
    static let description = IntentDescription("Opens Resonate and starts the voice assistant.")
    static let openAppWhenRun = true

    @Dependency private var app: AppModel

    @MainActor
    func perform() async throws -> some IntentResult {
        app.assistant.listenHandsFree()
        return .result()
    }
}

/// "Hey Siri, find a place in Resonate": asks what to find, then the assistant searches and answers.
struct FindPlaceIntent: AppIntent {
    static let title: LocalizedStringResource = "Find a Place"
    static let description = IntentDescription("Searches for a place nearby and reads out the closest matches.")
    static let openAppWhenRun = true

    @Parameter(title: "Place", requestValueDialog: "Where do you want to go?")
    var place: String

    @Dependency private var app: AppModel

    @MainActor
    func perform() async throws -> some IntentResult {
        app.assistant.start(with: "Find \(place)")
        return .result()
    }
}

/// "Hey Siri, start walking with Resonate": opens obstacle warnings right away.
struct StartWalkingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Walking"
    static let description = IntentDescription("Opens the camera and warns you about obstacles ahead.")
    static let openAppWhenRun = true

    @Dependency private var app: AppModel

    @MainActor
    func perform() async throws -> some IntentResult {
        app.router.cover = .walk(nil)
        return .result()
    }
}

struct ResonateShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TalkToResonateIntent(),
            phrases: ["Talk to \(.applicationName)", "Start \(.applicationName) assistant", "Ask \(.applicationName)"],
            shortTitle: "Talk to Resonate",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: FindPlaceIntent(),
            phrases: ["Find a place in \(.applicationName)", "Search \(.applicationName)"],
            shortTitle: "Find a Place",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: StartNavigationIntent(),
            phrases: ["Navigate with \(.applicationName)", "Get directions in \(.applicationName)"],
            shortTitle: "Navigate",
            systemImageName: "location.north.fill"
        )
        AppShortcut(
            intent: StopAssistantIntent(),
            phrases: ["Stop \(.applicationName) assistant"],
            shortTitle: "Stop Assistant",
            systemImageName: "mic.slash"
        )
        AppShortcut(
            intent: StartWalkingIntent(),
            phrases: ["Start walking with \(.applicationName)", "Walk with \(.applicationName)"],
            shortTitle: "Start Walking",
            systemImageName: "figure.walk"
        )
    }
}
