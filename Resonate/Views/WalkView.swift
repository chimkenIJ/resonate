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
                if let route = model.route {
                    RouteMapView(route: route, currentLocation: model.currentLocation)
                        .frame(height: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal, Metrics.screenPadding)
                }
                sheet
            }
        }
        .background(Palette.background)
        .task { await model.run() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .accessibilityAction(.escape) { dismiss() }
    }

    private var topBar: some View {
        HStack {
            BackButton(accessibilityLabel: model.backLabel, style: .floating)
            Spacer()
            StatusPill(text: "Watching ahead", accent: .clay)
            Spacer()
            IconCircleButton(systemImage: "eye", accessibilityLabel: "Describe the whole scene", style: .floating) {
                Task { await model.describeScene() }
            }
            .disabled(model.isDescribing)
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

            HStack(spacing: 10) {
                PillButton(title: "Repeat", kind: .secondary, accessibilityHint: "Says the last message again") {
                    Task { await model.repeatLast() }
                }
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
