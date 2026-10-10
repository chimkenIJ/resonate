import SwiftUI

/// Indoor scanning ("Indoors" mockup): walls, doors, and furniture with distances.
struct IndoorScanView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: IndoorScanViewModel

    init(model: IndoorScanViewModel) {
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
            DetectionOverlay(objects: model.snapshot?.objects ?? [], imageSize: model.snapshot?.imageSize)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    BackButton(accessibilityLabel: "Back to home", style: .floating)
                    Spacer()
                    StatusPill(text: model.isSupported ? "Scanning room" : "Not available", accent: .sage)
                }
                .padding(.horizontal, Metrics.screenPadding)
                .padding(.top, 8)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)

                Spacer()

                if model.isSupported {
                    sheet
                } else {
                    SheetCard {
                        Text(model.unsupportedMessage)
                            .appFont(.indoorHeadline)
                            .foregroundStyle(Palette.textPrimary)
                        PillButton(title: "Back to home") { dismiss() }
                    }
                }
            }
        }
        .background(Palette.background)
        .task { await model.run() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .accessibilityAction(.escape) { dismiss() }
    }

    private var sheet: some View {
        SheetCard(spacing: 16) {
            AdaptiveStack(spacing: 16) {
                MiniMapView(items: model.snapshot?.miniMap ?? [])
                Text(model.headline)
                    .appFont(.indoorHeadline)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let description = model.roomDescription {
                Text(description)
                    .appFont(.body)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GuidanceRow(text: model.guidance, systemImage: model.guidanceIcon.systemImage, accent: .sand)

            if let coaching = model.coaching {
                Label(coaching, systemImage: "lightbulb")
                    .appFont(.footnote)
                    .foregroundStyle(Palette.textMuted)
            }

            HStack(spacing: 10) {
                PillButton(title: "Repeat", kind: .secondary, accessibilityHint: "Says what's around you again") {
                    Task { await model.repeatLast() }
                }
                PillButton(title: model.isDescribing ? "Looking…" : "Describe room") {
                    Task { await model.describeRoom() }
                }
                .disabled(model.isDescribing)
            }
        }
    }
}

#Preview {
    let app = AppModel.preview()
    IndoorScanView(model: IndoorScanViewModel(services: app.services, feedback: app.feedback))
        .preferredColorScheme(.dark)
}
