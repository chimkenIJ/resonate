import AppIntents

// The app actions Claude can take. Each tool declared in supabase/functions/assistant/index.ts is
// one of these App Intents: the voice assistant runs the matching intent when Claude calls a tool,
// and Siri and Shortcuts can run the same intents directly. Keep the two lists in sync.

/// What an action did: `result` goes back to Claude as the tool result, `dialog` is what Siri says.
struct IntentOutcome {
    var result: JSONValue
    var dialog: String
}

/// An App Intent that Claude can call as a tool.
protocol AssistantToolIntent: AppIntent {
    /// The tool's name in the assistant function's tool list.
    static var toolName: String { get }
    /// Builds the intent from Claude's tool input.
    init(toolInput: JSONValue)
    @MainActor func run(on app: AppModel) async throws -> IntentOutcome
}

enum AssistantTools {
    static let all: [any AssistantToolIntent.Type] = [
        OpenScreenIntent.self, SearchPlacesIntent.self, ShowRouteIntent.self, StartNavigationIntent.self,
        OpenCameraModeIntent.self, CloseScreenIntent.self, ListSavedPlacesIntent.self, SavePlaceIntent.self,
        ChangeSettingIntent.self, StopAssistantIntent.self,
    ]

    /// Runs the intent for a tool call and returns the tool result for Claude.
    @MainActor
    static func run(_ name: String, input: JSONValue, on app: AppModel) async throws -> JSONValue {
        guard let tool = all.first(where: { $0.toolName == name }) else {
            throw AppError.server(message: "I don't know how to do that yet.")
        }
        return try await tool.init(toolInput: input).run(on: app).result
    }
}

// MARK: - Choices

enum AppScreen: String, AppEnum {
    case home, search, savedPlaces = "saved_places", settings

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Screen"
    static let caseDisplayRepresentations: [AppScreen: DisplayRepresentation] = [
        .home: "Home", .search: "Search", .savedPlaces: "Saved places", .settings: "Settings",
    ]

    var tab: AppTab {
        switch self {
        case .home: .home
        case .search: .search
        case .savedPlaces: .saved
        case .settings: .settings
        }
    }
}

enum CameraMode: String, AppEnum {
    case walk, scanArea = "scan_area", indoorScan = "indoor_scan", colors

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Camera mode"
    static let caseDisplayRepresentations: [CameraMode: DisplayRepresentation] = [
        .walk: "Walk mode", .scanArea: "Scan the area", .indoorScan: "Indoor scan", .colors: "Colors",
    ]
}

enum RouteSetting: String, AppEnum {
    case avoidStairs = "avoid_stairs", tactilePaving = "tactile_paving", audibleCrossings = "audible_crossings"

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Route setting"
    static let caseDisplayRepresentations: [RouteSetting: DisplayRepresentation] = [
        .avoidStairs: "Avoid stairs", .tactilePaving: "Tactile paving", .audibleCrossings: "Audible crossings",
    ]

    var name: String {
        switch self {
        case .avoidStairs: "Avoid stairs"
        case .tactilePaving: "Tactile paving"
        case .audibleCrossings: "Audible crossings"
        }
    }
}

// MARK: - Screens

struct OpenScreenIntent: AssistantToolIntent {
    static let toolName = "open_screen"
    static let title: LocalizedStringResource = "Open Screen"
    static let description = IntentDescription("Opens Home, Search, Saved places, or Settings.")
    static let openAppWhenRun = true

    @Parameter(title: "Screen") var screen: AppScreen
    @Dependency private var app: AppModel

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(try await run(on: app).dialog)")
    }

    @MainActor
    func run(on app: AppModel) async throws -> IntentOutcome {
        let tab = screen.tab
        app.router.cover = nil
        app.router.tab = tab
        app.router.paths[tab] = []
        return IntentOutcome(result: ["opened": .string(tab.title)], dialog: "Opened \(tab.title).")
    }
}

extension OpenScreenIntent {
    init(toolInput: JSONValue) {
        self.init()
        screen = AppScreen(rawValue: toolInput["screen"]?.stringValue ?? "") ?? .home
    }
}

