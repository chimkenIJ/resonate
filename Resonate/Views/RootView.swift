import SwiftUI

/// Login → Personalize → main app.
struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            switch app.phase {
            case .launching:
                ProgressView()
                    .tint(Palette.textPrimary)
                    .controlSize(.large)
                    .accessibilityLabel("Loading Resonate")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .login:
                LoginView(model: LoginViewModel(auth: app.services.auth, feedback: app.feedback) { state in
                    await app.didAuthenticate(state)
                })
            case .onboarding:
                PersonalizeView(model: PersonalizeViewModel(mode: .onboarding, preferences: app.preferences) { preferences in
                    try await app.updatePreferences(preferences)
                })
            case .ready:
                MainTabView(searchModel: DestinationSearchViewModel(services: app.services, feedback: app.feedback))
            }
        }
        .background(Palette.background.ignoresSafeArea())
        .task { await app.bootstrap() }
    }
}

#Preview {
    RootView()
        .environment(AppModel(services: .mock()))
        .preferredColorScheme(.dark)
}
