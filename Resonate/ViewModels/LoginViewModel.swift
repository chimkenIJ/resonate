import Foundation
import Observation

@Observable
final class LoginViewModel {
    private(set) var isWorking = false
    private(set) var errorMessage: String?

    private let auth: any AuthServicing
    private let feedback: FeedbackCenter
    private let onAuthenticated: (AuthState) async -> Void

    init(auth: any AuthServicing, feedback: FeedbackCenter, onAuthenticated: @escaping (AuthState) async -> Void) {
        self.auth = auth
        self.feedback = feedback
        self.onAuthenticated = onAuthenticated
    }

    func signIn() async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let user = try await auth.signIn()
            await onAuthenticated(.signedIn(user))
        } catch is CancellationError {
            // The user closed the login sheet; nothing to say.
        } catch {
            let message = "Sign in didn't finish. Try again, or continue without an account."
            errorMessage = message
            await feedback.announce(message, priority: .info)
        }
    }

    func continueAsGuest() async {
        auth.continueAsGuest()
        await onAuthenticated(.guest)
    }
}