struct CloseScreenIntent: AssistantToolIntent {
    static let toolName = "close_screen"
    static let title: LocalizedStringResource = "Close Screen"
    static let description = IntentDescription("Closes the camera screen or goes back one screen. Also ends navigation.")
    static let openAppWhenRun = true

    @Dependency private var app: AppModel

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(try await run(on: app).dialog)")
    }

    @MainActor
    func run(on app: AppModel) async throws -> IntentOutcome {
        let router = app.router
        if router.cover != nil {
            router.cover = nil
            return IntentOutcome(result: ["closed": "camera screen"], dialog: "Closed the camera.")
        }
        if var path = router.paths[router.tab], !path.isEmpty {
            path.removeLast()
            router.paths[router.tab] = path
            return IntentOutcome(result: ["went_back": true], dialog: "Went back.")
        }
        return IntentOutcome(result: ["note": "Already on a main screen."], dialog: "You're already on a main screen.")
    }
}

extension CloseScreenIntent {
    init(toolInput: JSONValue) { self.init() }
}

struct OpenCameraModeIntent: AssistantToolIntent {
    static let toolName = "open_camera_mode"
    static let title: LocalizedStringResource = "Open Camera Mode"
    static let description = IntentDescription("Opens walk mode, scan the area, indoor scanning, or color naming.")
    static let openAppWhenRun = true

    @Parameter(title: "Mode") var mode: CameraMode
    @Dependency private var app: AppModel

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try await run(on: app)
        return .result() // the camera screen speaks for itself
    }

    @MainActor
    func run(on app: AppModel) async throws -> IntentOutcome {
        app.router.cover = switch mode {
        case .walk: .walk(nil)
        case .scanArea: .scanArea
        case .indoorScan: .indoor
        case .colors: .colors
        }
        return IntentOutcome(result: ["opened": .string(mode.rawValue)], dialog: "")
    }
}

extension OpenCameraModeIntent {
    init(toolInput: JSONValue) {
        self.init()
        mode = CameraMode(rawValue: toolInput["mode"]?.stringValue ?? "") ?? .walk
    }
}

// MARK: - Places and routes

struct SearchPlacesIntent: AssistantToolIntent {
    static let toolName = "search_places"
    static let title: LocalizedStringResource = "Search Places"
    static let description = IntentDescription("Searches for places near you and shows the closest matches.")
    static let openAppWhenRun = true

    @Parameter(title: "Place", requestValueDialog: "What should I look for?") var query: String
    @Dependency private var app: AppModel

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(try await run(on: app).dialog)")
    }

    @MainActor
    func run(on app: AppModel) async throws -> IntentOutcome {
        app.router.cover = nil
        app.router.openSearch(listen: false)
        let places = try await app.search.searchQuietly(query)
        app.assistant.remember(places)
        let closest = places.prefix(3).map { place in
            place.name + (place.distanceMeters.map { ", \(DistanceText.spoken($0))" } ?? "")
        }
        return IntentOutcome(
            result: ["places": .array(places.map(\.toolDescription))],
            dialog: "Closest matches: \(closest.joined(separator: "; "))."
        )
    }
}

extension SearchPlacesIntent {
    init(toolInput: JSONValue) {
        self.init()
        query = toolInput["query"]?.stringValue ?? ""
    }
}

struct ShowRouteIntent: AssistantToolIntent {
    static let toolName = "show_route"
    static let title: LocalizedStringResource = "Show Route"
    static let description = IntentDescription("Plans an accessible walking route to a place and shows the overview.")
    static let openAppWhenRun = true

    @Parameter(title: "Place", requestValueDialog: "Where to?") var place: String
    @Dependency private var app: AppModel
    /// From Claude, `place` must be the id of a place it was shown, never a guess.
    var placeIsID = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(try await run(on: app).dialog)")
    }

    @MainActor
    func run(on app: AppModel) async throws -> IntentOutcome {
        let destination = try await app.resolvePlace(place, isID: placeIsID)
        let route = try await app.planRoute(to: destination)
        app.router.cover = nil
        app.router.push(.route(destination))
        var info = route.toolDescription
        info["note"] = "The route screen is open and reads this summary aloud, so don't repeat it."
        return IntentOutcome(result: .object(info), dialog: route.spokenSummary)
    }
}

