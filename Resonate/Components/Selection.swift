import SwiftUI

/// Multi-select card on the Personalize screen ("Getting around", "Telling colors apart").
struct SelectableCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let accent: Accent
    let isSelected: Bool
    let action: () -> Void

    @ScaledMetric(relativeTo: .headline) private var badge: CGFloat = 48

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                IconBadge(systemImage: systemImage, accent: accent, diameter: min(badge, 72), iconSize: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .appFont(.optionTitle)
                        .foregroundStyle(Palette.textPrimary)
                    Text(subtitle)
                        .appFont(.footnote)
                        .foregroundStyle(Palette.textMuted)
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                checkmark
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: Metrics.optionCardHeight)
            .background(RoundedRectangle(cornerRadius: Metrics.optionRadius).fill(Palette.surface))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.optionRadius)
                    .strokeBorder(isSelected ? accent.color : Palette.surfaceRaised, lineWidth: Metrics.borderWidth)
            )
            .contentShape(RoundedRectangle(cornerRadius: Metrics.optionRadius))
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var checkmark: some View {
        ZStack {
            if isSelected {
                Circle().fill(accent.color)
                Image(systemName: "checkmark")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(Palette.onAccent)
            } else {
                Circle().strokeBorder(Palette.unselectedRing, lineWidth: Metrics.borderWidth)
            }
        }
        .frame(width: 32, height: 32)
        .accessibilityHidden(true)
    }
}

/// Toggle tile for "Voice", "Buzzes", "Tones". Accent fill when on.
struct ToggleTile: View {
    let title: String
    let accent: Accent
    let isOn: Bool
    var accessibilityHint: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .appFont(isOn ? .primaryButton : .secondaryButton)
                .foregroundStyle(isOn ? Palette.onAccent : Palette.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: Metrics.primaryButtonHeight, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: Metrics.innerRadius).fill(isOn ? accent.color : Palette.surface))
                .overlay {
                    if !isOn {
                        RoundedRectangle(cornerRadius: Metrics.innerRadius).strokeBorder(Palette.border, lineWidth: Metrics.borderWidth)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: Metrics.innerRadius))
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityHint(accessibilityHint ?? "")
    }
}

#Preview {
    VStack(spacing: 10) {
        SelectableCard(title: "Getting around", subtitle: "Obstacles and routes", systemImage: "location", accent: .sage, isSelected: true) {}
        SelectableCard(title: "Telling colors apart", subtitle: "Name any color you point at", systemImage: "paintpalette", accent: .mauve, isSelected: false) {}
        HStack(spacing: 10) {
            ToggleTile(title: "Voice", accent: .sand, isOn: true) {}
            ToggleTile(title: "Buzzes", accent: .clay, isOn: true) {}
            ToggleTile(title: "Tones", accent: .slate, isOn: false) {}
        }
    }
    .padding(20)
    .background(Palette.background)
}
