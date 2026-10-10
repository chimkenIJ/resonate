import Foundation
import OSLog
import Supabase

/// Builds the Supabase client. Requests are authorized with the Auth0 access token
/// (Supabase third-party auth), so RLS sees the Auth0 user ID in `auth.jwt() ->> 'sub'`.
enum SupabaseClientFactory {
    static func make(config: AppConfig, auth: Auth0AuthService) -> SupabaseClient {
        SupabaseClient(
            supabaseURL: config.supabaseURL,
            supabaseKey: config.supabaseKey,
            options: SupabaseClientOptions(
                auth: .init(accessToken: { try await auth.accessToken() })
            )
        )
    }
}

// MARK: - Rows (snake_case columns ↔ app models)

private nonisolated struct FolderRow: Codable, Sendable {
    var id: UUID
    var name: String
    var accent: String
    var icon: String
    var placeCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, accent, icon
        case placeCount = "place_count"
    }

    var model: PlaceFolder {
        PlaceFolder(
            id: id,
            name: name,
            accent: Accent(rawValue: accent) ?? .slate,
            icon: FolderIcon(rawValue: icon) ?? .star,
            placeCount: placeCount ?? 0
        )
    }
}

private nonisolated struct NewFolderRow: Encodable, Sendable {
    var name: String
    var accent: String
    var icon: String
    var position: Int
}

private nonisolated struct SavedRouteRow: Codable, Sendable {
    var id: UUID
    var folderID: UUID
    var placeID: String
    var name: String
    var address: String
    var latitude: Double
    var longitude: Double
    var routeSummary: String?

    enum CodingKeys: String, CodingKey {
        case id, name, address, latitude, longitude
        case folderID = "folder_id"
        case placeID = "place_id"
        case routeSummary = "route_summary"
    }

    static let columns = "id, folder_id, place_id, name, address, latitude, longitude, route_summary"

    var model: SavedPlace {
        SavedPlace(
            id: id,
            folderID: folderID,
            place: Place(id: placeID, name: name, address: address, coordinate: GeoPoint(latitude: latitude, longitude: longitude)),
            routeSummary: routeSummary
        )
    }
}

private nonisolated struct NewSavedRouteRow: Encodable, Sendable {
    var folderID: UUID
    var placeID: String
    var name: String
    var address: String
    var latitude: Double
    var longitude: Double
    var routeSummary: String?

    enum CodingKeys: String, CodingKey {
        case name, address, latitude, longitude
        case folderID = "folder_id"
        case placeID = "place_id"
        case routeSummary = "route_summary"
    }
}

private nonisolated struct PreferencesRow: Codable, Sendable {
    var userID: String?
    var needs: [String]
    var alertChannels: [String]
    var avoidSteps: Bool
    var maxIncline: Double
    var preferTactilePaving: Bool
    var preferAudioSignals: Bool

    enum CodingKeys: String, CodingKey {
        case needs
        case userID = "user_id"
        case alertChannels = "alert_channels"
        case avoidSteps = "avoid_steps"
        case maxIncline = "max_incline"
        case preferTactilePaving = "prefer_tactile_paving"
        case preferAudioSignals = "prefer_audio_signals"
    }

    init(_ preferences: UserPreferences, userID: String) {
        self.userID = userID
        needs = preferences.needs.map(\.rawValue).sorted()
        alertChannels = preferences.alertChannels.map(\.rawValue).sorted()
        avoidSteps = preferences.routing.avoidSteps
        maxIncline = preferences.routing.maxIncline
        preferTactilePaving = preferences.routing.preferTactilePaving
        preferAudioSignals = preferences.routing.preferAudioSignals
    }

    var model: UserPreferences {
        var preferences = UserPreferences()
        let needs = Set(needs.compactMap(AssistNeed.init(rawValue:)))
        let channels = Set(alertChannels.compactMap(AlertChannel.init(rawValue:)))
        if !needs.isEmpty { preferences.needs = needs }
        if !channels.isEmpty { preferences.alertChannels = channels }
        preferences.routing = RoutingPreferences(
            avoidSteps: avoidSteps,
            maxIncline: maxIncline,
            preferTactilePaving: preferTactilePaving,
            preferAudioSignals: preferAudioSignals
        )
        return preferences
    }
}

private nonisolated struct EnsureUserParams: Encodable, Sendable {
    var pDisplayName: String?
    var pEmail: String?

    enum CodingKeys: String, CodingKey {
        case pDisplayName = "p_display_name"
        case pEmail = "p_email"
    }
}

// MARK: - Services

final class SupabaseUserService: UserProfileServicing {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func ensureUser(_ account: UserAccount) async throws {
        try await client.rpc("ensure_user", params: EnsureUserParams(pDisplayName: account.name, pEmail: account.email)).execute()
    }
}

final class SupabaseSavedPlacesService: SavedPlacesServicing {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func folders() async throws -> [PlaceFolder] {
        let rows: [FolderRow] = try await client
            .from("folders_with_counts")
            .select("id, name, accent, icon, place_count")
            .order("position")
            .order("created_at")
            .execute()
            .value
        return rows.map(\.model)
    }

    func places(in folderID: UUID) async throws -> [SavedPlace] {
        let rows: [SavedRouteRow] = try await client
            .from("saved_routes")
            .select(SavedRouteRow.columns)
            .eq("folder_id", value: folderID)
            .order("created_at")
            .execute()
            .value
        return rows.map(\.model)
    }

    func createFolder(name: String, accent: Accent, icon: FolderIcon) async throws -> PlaceFolder {
        let position = (try? await folders().count) ?? 0
        let row: FolderRow = try await client
            .from("folders")
            .insert(NewFolderRow(name: name, accent: accent.rawValue, icon: icon.rawValue, position: position))
            .select("id, name, accent, icon")
            .single()
            .execute()
            .value
        return row.model
    }

    func save(_ place: Place, routeSummary: String?, to folderID: UUID) async throws -> SavedPlace {
        guard GeorgiaRegion.contains(place.coordinate) else { throw AppError.outsideGeorgia }
        let row: SavedRouteRow = try await client
            .from("saved_routes")
            .insert(NewSavedRouteRow(
                folderID: folderID,
                placeID: place.id,
                name: place.name,
                address: place.address,
                latitude: place.coordinate.latitude,
                longitude: place.coordinate.longitude,
                routeSummary: routeSummary
            ))
            .select(SavedRouteRow.columns)
            .single()
            .execute()
            .value
        return row.model
    }

    func deletePlace(_ id: UUID) async throws {
        try await client.from("saved_routes").delete().eq("id", value: id).execute()
    }
}

final class SupabasePreferencesService: PreferencesServicing {
    private let client: SupabaseClient
    private let auth: any AuthServicing

    init(client: SupabaseClient, auth: any AuthServicing) {
        self.client = client
        self.auth = auth
    }

    func load() async -> UserPreferences? {
        do {
            let rows: [PreferencesRow] = try await client
                .from("preferences")
                .select("needs, alert_channels, avoid_steps, max_incline, prefer_tactile_paving, prefer_audio_signals")
                .limit(1)
                .execute()
                .value
            return rows.first?.model
        } catch {
            Log.data.error("Couldn't load preferences: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func save(_ preferences: UserPreferences) async throws {
        guard case .signedIn(let account) = auth.state else { return }
        try await client
            .from("preferences")
            .upsert(PreferencesRow(preferences, userID: account.id), onConflict: "user_id")
            .execute()
    }
}
