import SwiftUI

/// Outdoor navigation ("Detect" mockup): camera with obstacle boxes and a spoken alert sheet.
struct WalkView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var model: WalkViewModel

    init(model: WalkViewModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        ZStack {
            if model.previewSource.isLive {
                CameraPreviewView(source: model.previewSource)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            } else {
                CameraBackdrop(scene: .street)
            }
            DetectionOverlay(objects: model.objects, imageSize: model.imageSize)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer()
                sheet
            }
        }
        .background(Palette.background)
        .task {
            app.sceneDescriber = model
            await model.run()
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            if app.sceneDescriber === model { app.sceneDescriber = nil }
        }
        .accessibilityAction(.escape) { dismiss() }
    }

    private var topBar: some View {
        HStack {
            BackButton(accessibilityLabel: model.backLabel, style: .floating)
            Spacer()
        }
        .padding(.horizontal, Metrics.screenPadding)
        .padding(.top, 8)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private var sheet: some View {
        SheetCard {
            HStack {
                TagLabel(text: model.tagText, accent: model.tagAccent)
                Spacer()
                Text(model.deliveryText)
                    .appFont(.footnote)
                    .foregroundStyle(Palette.textMuted)
            }

            Text(model.headline)
                .appFont(.alertHeadline)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if let description = model.sceneDescription {
                Text(description)
                    .appFont(.body)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GuidanceRow(text: model.guidance, systemImage: model.guidanceIcon.systemImage, accent: .sand)

            if let signal = model.signal {
                GuidanceRow(text: signal.display, systemImage: signal.systemImage, accent: signal.accent)
            }

            HStack(spacing: 10) {
                PillButton(title: "Repeat", kind: .secondary, accessibilityHint: "Says the last message again") {
                    Task { await model.repeatLast() }
                }
                .disabled(model.isStarting)
                if model.isNavigating {
                    PillButton(title: "Route", accessibilityHint: "Shows the whole route") {
                        dismiss()
                    }
                } else {
                    PillButton(title: "Where to?", accessibilityHint: "Search for a place to walk to") {
                        dismiss()
                        app.router.openSearch(listen: true)
                    }
                }
                // Between start and end, finding a door is still one small tap away.
                if !model.showsFindDoor {
                    IconCircleButton(systemImage: "door.left.hand.open", accessibilityLabel: "Find door",
                                     accessibilityHint: "Looks for the nearest door with the camera and says how to open it") {
                        Task { await model.findDoor() }
                    }
                    .disabled(model.isDescribing)
                }
            }

            // Only when a door is likely: at the start (getting out of a building), indoors, or near the destination.
            if model.showsFindDoor {
                PillButton(title: "Find door", kind: .secondary,
                           accessibilityHint: "Looks for the nearest door with the camera and says how to open it") {
                    Task { await model.findDoor() }
                }
                .disabled(model.isDescribing)
            }
        }
    }
}

#Preview {
    let app = AppModel.preview()
    WalkView(model: WalkViewModel(mode: .navigating(SampleData.route(to: SampleData.places[0])), services: app.services, feedback: app.feedback))
        .environment(app)
        .preferredColorScheme(.dark)
}
