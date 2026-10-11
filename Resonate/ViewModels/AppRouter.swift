import SwiftUI

enum AppTab: String, CaseIterable, Hashable {
    case home, search, saved, settings

    var title: String {
        switch self {
        case .home: "Home"
        case .search: "Search"
        case .saved: "Saved"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home: "house"
        case .search: "magnifyingglass"
        case .saved: "folder"
        case .settings: "gearshape"
        }
    }

    var selectedIcon: String {
        switch self {
        case .home: "house.fill"
        case .search: "magnifyingglass"
        case .saved: "folder.fill"
        case .settings: "gearshape.fill"
        }
    }

    /// Used in back button labels: "Back to search results".
    var backTitle: String {
        switch self {
        case .home: "home"
        case .search: "search results"
        case .saved: "saved places"
        case .settings: "settings"
        }
    }
}

/// Screens pushed inside a tab.
enum AppRoute: Hashable {
    case folder(PlaceFolder)
    case route(Place)
}

/// Full-screen camera experiences, shown above the tab bar.
enum CoverRoute: Identifiable, Hashable {
    /// Obstacle detection. With a route it also gives turn-by-turn directions.
    case walk(Route?)
    /// Describes what's around the user. No obstacle detection.
    case scanArea
    case indoor
    case colors

    var id: String {
        switch self {
        case .walk(let route): "walk-\(route?.id.uuidString ?? "free")"
        case .scanArea: "scan-area"
        case .indoor: "indoor"
        case .colors: "colors"
        }
    }
}

/// Navigation state: selected tab, each tab's stack, and the camera cover.
@Observable
final class AppRouter {
    var tab: AppTab = .home { didSet { if tab != oldValue { onNavigate() } } }
    var paths: [AppTab: [AppRoute]] = [:] { didSet { if paths != oldValue { onNavigate() } } }
    var cover: CoverRoute? { didSet { if cover != oldValue { onNavigate() } } }
    private let onNavigate: @MainActor () -> Void

    init(onNavigate: @escaping @MainActor () -> Void = {}) {
        self.onNavigate = onNavigate
    }
    /// Incremented to ask the search screen to start listening.
    private(set) var listenRequest = 0

    /// The tab bar hides on pushed screens so their bottom buttons have room.
    var isTabBarVisible: Bool { (paths[tab] ?? []).isEmpty }

    func binding(for tab: AppTab) -> Binding<[AppRoute]> {
        Binding(
            get: { self.paths[tab] ?? [] },
            set: { self.paths[tab] = $0 }
        )
    }

    func push(_ route: AppRoute) {
        paths[tab, default: []].append(route)
    }

    func openSearch(listen: Bool) {
        tab = .search
        paths[.search] = []
        if listen { listenRequest += 1 }
    }

    func backLabel(for route: AppRoute, in tab: AppTab) -> String {
        let path = paths[tab] ?? []
        if let index = path.lastIndex(of: route), index > 0, case .folder(let folder) = path[index - 1] {
            return "Back to \(folder.name)"
        }
        return "Back to \(tab.backTitle)"
    }

    func reset() {
        tab = .home
        paths = [:]
        cover = nil
    }
}
