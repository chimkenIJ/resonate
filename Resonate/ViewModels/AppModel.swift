import Foundation
import OSLog
import Observation

/// App-wide state: which phase the user is in (login, onboarding, main app),
/// their account, their preferences, and the shared services.
@Observable
final class AppModel {
    enum Phase: Equatable {
        case launching, login, onboarding, ready
    }

    let services: AppServices
    let feedback: FeedbackCenter
    let router: AppRouter
    /// Shared by the Search tab and the voice assistant, so the assistant's searches show there.
    let search: DestinationSearchViewModel
    let assistant = VoiceAssistant()
    /// The open camera screen that can describe the scene (walk, navigation, scan the area),
    /// so the assistant can describe without leaving it.
    weak var sceneDescriber: (any SceneDescribing)?

    private(set) var phase: Phase = .launching {
        didSet {
            if phase != oldValue { feedback.endScreenSpeech() }
            if phase == .ready { assistant.appBecameReady() }
        }
    }
    private(set) var authState: AuthState = .signedOut
    private(set) var preferences = UserPreferences() {
        didSet { feedback.preferences = preferences }
    }

    init(services: AppServices) {
        self.services = services
        let feedback = FeedbackCenter(
            speech: services.speech,
            haptics: services.haptics,
            tones: services.tones,
            preferences: UserPreferences()
        )
        self.feedback = feedback
        self.router = AppRouter { feedback.endScreenSpeech() }
        self.search = DestinationSearchViewModel(services: services)
        assistant.attach(to: self)
    }

    func bootstrap() async {
        guard phase == .launching else { return }
        // Record the safety phrases in the app's voice in the background, so alerts work offline.
        let speech = services.speech
        Task { await speech.prewarm(SpeechPhrases.safety) }
        authState = await services.auth.restoreSession()
        await routeAfterAuth()
    }

    /// Called by the login screen after Auth0 sign-in or "Continue without account".
    func didAuthenticate(_ state: AuthState) async {
        authState = state
        await routeAfterAuth()
    }

    /// Sign in later from Settings (guest → account).
    func signIn() async throws {
        let user = try await services.auth.signIn()
        authState = .signedIn(user)
        await routeAfterAuth()
    }

    func signOut() async {
        assistant.stop()
        try? await services.auth.signOut()
        authState = .signedOut
        router.reset()
        phase = .login
    }

    func updatePreferences(_ newValue: UserPreferences) async throws {
        try await services.preferences.save(newValue)
        preferences = newValue
        if phase == .onboarding {
            if case .signedIn(let user) = authState {
                UserDefaults.standard.set(true, forKey: "onboarding.\(user.id)")
            }
            phase = .ready
        }
    }

    private var needsAccountOnboarding: Bool {
        guard case .signedIn(let user) = authState else { return false }
        return !UserDefaults.standard.bool(forKey: "onboarding.\(user.id)")
    }

    private func routeAfterAuth() async {
        guard authState != .signedOut else {
            phase = .login
            return
        }
        if case .signedIn(let user) = authState {
            await syncAccount(user)
        }
        if let saved = await services.preferences.load() {
            preferences = saved
            phase = needsAccountOnboarding ? .onboarding : .ready
        } else {
            phase = .onboarding
        }
    }

    /// Creates the Supabase user row and starter folders on first sign-in. Failure (for example,
    /// offline) is fine: it runs again next launch, and on-device features never depend on it.
    private func syncAccount(_ user: UserAccount) async {
        do {
            try await services.users.ensureUser(user)
        } catch {
            Log.account.error("Couldn't sync account: \(String(describing: error), privacy: .public)")
        }
    }
}

extension AppModel {
    /// For SwiftUI previews: mock services, already past login and onboarding.
    static func preview(phase: Phase = .ready, services: AppServices = .mock()) -> AppModel {
        let model = AppModel(services: services)
        model.authState = .guest
        model.phase = phase
        return model
    }

    #if DEBUG
    /// Opens straight to one screen, for screenshots and UI checks.
    /// Run with the environment variable RESONATE_SCREEN set to: login, onboarding, home, search,
    /// listen, saved, folder, route, walk, navigate, indoor, colors, settings.
    /// Add RESONATE_LIVE=1 to use the real services from ResonateConfig.plist instead of mocks.
    static func debugLaunch(screen: String, live: Bool = false) -> AppModel {
        let services: AppServices = live ? .makeDefault() : .mock()
        switch screen {
        case "login": return AppModel(services: services)
        case "onboarding": return preview(phase: .onboarding, services: services)
        default: break
        }
        let model = preview(services: services)
        let router = model.router
        switch screen {
        case "search": router.tab = .search
        case "listen": router.openSearch(listen: true)
        case "saved": router.tab = .saved
        case "folder":
            router.tab = .saved
            router.paths[.saved] = [.folder(SampleData.folders[0])]
        case "route":
            router.tab = .saved
            router.paths[.saved] = [.folder(SampleData.folders[0]), .route(SampleData.classes[0].place)]
        case "walk": router.cover = .walk(nil)
        case "navigate":
            if live {
                // Fetch a real route, then open turn-by-turn on it.
                Task {
                    let here = (try? await services.location.currentLocation()) ?? SampleData.userLocation
                    if let route = try? await services.routing.route(from: here, to: SampleData.classes[4].place, preferences: RoutingPreferences()) {
                        router.cover = .walk(route)
                    }
                }
            } else {
                router.cover = .walk(SampleData.route(to: SampleData.classes[0].place))
            }
        case "indoor": router.cover = .indoor
        case "colors":
            model.preferences.needs.insert(.colors)
            router.cover = .colors
        case "settings": router.tab = .settings
        default: break
        }
        return model
    }
    #endif
}
