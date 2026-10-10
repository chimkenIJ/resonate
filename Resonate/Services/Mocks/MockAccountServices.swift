import Foundation

final class MockAuthService: AuthServicing {
    private(set) var state: AuthState = .signedOut

    func restoreSession() async -> AuthState { state }

    func signIn() async throws -> UserAccount {
        try await Task.sleep(for: .milliseconds(400))
        let user = UserAccount(id: "auth0|mock-user", name: "Alex", email: "alex@example.com")
        state = .signedIn(user)
        return user
    }

    func continueAsGuest() { state = .guest }

    func signOut() async throws { state = .signedOut }

    func accessToken() async throws -> String? {
        if case .signedIn = state { return "mock-token" }
        return nil
    }
}

final class MockUserProfileService: UserProfileServicing {
    private(set) var ensured: [UserAccount] = []
    func ensureUser(_ account: UserAccount) async throws { ensured.append(account) }
}

final class MockPreferencesService: PreferencesServicing {
    private var stored: UserPreferences?

    init(stored: UserPreferences? = nil) { self.stored = stored }

    func load() async -> UserPreferences? { stored }

    func save(_ preferences: UserPreferences) async throws { stored = preferences }
}

final class MockSavedPlacesService: SavedPlacesServicing {
    private var folderList = SampleData.folders
    private var placesByFolder: [UUID: [SavedPlace]] = [SampleData.classesFolderID: SampleData.classes]

    func folders() async throws -> [PlaceFolder] {
        folderList.map { folder in
            var folder = folder
            if let places = placesByFolder[folder.id] { folder.placeCount = places.count }
            return folder
        }
    }

    func places(in folderID: UUID) async throws -> [SavedPlace] {
        if let places = placesByFolder[folderID] { return places }
        // Fill other sample folders with generic entries so every folder opens to something.
        guard let folder = folderList.first(where: { $0.id == folderID }) else { return [] }
        return SampleData.places.prefix(folder.placeCount).map {
            SavedPlace(id: UUID(), folderID: folderID, place: $0, routeSummary: "\(Int.random(in: 4...18)) min · step-free")
        }
    }

    func createFolder(name: String, accent: Accent, icon: FolderIcon) async throws -> PlaceFolder {
        let folder = PlaceFolder(id: UUID(), name: name, accent: accent, icon: icon, placeCount: 0)
        folderList.append(folder)
        placesByFolder[folder.id] = []
        return folder
    }

    func save(_ place: Place, routeSummary: String?, to folderID: UUID) async throws -> SavedPlace {
        let saved = SavedPlace(id: UUID(), folderID: folderID, place: place, routeSummary: routeSummary)
        placesByFolder[folderID, default: []].append(saved)
        return saved
    }

    func deletePlace(_ id: UUID) async throws {
        for key in placesByFolder.keys {
            placesByFolder[key]?.removeAll { $0.id == id }
        }
    }

    func deleteFolder(_ id: UUID) async throws {
        folderList.removeAll { $0.id == id }
        placesByFolder[id] = nil
    }
}
