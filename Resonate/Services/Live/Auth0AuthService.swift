import Auth0
import Foundation

/// Auth0 Universal Login. Credentials (with a refresh token) live in the Keychain via
/// CredentialsManager. Guests are remembered in UserDefaults so they skip the login screen.
final class Auth0AuthService: AuthServicing {
    private(set) var state: AuthState = .signedOut

    private let config: AppConfig
    private let credentialsManager: CredentialsManager
    private let defaults: UserDefaults
    private let guestKey = "auth.isGuest"

    init(config: AppConfig, defaults: UserDefaults = .standard) {
        self.config = config
        self.defaults = defaults
        self.credentialsManager = CredentialsManager(
            authentication: Auth0.authentication(clientId: config.auth0ClientID, domain: config.auth0Domain)
        )
    }

    private var webAuth: any WebAuth {
        Auth0.webAuth(clientId: config.auth0ClientID, domain: config.auth0Domain)
            .audience(config.auth0Audience)
            // A private browser session skips the "wants to use auth0.com to sign in" alert,
            // one less dialog for VoiceOver users. Sign-out then only needs to clear the Keychain.
            .useEphemeralSession()
            .useCredentialsManager(credentialsManager)
    }

    func restoreSession() async -> AuthState {
        if credentialsManager.canRenew() || credentialsManager.hasValid(),
           let account = storedAccount() {
            state = .signedIn(account)
        } else if defaults.bool(forKey: guestKey) {
            state = .guest
        } else {
            state = .signedOut
        }
        return state
    }

    func signIn() async throws -> UserAccount {
        do {
            _ = try await webAuth.start()
        } catch let error as WebAuthError where error == .userCancelled {
            throw CancellationError()
        }
        guard let account = storedAccount() else {
            throw AppError.server(message: "Sign in finished, but your account details were missing. Try again.")
        }
        defaults.set(false, forKey: guestKey)
        state = .signedIn(account)
        return account
    }

    func continueAsGuest() {
        defaults.set(true, forKey: guestKey)
        state = .guest
    }

    func signOut() async throws {
        // Revokes the refresh token on Auth0 and clears the Keychain.
        do {
            try await credentialsManager.revoke()
        } catch {
            try? credentialsManager.clear()
        }
        defaults.set(false, forKey: guestKey)
        state = .signedOut
    }

    func accessToken() async throws -> String? {
        guard case .signedIn = state else { return nil }
        return try await credentialsManager.credentials().accessToken
    }

    private func storedAccount() -> UserAccount? {
        guard let profile = try? credentialsManager.userProfile() else { return nil }
        return UserAccount(id: profile.sub, name: profile.name, email: profile.email)
    }
}
