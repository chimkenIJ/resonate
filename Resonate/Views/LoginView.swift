import SwiftUI

/// No mockup; built in the app's style. Signing in is optional.
struct LoginView: View {
    @State private var model: LoginViewModel

    init(model: LoginViewModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        FillingScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                IconBadge(systemImage: "waveform", accent: .sand, diameter: 96, iconSize: 42)
                    .padding(.top, 40)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Resonate")
                        .appFont(.screenTitle)
                        .foregroundStyle(Palette.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text("Hear what's around you, and find routes that work for you.")
                        .appFont(.bodyLarge)
                        .foregroundStyle(Palette.textSecondary)
                }

                Spacer(minLength: 24)

                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .appFont(.body)
                        .foregroundStyle(Accent.rose.color)
                }

                VStack(spacing: 12) {
                    PillButton(
                        title: model.isWorking ? "Signing in…" : "Sign in",
                        systemImage: "person.crop.circle",
                        accessibilityLabel: "Sign in or create an account"
                    ) {
                        Task { await model.signIn() }
                    }
                    .disabled(model.isWorking)

                    PillButton(title: "Continue without account", kind: .secondary) {
                        Task { await model.continueAsGuest() }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Obstacle alerts and routes work without an account. Your saved places stay on this phone until you sign in.")
                    Text("Resonate is an extra aid. It doesn't replace the tools you already use to get around.")
                }
                .appFont(.footnote)
                .foregroundStyle(Palette.textMuted)
            }
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.bottom, 28)
        }
        .background(Palette.background.ignoresSafeArea())
    }
}

#Preview {
    let app = AppModel.preview(phase: .login)
    LoginView(model: LoginViewModel(auth: app.services.auth, feedback: app.feedback) { _ in })
        .preferredColorScheme(.dark)
}
