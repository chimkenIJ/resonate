import SwiftUI

/// Getting around indoors ("Indoors" mockup): what's in the way, where the doors are, and guidance to a door.
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
            DetectionOverlay(objects: model.overlayObjects, imageSize: model.snapshot?.imageSize)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    BackButton(accessibilityLabel: "Back to home", style: .floating)
                    Spacer()
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
                MiniMapView(items: model.miniMap)
                Text(model.headline)
                    .appFont(.indoorHeadline)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let nearby = model.nearbyText {
                Label(nearby, systemImage: "dot.radiowaves.left.and.right")
                    .appFont(.body)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Also nearby: \(nearby)")
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

            // The main job indoors: getting to a door. Always here.
            PillButton(title: model.isGuiding ? "Stop guiding" : "Find door",
                       accessibilityHint: model.isGuiding ? "Stops guiding to the door"
                           : "Guides you to the nearest door, step by step, and says how to open it") {
                Task { await model.toggleFindDoor() }
            }

            HStack(spacing: 10) {
                PillButton(title: "Repeat", kind: .secondary, accessibilityHint: "Says the last update again") {
                    Task { await model.repeatLast() }
                }
                PillButton(title: model.isDescribing ? "Looking…" : "Describe room", kind: .secondary) {
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
