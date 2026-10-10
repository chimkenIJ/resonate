import Foundation
import Testing
@testable import Resonate

@MainActor
struct LoginTests {
    @Test func directAuthenticationPreservesAccount() async {
        let app = AppModel(services: .mock())
        let account = UserAccount(id: "direct-login", name: "Alex", email: "alex@example.com")
        await app.didAuthenticate(.signedIn(account))
        guard case .signedIn(let stored) = app.authState else {
            Issue.record("The account was not stored")
            return
        }
        #expect(stored.id == "direct-login")
        #expect(app.phase == .onboarding)
    }

    @Test func loginCallbackPreservesAccount() async {
        let app = AppModel(services: .mock())
        let login = LoginViewModel(auth: app.services.auth, feedback: app.feedback) { state in
            await app.didAuthenticate(state)
        }
        await login.signIn()
        guard case .signedIn(let stored) = app.authState else {
            Issue.record("The account was not stored")
            return
        }
        #expect(stored.id == "auth0|mock-user")
        #expect(stored.name == "Alex")
        #expect(stored.email == "alex@example.com")
        #expect(app.phase == .onboarding)
        #expect(login.errorMessage == nil)
        #expect(!login.isWorking)
    }

    @Test func settingsAuthenticationPreservesAccount() async throws {
        let app = AppModel(services: .mock())
        try await app.signIn()
        guard case .signedIn(let stored) = app.authState else {
            Issue.record("The account was not stored")
            return
        }
        #expect(stored.id == "auth0|mock-user")
        #expect(app.phase == .onboarding)
    }
}
