import SwiftUI

/// Onboarding (the only step) and the Settings tab share this screen.
struct PersonalizeView: View {
    @Environment(AppModel.self) private var app
    @State private var model: PersonalizeViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(model: PersonalizeViewModel) {
        _model = State(initialValue: model)
    }

    private var isOnboarding: Bool { model.mode == .onboarding }

    var body: some View {
        FillingScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !isOnboarding {
                    ScreenHeader(title: "Settings")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("What should we help with?")
                        .appFont(isOnboarding ? .onboardingTitle : .sectionTitle)
                        .foregroundStyle(Palette.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text("Pick any. You can change this anytime.")
                        .appFont(.body)
                        .foregroundStyle(Palette.textSecondary)
                }

                VStack(spacing: 10) {
                    ForEach(AssistNeed.allCases, id: \.self) { need in
                        SelectableCard(
                            title: need.title,
                            subtitle: need.subtitle,
                            systemImage: need.systemImage,
                            accent: need.accent,
                            isSelected: model.needs.contains(need)
                        ) {
                            model.toggle(need)
                        }
                    }
                }

                Text("How should alerts reach you?")
                    .appFont(.sectionTitle)
                    .foregroundStyle(Palette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, 4)

                channelPicker

                Text("Maps settings")
                    .appFont(.sectionTitle)
                    .accessibilityAddTraits(.isHeader)
                Toggle("Avoid stairs", isOn: $model.routing.avoidSteps)
                Toggle("Prefer tactile paving", isOn: $model.routing.preferTactilePaving)
                Toggle("Prefer audible crossings", isOn: $model.routing.preferAudioSignals)
                Picker("Maximum incline", selection: $model.routing.maxIncline) {
                    Text("Gentle (4%)").tag(0.04)
                    Text("Moderate (8%)").tag(0.08)
                    Text("Steep (15%)").tag(0.15)
                }
                Text("Preferences depend on available map data. Check route warnings before walking.")
                    .appFont(.footnote)
                    .foregroundStyle(Palette.textSecondary)

                Text("Voice")
                    .appFont(.sectionTitle)
                    .accessibilityAddTraits(.isHeader)
                Picker("Speaking voice", selection: $model.voiceID) {
                    Text("Default voice").tag(String?.none)
                    ForEach(model.voices) { voice in
                        Text(voice.name).tag(Optional(voice.id))
                    }
                }
                if model.voices.isEmpty {
                    Text("Connect to load available voices.").appFont(.footnote)
                }


                if let message = model.message {
                    Text(message)
                        .appFont(.body)
                        .foregroundStyle(Accent.rose.color)
                        .onAppear { AccessibilityNotification.Announcement(message).post() }
                }

                if !isOnboarding {
                    accountSection
                }

                Spacer(minLength: 24)

                if isOnboarding {
                    PillButton(title: "Continue", accessibilityHint: "Saves your choices and opens the home screen") {
                        Task { await model.commit() }
                    }
                    .disabled(model.isSaving)
                }
            }
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.top, isOnboarding ? 40 : 16)
            .padding(.bottom, 28)
        }
        .background(Palette.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task { await model.loadVoices(using: app.services.speech) }
    }

    @ViewBuilder
    private var channelPicker: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))
        layout {
            ForEach(AlertChannel.allCases, id: \.self) { channel in
                ToggleTile(title: channel.title, accent: channel.accent, isOn: model.channels.contains(channel)) {
                    model.toggle(channel)
                }
            }
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Account")
                .appFont(.sectionTitle)
                .foregroundStyle(Palette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            switch app.authState {
            case .signedIn(let user):
                Text("Signed in as \(user.name ?? user.email ?? "you").")
                    .appFont(.body)
                    .foregroundStyle(Palette.textSecondary)
                PillButton(title: "Sign out", kind: .secondary) {
                    Task { await app.signOut() }
                }
            case .guest, .signedOut:
                Text("You're using Resonate without an account. Sign in to keep saved places on all your devices.")
                    .appFont(.body)
                    .foregroundStyle(Palette.textSecondary)
                PillButton(title: "Sign in", systemImage: "person.crop.circle") {
                    Task { try? await app.signIn() }
                }
            }
        }
        .padding(.top, 8)
    }
}

#Preview("Onboarding") {
    let app = AppModel.preview(phase: .onboarding)
    PersonalizeView(model: PersonalizeViewModel(mode: .onboarding, preferences: UserPreferences()) { _ in })
        .environment(app)
        .preferredColorScheme(.dark)
}
