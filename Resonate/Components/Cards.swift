import SwiftUI

/// Horizontal row that becomes a vertical stack at accessibility text sizes, so large text never gets squeezed.
struct AdaptiveStack<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: spacing * 0.75))
            : AnyLayout(HStackLayout(alignment: .center, spacing: spacing))
        layout { content }
    }
}

/// Round accent badge holding an icon in dark ink.
struct IconBadge: View {
    let systemImage: String
    let accent: Accent
    var diameter: CGFloat = 72
    var iconSize: CGFloat = 30

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: iconSize, weight: .semibold))
            .foregroundStyle(Palette.onAccent)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(accent.color))
            .accessibilityHidden(true)
    }
}

/// Home screen tile: "Scan the area", "Scan indoors", "Saved places".
struct FeatureTile: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let accent: Accent
    var minHeight: CGFloat = Metrics.tileHeight
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AdaptiveStack(spacing: 20) {
                IconBadge(systemImage: systemImage, accent: accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .appFont(.tileTitle)
                        .foregroundStyle(Palette.textPrimary)
                    Text(subtitle)
                        .appFont(.body)
                        .foregroundStyle(Palette.textSecondary)
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, minHeight: minHeight, maxHeight: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Metrics.tileRadius).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: Metrics.tileRadius).strokeBorder(accent.color, lineWidth: Metrics.borderWidth))
            .contentShape(RoundedRectangle(cornerRadius: Metrics.tileRadius))
        }
        .buttonStyle(.pressable)
    }
}

/// The big off-white "Where do you want to go?" card. Tapping starts voice input.
struct VoiceSearchCard: View {
    var title = "Where do you want to go?"
    var subtitle = "Tap, then say a place"
    var isListening = false
    let action: () -> Void

    @ScaledMetric(relativeTo: .title) private var micSize: CGFloat = 80

    var body: some View {
        Button(action: action) {
            AdaptiveStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .appFont(.searchPrompt)
                        .foregroundStyle(Palette.onAccent)
                    Text(isListening ? "Listening…" : subtitle)
                        .appFont(.bodyLarge)
                        .foregroundStyle(Palette.onLightSecondary)
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: isListening ? "waveform" : "mic")
                    .font(.system(size: 32, weight: .semibold))
                    .symbolEffect(.variableColor.iterative, isActive: isListening)
                    .foregroundStyle(Palette.textPrimary)
                    .frame(width: min(micSize, 110), height: min(micSize, 110))
                    .background(Circle().fill(Palette.background))
                    .accessibilityHidden(true)
            }
            .padding(24)
            .frame(maxWidth: .infinity, minHeight: Metrics.searchCardHeight, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Metrics.searchCardRadius).fill(Palette.textPrimary))
            .contentShape(RoundedRectangle(cornerRadius: Metrics.searchCardRadius))
        }
        .buttonStyle(.pressable)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isListening ? "Listening. Say a place." : "\(title) \(subtitle)")
        .accessibilityAddTraits(.isButton)
    }
}

/// Folder in the Saved places grid, drawn like a paper folder.
struct FolderCard: View {
    let folder: PlaceFolder
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topLeading) {
                decoration
                VStack(alignment: .leading, spacing: 2) {
                    Image(systemName: folder.icon.systemImage)
                        .font(.system(size: 22, weight: .semibold))
                        .padding(.bottom, 14)
                        .accessibilityHidden(true)
                    Text(folder.name)
                        .appFont(.rowTitle)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    Text(folder.countText)
                        .appFont(.caption)
                }
                .foregroundStyle(Palette.onAccent)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, minHeight: Metrics.folderCardHeight - 42, alignment: .bottomLeading)
                .background(
                    UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 20, bottomTrailingRadius: 20, topTrailingRadius: 20)
                        .fill(folder.accent.color)
                )
                .padding(.top, 42)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(folder.name), \(folder.countText)")
        .accessibilityHint("Opens this folder")
        .accessibilityAddTraits(.isButton)
    }

    /// Tab and paper sheets peeking out of the folder. Decoration only.
    private var decoration: some View {
        ZStack(alignment: .topLeading) {
            UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12)
                .fill(folder.accent.tabColor)
                .frame(width: 76, height: 30)
                .offset(y: 18)
            RoundedRectangle(cornerRadius: 10)
                .fill(Palette.paperLight)
                .frame(width: 80, height: 60)
                .rotationEffect(.degrees(-7))
                .offset(x: 16, y: 4)
            if folder.placeCount >= 3 {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Palette.paperDark)
                    .frame(width: 80, height: 56)
                    .rotationEffect(.degrees(6))
                    .offset(x: 70, y: 8)
            }
        }
        .accessibilityHidden(true)
    }
}

/// 92pt row in a folder list: place name + "12 min · step-free".
struct PlaceRow: View {
    let title: String
    let subtitle: String?
    var accessibilityHint = "Shows the route"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .appFont(.rowTitle)
                        .foregroundStyle(Palette.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .appFont(.rowSubtitle)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Palette.textMuted)
                    .accessibilityHidden(true)
            }
            .padding(.leading, 22)
            .padding(.trailing, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: Metrics.placeRowHeight)
            .background(RoundedRectangle(cornerRadius: Metrics.rowRadius).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: Metrics.rowRadius).strokeBorder(Palette.rowBorder, lineWidth: Metrics.borderWidth))
            .contentShape(RoundedRectangle(cornerRadius: Metrics.rowRadius))
        }
        .buttonStyle(.pressable)
        .accessibilityHint(accessibilityHint)
    }
}

/// Destination search result with "Go" and "Save". No mockup; built from the folder row style.
struct DestinationResultRow: View {
    let place: Place
    let onGo: () -> Void
    let onSave: () -> Void

    private var distanceText: String? {
        place.distanceMeters.map { DistanceText.short($0) + " away" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(place.name)
                    .appFont(.rowTitle)
                    .foregroundStyle(Palette.textPrimary)
                Text([distanceText, place.address].compactMap { $0 }.joined(separator: " · "))
                    .appFont(.rowSubtitle)
                    .foregroundStyle(Palette.textSecondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenSummary)
            .accessibilityAddTraits(.isHeader)

            HStack(spacing: 10) {
                PillButton(title: "Go", systemImage: "location", accessibilityLabel: "Go to \(place.name)", action: onGo)
                PillButton(title: "Save", systemImage: "folder.badge.plus", kind: .secondary, accessibilityLabel: "Save \(place.name)", action: onSave)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Metrics.rowRadius).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: Metrics.rowRadius).strokeBorder(Palette.rowBorder, lineWidth: Metrics.borderWidth))
        .accessibilityElement(children: .contain)
    }

    private var spokenSummary: String {
        let distance = place.distanceMeters.map { ", \(DistanceText.spoken($0)) away" } ?? ""
        return "\(place.name)\(distance). \(place.address)"
    }
}

#Preview {
    ScrollView {
        VStack(spacing: 20) {
            VoiceSearchCard {}
            FeatureTile(title: "Scan the area", subtitle: "Tells you what's around you", systemImage: "eye", accent: .sand) {}
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible())], spacing: 22) {
                ForEach(SampleData.folders.prefix(2)) { FolderCard(folder: $0) {} }
            }
            PlaceRow(title: "Calculus", subtitle: "12 min · step-free") {}
            DestinationResultRow(place: SampleData.places[5]) {} onSave: {}
        }
        .padding(20)
    }
    .background(Palette.background)
}
