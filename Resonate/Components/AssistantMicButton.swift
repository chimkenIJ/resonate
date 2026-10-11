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

/// Puts the talk button over the camera screens while the assistant is enabled in Settings. The
/// tab screens have it in the tab bar; the route and folder screens have it in their own top row.
struct AssistantMicOverlay: ViewModifier {
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        content.overlay {
            if app.assistant.isEnabled, app.phase == .ready {
                FloatingTalkButton(assistant: app.assistant)
            }
        }
    }
}

extension View {
    /// Adds the talk button at the top right of a camera screen.
    func assistantMic() -> some View {
        modifier(AssistantMicOverlay())
    }
}

private struct FloatingTalkButton: View {
    let assistant: VoiceAssistant

    var body: some View {
        let diameter: CGFloat = 60
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
            // Top right, level with the Back button, where the route screen has its microphone too.
            .padding(.trailing, Metrics.screenPadding)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    private var caption: String? {
        switch assistant.state {
        case .listening: "Listening…"
        case .thinking: "Thinking…"
        case .off, .speaking: nil
        }
    }
}
