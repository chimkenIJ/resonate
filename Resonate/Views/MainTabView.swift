import SwiftUI

/// Tabs (Home, Search, Saved, Settings) with a camera button in the middle.
/// Each tab has its own navigation stack; camera screens open full screen above everything.
/// When the voice assistant is on in Settings, its microphone replaces the camera button in the
/// tab bar (the camera tools stay on Home) and floats over screens without the tab bar.
struct MainTabView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var router = app.router

        NavigationStack(path: router.binding(for: router.tab)) {
            root(for: router.tab)
                // On each tab's main screen (pushed screens have their own bottom buttons), so the
                // screen's layout knows exactly how much room the tab bar takes.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    ResonateTabBar(selection: $router.tab, assistant: app.assistant.isEnabled ? app.assistant : nil) {
                        router.cover = .walk(nil)
                    }
                }
                .navigationDestination(for: AppRoute.self) { destination($0, in: router.tab) }
        }
        .id(router.tab)
        .assistantMic()
        .fullScreenCover(item: $router.cover) { cover in
            coverView(cover)
                .assistantMic(onEveryScreen: true)
                .environment(app)
        }
    }

    @ViewBuilder
    private func root(for tab: AppTab) -> some View {
        switch tab {
        case .home:
            HomeView()
        case .search:
            DestinationSearchView(model: app.search)
        case .saved:
            SavedPlacesView(model: SavedPlacesViewModel(service: app.services.savedPlaces))
        case .settings:
            PersonalizeView(model: PersonalizeViewModel(mode: .settings, preferences: app.preferences) { preferences in
                try await app.updatePreferences(preferences)
            })
        }
    }

    @ViewBuilder
    private func destination(_ route: AppRoute, in tab: AppTab) -> some View {
        switch route {
        case .folder(let folder):
            FolderView(model: FolderViewModel(folder: folder, service: app.services.savedPlaces, feedback: app.feedback))
        case .route(let place):
            RouteView(
                model: RouteViewModel(place: place, services: app.services, feedback: app.feedback, preferences: app.preferences.routing),
                backLabel: app.router.backLabel(for: route, in: tab)
            )
        }
    }

    @ViewBuilder
    private func coverView(_ cover: CoverRoute) -> some View {
        switch cover {
        case .walk(let route):
            WalkView(model: WalkViewModel(
                mode: route.map { .navigating($0) } ?? .freeWalk,
                services: app.services,
                feedback: app.feedback,
                routingPreferences: app.preferences.routing
            ))
        case .scanArea:
            ScanAreaView(model: ScanAreaViewModel(services: app.services, feedback: app.feedback))
        case .indoor:
            IndoorScanView(model: IndoorScanViewModel(services: app.services, feedback: app.feedback))
        case .colors:
            ColorIdentifyView(model: ColorIdentifyViewModel(services: app.services, feedback: app.feedback))
        }
    }
}

#Preview {
    let app = AppModel.preview()
    MainTabView()
        .environment(app)
        .preferredColorScheme(.dark)
}
