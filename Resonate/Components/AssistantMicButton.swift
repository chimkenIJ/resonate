import SwiftUI

/// The voice assistant's push-to-talk button. Hold it and talk; let go to send. With VoiceOver or
/// Switch Control, activate it once to start and again to send.
struct AssistantTalkButton: View {
    let assistant: VoiceAssistant
    var diameter: CGFloat = 72

    @State private var isPressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let listening = assistant.state == .listening
        Image(systemName: icon)
            .font(.system(size: diameter * 0.36, weight: .semibold))
            .foregroundStyle(listening ? Palette.background : Palette.onAccent)
            .symbolEffect(.pulse, isActive: listening && !reduceMotion)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(listening ? Palette.textPrimary : Accent.sand.color))
            .overlay(Circle().stroke(Palette.background, lineWidth: 5))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            .scaleEffect(listening && !reduceMotion ? 1.08 : 1)
            .animation(reduceMotion ? nil : .spring(duration: 0.2), value: listening)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPressed else { return }
                        isPressed = true
                        assistant.beginTalking()
                    }
                    .onEnded { _ in
                        isPressed = false
                        assistant.finishTalking()
                    }
            )
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Talk to assistant")
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(listening ? "Double-tap to send." : "Hold while you talk, then let go. Or double-tap, talk, and double-tap again.")
            .accessibilityAction { assistant.toggleTalking() }
            .accessibilityShowsLargeContentViewer {
                Image(systemName: "mic.fill")
                Text("Talk to assistant")
            }
    }

    private var icon: String {
        switch assistant.state {
        case .off: "mic"
        case .listening: "mic.fill"
        case .thinking: "ellipsis"
        case .speaking: "speaker.wave.2.fill"
        }
    }

    private var accessibilityValue: String {
        switch assistant.state {
        case .off: ""
        case .listening: "Listening"
        case .thinking: "Working on it"
        case .speaking: "Speaking"
        }
    }
}

/// Puts the talk button over screens without the tab bar (pushed screens and camera screens),
/// in a fixed spot on the right edge, while the assistant is enabled in Settings.
struct AssistantMicOverlay: ViewModifier {
    /// False on the tab stacks: their main screens have the button in the tab bar.
    let onEveryScreen: Bool
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        content.overlay {
            let router = app.router
            let path = router.paths[router.tab] ?? []
            let tabBarHidden = onEveryScreen || !path.isEmpty
            // The route screen has its own microphone at the top, over the map.
            let hasOwnButton = !onEveryScreen && { if case .route = path.last { true } else { false } }()
            if app.assistant.isEnabled, app.phase == .ready, tabBarHidden, !hasOwnButton {
                FloatingTalkButton(assistant: app.assistant)
            }
        }
    }
}

extension View {
    /// Adds the floating talk button where the tab bar isn't showing.
    func assistantMic(onEveryScreen: Bool = false) -> some View {
        modifier(AssistantMicOverlay(onEveryScreen: onEveryScreen))
    }
}

private struct FloatingTalkButton: View {
    let assistant: VoiceAssistant

    @ScaledMetric(relativeTo: .title2) private var size: CGFloat = 68

    var body: some View {
        GeometryReader { geometry in
            let diameter = min(size, Metrics.iconButtonMaxSize)
            let inset = Metrics.screenPadding + diameter / 2

            AssistantTalkButton(assistant: assistant, diameter: diameter)
                .overlay(alignment: .trailing) {
                    if let caption {
                        Text(caption)
                            .appFont(.caption)
                            .foregroundStyle(Palette.textPrimary)
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(Palette.surfaceRaised))
                            .offset(x: -(diameter + 10))
                            .allowsHitTesting(false)
                            .accessibilityHidden(true) // the button's value says the same thing
                    }
                }
                // Always the same spot on the right edge, so it's easy to find and can't be moved by accident.
                .position(x: geometry.size.width - inset, y: min(max(geometry.size.height * 0.72, inset), geometry.size.height - inset))
        }
        .ignoresSafeArea(.keyboard)
    }

    private var caption: String? {
        switch assistant.state {
        case .listening: "Listening…"
        case .thinking: "Thinking…"
        case .off, .speaking: nil
        }
    }
}
