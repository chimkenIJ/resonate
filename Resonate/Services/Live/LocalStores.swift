import Foundation
import OSLog

/// Saved places for guests, kept in a JSON file on the phone.
final class LocalSavedPlacesService: SavedPlacesServicing {
    private struct Store: Codable {
        var folders: [PlaceFolder]
        var places: [SavedPlace]
    }

    private let fileURL: URL
    private var store: Store

    init(fileURL: URL = LocalSavedPlacesService.defaultFileURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL), let decoded = try? JSONDecoder().decode(Store.self, from: data) {
            store = decoded
        } else {
            store = Store(folders: PlaceFolder.starterFolders(), places: [])
        }
    }

    static var defaultFileURL: URL {
        URL.applicationSupportDirectory.appending(path: "saved-places.json")
    }

    func folders() async throws -> [PlaceFolder] {
        store.folders.map { folder in
            var folder = folder
            folder.placeCount = store.places.filter { $0.folderID == folder.id }.count
            return folder
        }
    }

    func places(in folderID: UUID) async throws -> [SavedPlace] {
        store.places.filter { $0.folderID == folderID }
    }

    func createFolder(name: String, accent: Accent, icon: FolderIcon) async throws -> PlaceFolder {
        let folder = PlaceFolder(id: UUID(), name: name, accent: accent, icon: icon, placeCount: 0)
        store.folders.append(folder)
        try persist()
        return folder
    }

    func save(_ place: Place, routeSummary: String?, to folderID: UUID) async throws -> SavedPlace {
        guard GeorgiaRegion.contains(place.coordinate) else { throw AppError.outsideGeorgia }
        let saved = SavedPlace(id: UUID(), folderID: folderID, place: place, routeSummary: routeSummary)
        store.places.append(saved)
        try persist()
        return saved
    }

    func deletePlace(_ id: UUID) async throws {
        store.places.removeAll { $0.id == id }
        try persist()
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(store).write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
}

/// Preferences kept on the phone. Used for guests, and as an offline copy for signed-in users.
final class LocalPreferencesService: PreferencesServicing {
    private let defaults: UserDefaults
    private let key = "preferences.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() async -> UserPreferences? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(UserPreferences.self, from: data)
    }

    func save(_ preferences: UserPreferences) async throws {
        defaults.set(try JSONEncoder().encode(preferences), forKey: key)
    }
}

/// Uses Supabase when signed in and the on-phone store for guests.
final class AccountAwareSavedPlacesService: SavedPlacesServicing {
    private let auth: any AuthServicing
    private let remote: any SavedPlacesServicing
    private let local: any SavedPlacesServicing

    init(auth: any AuthServicing, remote: any SavedPlacesServicing, local: any SavedPlacesServicing) {
        self.auth = auth
        self.remote = remote
        self.local = local
    }

    private var active: any SavedPlacesServicing {
        if case .signedIn = auth.state { return remote }
        return local
    }

    func folders() async throws -> [PlaceFolder] { try await active.folders() }
    func places(in folderID: UUID) async throws -> [SavedPlace] { try await active.places(in: folderID) }
    func createFolder(name: String, accent: Accent, icon: FolderIcon) async throws -> PlaceFolder {
        try await active.createFolder(name: name, accent: accent, icon: icon)
    }
    func save(_ place: Place, routeSummary: String?, to folderID: UUID) async throws -> SavedPlace {
        try await active.save(place, routeSummary: routeSummary, to: folderID)
    }
    func deletePlace(_ id: UUID) async throws { try await active.deletePlace(id) }
}

/// Always keeps a copy on the phone (so settings work offline) and syncs to Supabase when signed in.
final class AccountAwarePreferencesService: PreferencesServicing {
    private let auth: any AuthServicing
    private let remote: any PreferencesServicing
    private let local: any PreferencesServicing

    init(auth: any AuthServicing, remote: any PreferencesServicing, local: any PreferencesServicing) {
        self.auth = auth
        self.remote = remote
        self.local = local
    }

    func load() async -> UserPreferences? {
        guard case .signedIn = auth.state else { return await local.load() }
        if let saved = await remote.load() {
            try? await local.save(saved)
            return saved
        }
        // First sign-in after using the app as a guest: carry the choices over.
        guard let onPhone = await local.load() else { return nil }
        try? await remote.save(onPhone)
        return onPhone
    }

    /// The phone copy is what the app runs on, so only that failing is an error. A failed sync
    /// (offline, server trouble) never blocks the user; `load()` uploads the phone copy next launch.
    func save(_ preferences: UserPreferences) async throws {
        try await local.save(preferences)
        guard case .signedIn = auth.state else { return }
        do {
            try await remote.save(preferences)
        } catch {
            Log.data.error("Preferences saved on phone; sync to Supabase failed: \(String(describing: error), privacy: .public)")
        }
    }
}
