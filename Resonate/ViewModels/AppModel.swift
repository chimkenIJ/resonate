import Foundation
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
    let router = AppRouter()

    private(set) var phase: Phase = .launching
    private(set) var authState: AuthState = .signedOut
    private(set) var preferences = UserPreferences() {
        didSet { feedback.preferences = preferences }
    }

    init(services: AppServices) {
        self.services = services
        self.feedback = FeedbackCenter(
            speech: services.speech,
            haptics: services.haptics,
            tones: services.tones,
            preferences: UserPreferences()
        )
    }

    func bootstrap() async {
        guard phase == .launching else { return }
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
    }

    func signOut() async {
        try? await services.auth.signOut()
        authState = .signedOut
        router.reset()
        phase = .login
    }

    func updatePreferences(_ newValue: UserPreferences) async throws {
        try await services.preferences.save(newValue)
        preferences = newValue
        if phase == .onboarding { phase = .ready }
    }

    private func routeAfterAuth() async {
        guard authState != .signedOut else {
            phase = .login
            return
        }
        if let saved = await services.preferences.load() {
            preferences = saved
            phase = .ready
        } else {
            phase = .onboarding
        }
    }
}

extension AppModel {
    /// For SwiftUI previews: mock services, already past login and onboarding.
    static func preview(phase: Phase = .ready) -> AppModel {
        let model = AppModel(services: .mock())
        model.authState = .guest
        model.phase = phase
        return model
    }

    #if DEBUG
    /// Opens straight to one screen, for screenshots and UI checks.
    /// Run with the environment variable RESONATE_SCREEN set to: login, onboarding, home, search,
    /// listen, saved, folder, route, walk, navigate, indoor, colors, settings.
    static func debugLaunch(screen: String) -> AppModel {
        switch screen {
        case "login": return AppModel(services: .mock())
        case "onboarding": return preview(phase: .onboarding)
        default: break
        }
        let model = preview()
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
        case "navigate": router.cover = .walk(SampleData.route(to: SampleData.classes[0].place))
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
