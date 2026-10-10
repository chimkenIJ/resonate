import Foundation

/// A geocoded destination.
nonisolated struct Place: Identifiable, Codable, Hashable, Sendable {
    /// Stable ID from the geocoder (for example "osm:node:123").
    var id: String
    var name: String
    var address: String
    var coordinate: GeoPoint
    /// Straight-line distance from the user when the search ran.
    var distanceMeters: Double?
}

/// Icons a saved-places folder can use. Raw values are SF Symbol names.
nonisolated enum FolderIcon: String, CaseIterable, Codable, Hashable, Sendable {
    case classes = "graduationcap"
    case home = "house"
    case food = "cup.and.saucer"
    case gym = "waveform.path.ecg"
    case friends = "person.2"
    case errands = "cart"
    case work = "briefcase"
    case health = "cross.case"
    case star = "star"

    var systemImage: String { rawValue }

    var spokenName: String {
        switch self {
        case .classes: "School"
        case .home: "Home"
        case .food: "Food"
        case .gym: "Gym"
        case .friends: "Friends"
        case .errands: "Shopping"
        case .work: "Work"
        case .health: "Health"
        case .star: "Star"
        }
    }
}

/// A folder of saved places ("Classes", "Food", ...).
nonisolated struct PlaceFolder: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var accent: Accent
    var icon: FolderIcon
    var placeCount: Int

    var countText: String { placeCount == 1 ? "1 route" : "\(placeCount) routes" }

    /// Folders every new user starts with. Matches `ensure_user()` in the Supabase migration.
    static func starterFolders() -> [PlaceFolder] {
        [
            PlaceFolder(id: UUID(), name: "Classes", accent: .slate, icon: .classes, placeCount: 0),
            PlaceFolder(id: UUID(), name: "Home", accent: .sand, icon: .home, placeCount: 0),
            PlaceFolder(id: UUID(), name: "Food", accent: .clay, icon: .food, placeCount: 0),
            PlaceFolder(id: UUID(), name: "Gym", accent: .mauve, icon: .gym, placeCount: 0),
            PlaceFolder(id: UUID(), name: "Friends", accent: .rose, icon: .friends, placeCount: 0),
            PlaceFolder(id: UUID(), name: "Errands", accent: .sage, icon: .errands, placeCount: 0),
        ]
    }
}

/// A place saved into a folder, with the last known route summary.
nonisolated struct SavedPlace: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var folderID: UUID
    var place: Place
    /// For example "12 min · step-free". Nil until a route has been computed.
    var routeSummary: String?
}
