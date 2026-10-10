import SwiftUI

/// Onboarding (the only step) and the Settings tab share this screen.
struct PersonalizeView: View {
    @Environment(AppModel.self) private var app
    @State private var model: PersonalizeViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isChoosingVoice = false

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

                Text("What should we help with?")
                    .appFont(isOnboarding ? .onboardingTitle : .sectionTitle)
                    .foregroundStyle(Palette.textPrimary)
                    .accessibilityAddTraits(.isHeader)

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

                sectionTitle("Map settings")
                row {
                    ToggleTile(title: "Avoid stairs", accent: .clay, isOn: model.routing.avoidSteps,
                               accessibilityHint: "Turns avoiding stairs on or off") {
                        model.routing.avoidSteps.toggle()
                    }
                    ToggleTile(title: "Tactile paving", accent: .slate, isOn: model.routing.preferTactilePaving,
                               accessibilityHint: "Prefers routes with bumpy curb strips you can feel") {
                        model.routing.preferTactilePaving.toggle()
                    }
                    ToggleTile(title: "Audible crossings", accent: .mauve, isOn: model.routing.preferAudioSignals,
                               accessibilityHint: "Prefers crossings with signals that beep or speak") {
                        model.routing.preferAudioSignals.toggle()
                    }
                }

                sectionTitle("How steep can hills be?")
                row {
                    ForEach(HillLimit.allCases) { limit in
                        ToggleTile(title: limit.title, accent: limit.accent,
                                   isOn: HillLimit(incline: model.routing.maxIncline) == limit,
                                   accessibilityHint: limit.explanation) {
                            model.routing.maxIncline = limit.incline
                        }
                    }
                }

                sectionTitle("Voice")
                PlaceRow(title: model.currentVoiceName, subtitle: "Tap to hear and change the voice",
                         accessibilityHint: "Opens the list of voices") {
                    isChoosingVoice = true
                }
                .accessibilityLabel("Voice: \(model.currentVoiceName)")


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
        .sheet(isPresented: $isChoosingVoice) {
            VoicePickerView(model: model)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .appFont(.sectionTitle)
            .foregroundStyle(Palette.textPrimary)
            .accessibilityAddTraits(.isHeader)
            .padding(.top, 4)
    }

    /// Side by side (1 | 2 | 3); stacked at the largest text sizes so nothing gets cut off.
    @ViewBuilder
    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 10))
        layout { content() }
            .fixedSize(horizontal: false, vertical: true) // equal heights when a label wraps
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
