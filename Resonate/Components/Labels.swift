import SwiftUI

/// Rounded accent label: "Heads up", "Bike · 2 m", "Stairs avoided".
struct TagLabel: View {
    let text: String
    var accent: Accent? = nil

    var body: some View {
        Text(text)
            .appFont(.label)
            .foregroundStyle(Palette.onAccent)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: Metrics.tagRadius).fill(accent?.color ?? Palette.textPrimary))
    }
}

/// Fully rounded feature chip on the route sheet: "Curb ramps", "Audio crossings".
struct FeatureChip: View {
    let text: String
    let accent: Accent

    var body: some View {
        Text(text)
            .appFont(.chip)
            .foregroundStyle(Palette.onAccent)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(accent.color))
    }
}

/// Status capsule over the camera: "● Watching ahead", "● Scanning room".
struct StatusPill: View {
    let text: String
    let accent: Accent

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(accent.color)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Text(text)
                .appFont(.label)
                .foregroundStyle(Palette.textPrimary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(Capsule().fill(Palette.surface))
        .accessibilityElement(children: .combine)
    }
}

/// Title and subtitle at the top of a screen ("Saved places / 6 folders").
struct ScreenHeader: View {
    let title: String
    var subtitle: String? = nil
    var style: AppTextStyle = .screenTitle

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .appFont(style)
                .foregroundStyle(Palette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .appFont(.bodyLarge)
                    .foregroundStyle(Palette.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Icon + sentence on a raised row: "Step right to pass. Curb drop in 4 m."
struct GuidanceRow: View {
    let text: String
    let systemImage: String
    var accent: Accent = .sand

    @ScaledMetric(relativeTo: .body) private var badge: CGFloat = 44

    var body: some View {
        HStack(spacing: 14) {
            IconBadge(systemImage: systemImage, accent: accent, diameter: min(badge, 64), iconSize: 20)
            Text(text)
                .appFont(.body)
                .foregroundStyle(Palette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: Metrics.innerRadius).fill(Palette.surfaceRaised))
        .accessibilityElement(children: .combine)
    }
}

/// Turn-by-turn list on the route sheet.
struct StepList: View {
    let steps: [RouteStep]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                if index > 0 {
                    Rectangle()
                        .fill(Palette.divider)
                        .frame(height: 1)
                        .padding(.horizontal, 16)
                        .accessibilityHidden(true)
                }
                StepRow(step: step)
            }
        }
        .background(RoundedRectangle(cornerRadius: Metrics.innerRadius).fill(Palette.surfaceRaised))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.innerRadius))
    }
}

struct StepRow: View {
    let step: RouteStep

    @ScaledMetric(relativeTo: .body) private var badge: CGFloat = 40

    var body: some View {
        HStack(spacing: 14) {
            IconBadge(systemImage: step.maneuver.systemImage, accent: step.maneuver.accent, diameter: min(badge, 60), iconSize: 18)
            Text(step.instruction)
                .appFont(.bodyBold)
                .foregroundStyle(Palette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if step.distanceMeters > 0 {
                Text(DistanceText.short(step.distanceMeters))
                    .appFont(.caption)
                    .foregroundStyle(Palette.textPrimary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(step.distanceMeters > 0
            ? "\(step.instruction), \(DistanceText.spoken(step.distanceMeters))"
            : step.instruction)
    }
}

/// Wraps chips onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > maxWidth, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 16) {
        ScreenHeader(title: "Saved places", subtitle: "6 folders")
        HStack { TagLabel(text: "Heads up", accent: .clay); StatusPill(text: "Watching ahead", accent: .clay) }
        FlowLayout {
            FeatureChip(text: "Curb ramps", accent: .sand)
            FeatureChip(text: "Audio crossings", accent: .mauve)
            FeatureChip(text: "1 elevator", accent: .sage)
        }
        GuidanceRow(text: "Step right to pass. Curb drop in 4 m.", systemImage: "arrow.turn.up.right")
        StepList(steps: Array(SampleData.route(to: SampleData.places[0]).steps.prefix(2)))
    }
    .padding(20)
    .background(Palette.background)
}
