import SwiftUI

/// 60pt round icon button: back, settings, add folder, describe scene.
struct IconCircleButton: View {
    enum Style {
        /// Surface fill with a 2pt border (Home settings, Saved back/add).
        case bordered
        /// Surface fill, no border (floating over the camera).
        case floating
        /// Accent fill with dark icon.
        case accent(Accent)
    }

    let systemImage: String
    let accessibilityLabel: String
    var accessibilityHint: String? = nil
    var style: Style = .bordered
    let action: () -> Void

    @ScaledMetric(relativeTo: .title2) private var size: CGFloat = Metrics.iconButtonSize
    @ScaledMetric(relativeTo: .title2) private var iconSize: CGFloat = 22

    var body: some View {
        let diameter = min(size, Metrics.iconButtonMaxSize)
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: min(iconSize, 34), weight: .bold))
                .foregroundStyle(foreground)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(background))
                .overlay {
                    if case .bordered = style {
                        Circle().strokeBorder(Palette.border, lineWidth: Metrics.borderWidth)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint ?? "")
    }

    private var background: Color {
        if case .accent(let accent) = style { return accent.color }
        return Palette.surface
    }

    private var foreground: Color {
        if case .accent = style { return Palette.onAccent }
        return Palette.textPrimary
    }
}

/// Back button. Dismisses the current screen unless a custom action is given.
struct BackButton: View {
    /// What VoiceOver says, for example "Back to home".
    let accessibilityLabel: String
    var style: IconCircleButton.Style = .bordered
    var action: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        IconCircleButton(systemImage: "chevron.left", accessibilityLabel: accessibilityLabel, style: style) {
            if let action { action() } else { dismiss() }
        }
    }
}

/// Full-width capsule button, at least 64pt tall.
struct PillButton: View {
    enum Kind {
        /// Off-white fill, dark text ("Start walking", "Continue").
        case primary
        /// Raised surface fill, light text ("Repeat").
        case secondary
        /// Accent fill, dark text.
        case accent(Accent)
    }

    let title: String
    var systemImage: String? = nil
    var kind: Kind = .primary
    var accessibilityLabel: String? = nil
    var accessibilityHint: String? = nil
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 20, weight: .bold))
                        .accessibilityHidden(true)
                }
                Text(title)
                    .appFont(isSecondary ? .secondaryButton : .primaryButton)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: Metrics.primaryButtonHeight)
            .background(Capsule().fill(background))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(accessibilityLabel ?? title)
        .accessibilityHint(accessibilityHint ?? "")
    }

    private var isSecondary: Bool {
        if case .secondary = kind { return true }
        return false
    }

    private var background: Color {
        switch kind {
        case .primary: Palette.textPrimary
        case .secondary: Palette.surfaceRaised
        case .accent(let accent): accent.color
        }
    }

    private var foreground: Color {
        isSecondary ? Palette.textPrimary : Palette.onAccent
    }
}

#Preview {
    VStack(spacing: 16) {
        HStack {
            BackButton(accessibilityLabel: "Back to home")
            Spacer()
            IconCircleButton(systemImage: "plus", accessibilityLabel: "Add a folder") {}
            IconCircleButton(systemImage: "eye", accessibilityLabel: "Describe the whole scene", style: .floating) {}
        }
        PillButton(title: "Start walking", systemImage: "location") {}
        HStack(spacing: 10) {
            PillButton(title: "Repeat", kind: .secondary) {}
            PillButton(title: "Describe room") {}
        }
    }
    .padding(20)
    .background(Palette.background)
}

private struct EscapeDismiss: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.accessibilityAction(.escape) { dismiss() }
    }
}

extension View {
    /// The VoiceOver "scrub" gesture (two-finger Z) goes back, since the system nav bar is hidden.
    func backOnEscape() -> some View {
        modifier(EscapeDismiss())
    }
}
