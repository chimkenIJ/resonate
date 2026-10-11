import SwiftUI

/// "Scan the area": camera view with a spoken description of the surroundings. No obstacle alerts.
struct ScanAreaView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var model: ScanAreaViewModel

    init(model: ScanAreaViewModel) {
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
            BackButton(accessibilityLabel: "Back to home", style: .floating)
            Spacer()
        }
        .padding(.horizontal, Metrics.screenPadding)
        .padding(.top, 8)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private var sheet: some View {
        SheetCard {
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

            GuidanceRow(text: model.guidance, systemImage: "iphone", accent: .sand)

            HStack(spacing: 10) {
                PillButton(title: "Repeat", kind: .secondary, accessibilityHint: "Says the last message again") {
                    Task { await model.repeatLast() }
                }
                .disabled(model.sceneDescription == nil)
                PillButton(title: "Scan again", accessibilityHint: "Describes what the camera sees now") {
                    Task { await model.describe() }
                }
                .disabled(model.isStarting || model.isDescribing || !model.cameraAvailable)
            }
        }
    }
}

#Preview {
    let app = AppModel.preview()
    ScanAreaView(model: ScanAreaViewModel(services: app.services, feedback: app.feedback))
        .environment(app)
        .preferredColorScheme(.dark)
}