extension ShowRouteIntent {
    init(toolInput: JSONValue) {
        self.init()
        place = toolInput["place_id"]?.stringValue ?? ""
        placeIsID = true
    }
}

struct StartNavigationIntent: AssistantToolIntent {
    static let toolName = "start_navigation"
    static let title: LocalizedStringResource = "Start Navigation"
    static let description = IntentDescription("Starts turn-by-turn walking directions with obstacle warnings.")
    static let openAppWhenRun = true

    @Parameter(title: "Place", requestValueDialog: "Where do you want to go?") var place: String
    @Dependency private var app: AppModel
    var placeIsID = false

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try await run(on: app)
        return .result() // navigation announces itself
    }

    @MainActor
    func run(on app: AppModel) async throws -> IntentOutcome {
        let destination = try await app.resolvePlace(place, isID: placeIsID)
        let route = try await app.planRoute(to: destination)
        app.router.cover = .walk(route)
        var info = route.toolDescription
        info["note"] = "Navigation started. The app speaks each turn and warns about obstacles."
        return IntentOutcome(result: .object(info), dialog: "")
    }
}

extension StartNavigationIntent {
    init(toolInput: JSONValue) {
        self.init()
        place = toolInput["place_id"]?.stringValue ?? ""
        placeIsID = true
    }
}

// MARK: - Saved places

struct ListSavedPlacesIntent: AssistantToolIntent {
    static let toolName = "list_saved_places"
    static let title: LocalizedStringResource = "List Saved Places"
    static let description = IntentDescription("Reads your saved-place folders and the places in each.")
    static let openAppWhenRun = true

    @Dependency private var app: AppModel

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(try await run(on: app).dialog)")
    }

    @MainActor
    func run(on app: AppModel) async throws -> IntentOutcome {
        let service = app.services.savedPlaces
        var folders: [JSONValue] = []
        var spoken: [String] = []
        for folder in try await service.folders() {
            let places = ((try? await service.places(in: folder.id)) ?? []).map(\.place)
            app.assistant.remember(places)
            folders.append(["folder": .string(folder.name), "places": .array(places.map(\.toolDescription))])
            spoken.append(places.isEmpty ? "\(folder.name) is empty" : "\(folder.name): \(places.map(\.name).joined(separator: ", "))")
        }
        let dialog = spoken.isEmpty ? "You don't have any folders yet." : spoken.joined(separator: ". ") + "."
        return IntentOutcome(result: ["folders": .array(folders)], dialog: dialog)
    }
}

extension ListSavedPlacesIntent {
    init(toolInput: JSONValue) { self.init() }
}

struct SavePlaceIntent: AssistantToolIntent {
    static let toolName = "save_place"
    static let title: LocalizedStringResource = "Save Place"
    static let description = IntentDescription("Saves a place into one of your folders.")
    static let openAppWhenRun = true

    @Parameter(title: "Place") var place: String
    @Parameter(title: "Folder") var folderName: String
    @Dependency private var app: AppModel
    var placeIsID = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(try await run(on: app).dialog)")
    }

    @MainActor
    func run(on app: AppModel) async throws -> IntentOutcome {
        let destination = try await app.resolvePlace(place, isID: placeIsID)
        let folders = try await app.services.savedPlaces.folders()
        guard let folder = folders.first(where: { $0.name.localizedCaseInsensitiveCompare(folderName) == .orderedSame }) else {
            throw AppError.server(message: "There's no folder called \(folderName). Your folders are \(folders.map(\.name).joined(separator: ", ")).")
        }
        _ = try await app.services.savedPlaces.save(destination, routeSummary: nil, to: folder.id)
        return IntentOutcome(
            result: ["saved": .string(destination.name), "folder": .string(folder.name)],
            dialog: "Saved \(destination.name) to \(folder.name)."
        )
    }
}

