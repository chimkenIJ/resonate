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

    func deleteFolder(_ id: UUID) async throws {
        store.folders.removeAll { $0.id == id }
        store.places.removeAll { $0.folderID == id }
        try persist()
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(store).write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
}

/// Preferences kept on the phone, in a file written atomically on every change (so killing the app
/// right after a change can't lose it). Used for guests, and as the working copy for signed-in users.
final class LocalPreferencesService: PreferencesServicing {
    private struct Stored: Codable {
        var preferences: UserPreferences
        /// True until Supabase confirms it has this version.
        var needsSync: Bool
    }

    private let fileURL: URL
    private let legacyDefaults: UserDefaults
    private let legacyKey = "preferences.v1"

    init(fileURL: URL = URL.applicationSupportDirectory.appending(path: "preferences.json"),
         legacyDefaults: UserDefaults = .standard) {
        self.fileURL = fileURL
        self.legacyDefaults = legacyDefaults
    }

    func load() async -> UserPreferences? { stored()?.preferences }

    func save(_ preferences: UserPreferences) async throws {
        try write(Stored(preferences: preferences, needsSync: true))
    }

    /// Whether the phone has changes the account hasn't received yet.
    var needsSync: Bool { stored()?.needsSync ?? false }

    func markSynced() {
        guard var current = stored(), current.needsSync else { return }
        current.needsSync = false
        try? write(current)
    }

    /// Replaces the phone copy with the account's (already in sync).
    func replace(with preferences: UserPreferences) {
        try? write(Stored(preferences: preferences, needsSync: false))
    }

    private func stored() -> Stored? {
        if let data = try? Data(contentsOf: fileURL), let decoded = try? JSONDecoder().decode(Stored.self, from: data) {
            return decoded
        }
        // Earlier versions kept preferences in UserDefaults.
        if let data = legacyDefaults.data(forKey: legacyKey),
           let preferences = try? JSONDecoder().decode(UserPreferences.self, from: data) {
            return Stored(preferences: preferences, needsSync: true)
        }
        return nil
    }

    private func write(_ value: Stored) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
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
    func deleteFolder(_ id: UUID) async throws { try await active.deleteFolder(id) }
}

/// The phone copy is what the app runs on; Supabase keeps a copy for the account.
/// Changes are saved on the phone first and marked "needs sync" until Supabase confirms them, so a
/// failed sync (offline, server trouble, a missing column) can never roll settings back on next launch.
final class AccountAwarePreferencesService: PreferencesServicing {
    private let auth: any AuthServicing
    private let remote: any PreferencesServicing
    private let local: LocalPreferencesService

    init(auth: any AuthServicing, remote: any PreferencesServicing, local: LocalPreferencesService) {
        self.auth = auth
        self.remote = remote
        self.local = local
    }

    func load() async -> UserPreferences? {
        guard case .signedIn = auth.state else { return await local.load() }
        // Unsynced changes on the phone are newer than the account's copy: keep them and upload them.
        if local.needsSync, let onPhone = await local.load() {
            await upload(onPhone)
            return onPhone
        }
        if let saved = await remote.load() {
            local.replace(with: saved)
            return saved
        }
        // First sign-in after using the app as a guest: carry the choices over.
        guard let onPhone = await local.load() else { return nil }
        await upload(onPhone)
        return onPhone
    }

    func save(_ preferences: UserPreferences) async throws {
        try await local.save(preferences)
        guard case .signedIn = auth.state else { return }
        await upload(preferences)
    }

    /// The upload in progress. Uploads run one at a time, each sending the newest settings on the
    /// phone: two quick changes can't finish out of order and leave the account with the older one.
    private var uploading: Task<Void, Never>?

    private func upload(_ preferences: UserPreferences) async {
        let previous = uploading
        let next = Task { [weak self] in
            await previous?.value
            guard let self, self.local.needsSync, let latest = await self.local.load() else { return }
            do {
                try await self.remote.save(latest)
                // Only "in sync" if nothing changed on the phone while this was uploading.
                if await self.local.load() == latest { self.local.markSynced() }
            } catch {
                Log.data.error("Preferences kept on phone; Supabase sync failed (will retry): \(String(describing: error), privacy: .public)")
            }
        }
        uploading = next
        await next.value
    }
}
