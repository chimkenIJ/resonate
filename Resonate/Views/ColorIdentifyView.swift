import SwiftUI

/// "Telling colors apart": no mockup; built from the camera screen pattern.
struct ColorIdentifyView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: ColorIdentifyViewModel

    init(model: ColorIdentifyViewModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        ZStack {
            if model.previewSource.isLive {
                CameraPreviewView(source: model.previewSource)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            } else {
                CameraBackdrop(scene: .room)
            }

            // Aiming ring at the exact middle of the camera view, where the color is read. Decoration only.
            Color.clear
                .overlay {
                    Circle()
                        .strokeBorder(Palette.textPrimary, lineWidth: 4)
                        .frame(width: 88, height: 88)
                        .overlay(Circle().fill(Palette.textPrimary).frame(width: 8, height: 8))
                        .shadow(color: .black.opacity(0.6), radius: 3)
                }
                .ignoresSafeArea()
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                HStack {
                    BackButton(accessibilityLabel: "Back to home", style: .floating)
                    Spacer()
                }
                .padding(.horizontal, Metrics.screenPadding)
                .padding(.top, 8)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)

                Spacer()

                SheetCard(spacing: 16) {
                    HStack(spacing: 16) {
                        RoundedRectangle(cornerRadius: 20)
                            .fill(model.reading.flatMap { Color(hexString: $0.hex) } ?? Palette.surfaceRaised)
                            .frame(width: 72, height: 72)
                            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Palette.border, lineWidth: Metrics.borderWidth))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 8) {
                            if let family = model.reading?.family {
                                TagLabel(text: family, accent: .mauve)
                            }
                            Text(model.reading?.name ?? "Looking…")
                                .appFont(.alertHeadline)
                                .foregroundStyle(Palette.textPrimary)
                        }
                        .accessibilityElement(children: .combine)
                    }

                    GuidanceRow(text: "Point the camera at something. I'll say its color.", systemImage: "hand.point.up.left", accent: .mauve)

                    PillButton(title: "Repeat", kind: .secondary, accessibilityHint: "Says the color again") {
                        Task { await model.repeatLast() }
                    }
                }
            }
        }
        .background(Palette.background)
        .task { await model.run() }
        .accessibilityAction(.escape) { dismiss() }
    }
}

#Preview {
    let app = AppModel.preview()
    ColorIdentifyView(model: ColorIdentifyViewModel(services: app.services, feedback: app.feedback))
        .preferredColorScheme(.dark)
}