extension SavePlaceIntent {
    init(toolInput: JSONValue) {
        self.init()
        place = toolInput["place_id"]?.stringValue ?? ""
        folderName = toolInput["folder_name"]?.stringValue ?? ""
        placeIsID = true
    }
}

// MARK: - Settings and the assistant

struct ChangeSettingIntent: AssistantToolIntent {
    static let toolName = "change_setting"
    static let title: LocalizedStringResource = "Change Route Setting"
    static let description = IntentDescription("Turns avoid stairs, tactile paving, or audible crossings on or off.")
    static let openAppWhenRun = true

    @Parameter(title: "Setting") var setting: RouteSetting
    @Parameter(title: "On") var enabled: Bool
    @Dependency private var app: AppModel
    /// Claude named a setting that isn't in the list.
    var isUnknownSetting = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(try await run(on: app).dialog)")
    }

    @MainActor
    func run(on app: AppModel) async throws -> IntentOutcome {
        guard !isUnknownSetting else { throw AppError.server(message: "I can't change that setting.") }
        var preferences = app.preferences
        switch setting {
        case .avoidStairs: preferences.routing.avoidSteps = enabled
        case .tactilePaving: preferences.routing.preferTactilePaving = enabled
        case .audibleCrossings: preferences.routing.preferAudioSignals = enabled
        }
        try await app.updatePreferences(preferences)
        return IntentOutcome(result: [setting.rawValue: .bool(enabled)], dialog: "\(setting.name) \(enabled ? "on" : "off").")
    }
}

extension ChangeSettingIntent {
    init(toolInput: JSONValue) {
        self.init()
        let setting = RouteSetting(rawValue: toolInput["setting"]?.stringValue ?? "")
        self.setting = setting ?? .avoidStairs
        isUnknownSetting = setting == nil
        enabled = toolInput["enabled"]?.boolValue ?? true
    }
}

struct StopAssistantIntent: AssistantToolIntent {
    static let toolName = "stop_listening"
    static let title: LocalizedStringResource = "Stop Voice Assistant"
    static let description = IntentDescription("Turns off Resonate's voice assistant.")

    @Dependency private var app: AppModel
    /// From Claude: finish saying goodbye first.
    var afterReply = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(try await run(on: app).dialog)")
    }

    @MainActor
    func run(on app: AppModel) async throws -> IntentOutcome {
        if afterReply {
            app.assistant.stopAfterThisTurn()
        } else {
            app.assistant.stop()
        }
        return IntentOutcome(result: ["stopping": true], dialog: "Voice assistant off.")
    }
}

extension StopAssistantIntent {
    init(toolInput: JSONValue) {
        self.init()
        afterReply = true
    }
}

// MARK: - Helpers

extension AppModel {
    /// A place Claude was shown (by id), or for Siri and Shortcuts, the closest match for a name.
    func resolvePlace(_ reference: String, isID: Bool) async throws -> Place {
        if let place = assistant.knownPlace(id: reference) ?? search.results.first(where: { $0.id == reference }) {
            return place
        }
        guard !isID else { throw AppError.server(message: "I don't have that place anymore. Search for it again.") }
        let name = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let place = try await search.searchQuietly(name).first else {
            throw AppError.noResults(query: name)
        }
        return place
    }

    func planRoute(to place: Place) async throws -> Route {
        let origin = try await services.location.currentLocation()
        guard GeorgiaRegion.contains(origin), GeorgiaRegion.contains(place.coordinate) else {
            throw AppError.outsideGeorgia
        }
        return try await services.routing.route(from: origin, to: place, preferences: preferences.routing)
    }
}

extension Place {
    var toolDescription: JSONValue {
        var info: [String: JSONValue] = ["id": .string(id), "name": .string(name), "address": .string(address)]
        if let meters = distanceMeters { info["distance"] = .string(DistanceText.spoken(meters)) }
        return .object(info)
    }
}

extension Route {
    var toolDescription: [String: JSONValue] {
        [
            "destination": .string(destination.name),
            "summary": .string(spokenSummary),
            "features": .array(features.map { .string($0.label) }),
            "first_step": .string(steps.first?.spoken ?? ""),
        ]
    }
}
