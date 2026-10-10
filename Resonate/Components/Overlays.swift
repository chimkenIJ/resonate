import SwiftUI

/// Bottom sheet container. `.floating` is inset from the edges (camera screens);
/// `.anchored` sits flush with a grab handle (route screen).
struct SheetCard<Content: View>: View {
    enum Style { case floating, anchored }

    var style: Style = .floating
    var spacing: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            if style == .anchored {
                Capsule()
                    .fill(Palette.sheetHandle)
                    .frame(width: 44, height: 5)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
            }
            content
        }
        .padding(.horizontal, 20)
        .padding(.top, style == .anchored ? 12 : 22)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(Palette.surface))
        .overlay(shape.stroke(Palette.border, lineWidth: 1))
        .padding(style == .floating ? 10 : 0)
    }

    private var shape: some Shape {
        UnevenRoundedRectangle(
            topLeadingRadius: Metrics.sheetRadius,
            bottomLeadingRadius: style == .floating ? Metrics.sheetRadius : 0,
            bottomTrailingRadius: style == .floating ? Metrics.sheetRadius : 0,
            topTrailingRadius: Metrics.sheetRadius
        )
    }
}

/// Labeled boxes drawn over the camera feed. Purely visual for sighted helpers;
/// VoiceOver ignores it because the spoken alert carries the same information.
struct DetectionOverlay: View {
    let objects: [DetectedObject]
    /// Size of the upright camera image the boxes refer to. With it, boxes line up with an
    /// aspect-fill camera preview; without it (mock frames), boxes stretch to the view.
    var imageSize: CGSize? = nil
    /// Distance from the top of the screen that the back button and status pill cover.
    var labelTopLimit: CGFloat = 140

    /// Maps a normalized image rect to view points, matching aspect-fill cropping.
    static func viewRect(for box: CGRect, imageSize: CGSize?, in viewSize: CGSize) -> CGRect {
        guard let imageSize, imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(x: box.minX * viewSize.width, y: box.minY * viewSize.height,
                          width: box.width * viewSize.width, height: box.height * viewSize.height)
        }
        let scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let shown = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(x: (viewSize.width - shown.width) / 2, y: (viewSize.height - shown.height) / 2)
        return CGRect(x: origin.x + box.minX * shown.width, y: origin.y + box.minY * shown.height,
                      width: box.width * shown.width, height: box.height * shown.height)
    }

    var body: some View {
        GeometryReader { proxy in
            ForEach(objects) { object in
                let rect = Self.viewRect(for: object.boundingBox, imageSize: imageSize, in: proxy.size)
                let accent = object.category.accent
                let dashed = object.category == .dropOff

                RoundedRectangle(cornerRadius: dashed ? 12 : 18)
                    .strokeBorder(accent.color, style: StrokeStyle(lineWidth: 4, dash: dashed ? [10, 6] : []))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)

                // Labels sit above their box, or just inside it when that would hide them under the top buttons.
                TagLabel(text: object.overlayText, accent: accent)
                    .fixedSize()
                    .position(x: rect.minX, y: rect.minY - 22 < labelTopLimit ? rect.minY + 24 : rect.minY - 22)
                    .offset(x: 50)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Faint square grid behind the Saved places screen and the map placeholder.
struct GridBackground: View {
    var background: Color = Palette.background
    var line: Color = Palette.gridLine
    var spacing: CGFloat = 26

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x: CGFloat = 0
            while x <= size.width {
                path.addRect(CGRect(x: x, y: 0, width: 1, height: size.height))
                x += spacing
            }
            var y: CGFloat = 0
            while y <= size.height {
                path.addRect(CGRect(x: 0, y: y, width: size.width, height: 1))
                y += spacing
            }
            context.fill(path, with: .color(line))
        }
        .background(background)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// Small top-down map in the indoor sheet.
struct MiniMapView: View {
    let items: [MiniMapItem]
    var size: CGFloat = 96

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20).fill(Palette.surfaceRaised)
            GeometryReader { proxy in
                ForEach(items) { item in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(item.category.accent.color)
                        .frame(width: item.rect.width * proxy.size.width, height: item.rect.height * proxy.size.height)
                        .rotationEffect(.radians(item.rotation))
                        .position(x: item.rect.midX * proxy.size.width, y: item.rect.midY * proxy.size.height)
                }
                Circle()
                    .stroke(Palette.sheetHandle, style: StrokeStyle(lineWidth: 1.5, dash: [3, 4]))
                    .frame(width: proxy.size.width * 0.375, height: proxy.size.width * 0.375)
                    .position(x: proxy.size.width / 2, y: proxy.size.height * 0.81)
                Image(systemName: "triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.textPrimary)
                    .position(x: proxy.size.width / 2, y: proxy.size.height * 0.81)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .accessibilityHidden(true)
    }
}

#Preview {
    ZStack(alignment: .bottom) {
        Color(hex: 0x23262B).ignoresSafeArea()
        DetectionOverlay(objects: SampleData.outdoorFrames[0].objects)
        SheetCard {
            HStack {
                TagLabel(text: "Heads up", accent: .clay)
                Spacer()
                Text("Spoken + 2 buzzes").appFont(.footnote).foregroundStyle(Palette.textMuted)
            }
            Text("Bike parked ahead, slightly left.").appFont(.alertHeadline).foregroundStyle(Palette.textPrimary)
            HStack(spacing: 16) {
                MiniMapView(items: SampleData.indoorSnapshots[0].miniMap)
                GuidanceRow(text: "Step right to pass.", systemImage: "arrow.turn.up.right")
            }
        }
    }
}
