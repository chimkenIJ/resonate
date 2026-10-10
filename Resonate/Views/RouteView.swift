import SwiftUI

/// Map with the accessible route on top, summary sheet with turn steps below.
struct RouteView: View {
    @Environment(AppModel.self) private var app
    @State private var model: RouteViewModel
    let backLabel: String

    init(model: RouteViewModel, backLabel: String) {
        _model = State(initialValue: model)
        self.backLabel = backLabel
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                map
                    .frame(height: max(proxy.size.height * 0.42, 220) + proxy.safeAreaInsets.top)
                    .overlay(alignment: .topLeading) {
                        BackButton(accessibilityLabel: backLabel)
                            .padding(.leading, Metrics.screenPadding)
                            .padding(.top, proxy.safeAreaInsets.top + 8)
                    }

                SheetCard(style: .anchored) {
                    ScrollView {
                        sheetContent
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollBounceBehavior(.basedOnSize)

                    if let route = model.route {
                        PillButton(title: "Start walking", systemImage: "location", accessibilityHint: "Opens the camera and starts spoken directions") {
                            app.router.cover = .walk(route)
                        }
                    }
                }
                .padding(.top, -Metrics.sheetRadius)
            }
            .ignoresSafeArea(edges: .top)
        }
        .background(Palette.surface.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .backOnEscape()
        .task {
            if model.route == nil { await model.load() }
        }
        .task { await model.trackLocation() }
    }

    @ViewBuilder
    private var map: some View {
        if let route = model.route {
            RouteMapView(route: route, currentLocation: model.currentLocation)
        } else {
            GridBackground(background: Palette.mapBackground, line: Palette.mapGridLine)
        }
    }

    @ViewBuilder
    private var sheetContent: some View {
        switch model.state {
        case .loading:
            VStack(alignment: .leading, spacing: 14) {
                Text("To \(model.place.name)")
                    .appFont(.caption)
                    .foregroundStyle(Palette.textMuted)
                HStack(spacing: 12) {
                    ProgressView().tint(Palette.textPrimary).controlSize(.large)
                    Text("Finding a step-free route…")
                        .appFont(.bodyLarge)
                        .foregroundStyle(Palette.textPrimary)
                }
                .accessibilityElement(children: .combine)
            }
        case .loaded(let route):
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("To \(route.destination.name)")
                        .appFont(.caption)
                        .foregroundStyle(Palette.textMuted)
                    Text(route.summary)
                        .appFont(.routeSummary)
                        .foregroundStyle(Palette.textPrimary)
                        .accessibilityLabel(route.spokenSummary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)

                FlowLayout {
                    ForEach(route.features, id: \.self) { feature in
                        FeatureChip(text: feature.label, accent: feature.accent)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Along the way: " + route.features.map(\.label).joined(separator: ", "))

                StepList(steps: route.steps)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 16) {
                Text(message)
                    .appFont(.indoorHeadline)
                    .foregroundStyle(Palette.textPrimary)
                PillButton(title: "Try again", kind: .secondary) {
                    Task { await model.load() }
                }
            }
        }
    }
}

#Preview {
    let app = AppModel.preview()
    NavigationStack {
        RouteView(
            model: RouteViewModel(place: SampleData.classes[0].place, services: app.services, feedback: app.feedback, preferences: RoutingPreferences()),
            backLabel: "Back to Classes"
        )
    }
    .environment(app)
    .preferredColorScheme(.dark)
}
