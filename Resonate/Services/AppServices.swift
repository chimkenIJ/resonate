import Foundation

/// All services the app uses, injected at the root. `.live(config:)` uses real services where they
/// exist so far and mocks for the rest; `.mock()` is fully offline for previews and development.
struct AppServices {
    let auth: any AuthServicing
    let users: any UserProfileServicing
    let preferences: any PreferencesServicing
    let savedPlaces: any SavedPlacesServicing
    let location: any LocationServicing
    let geocoding: any GeocodingServicing
    let routing: any RoutingServicing
    let speech: any SpeechServicing
    let speechRecognition: any SpeechRecognitionServicing
    let haptics: any HapticsServicing
    let tones: any TonesServicing
    let obstacleDetection: any ObstacleDetectionServicing
    let indoorScan: any IndoorScanServicing
    let sceneDescription: any SceneDescriptionServicing
    let colorRecognition: any ColorRecognitionServicing

    static func mock() -> AppServices {
        let location = MockLocationService()
        return AppServices(
            auth: MockAuthService(),
            users: MockUserProfileService(),
            preferences: MockPreferencesService(),
            savedPlaces: MockSavedPlacesService(),
            location: location,
            geocoding: MockGeocodingService(),
            routing: MockRoutingService(),
            speech: MockSpeechService(),
            speechRecognition: MockSpeechRecognitionService(),
            haptics: MockHapticsService(),
            tones: MockTonesService(),
            obstacleDetection: MockObstacleDetectionService(),
            indoorScan: MockIndoorScanService(),
            sceneDescription: MockSceneDescriptionService(),
            colorRecognition: MockColorRecognitionService()
        )
    }

    /// Everything real: accounts, saved places, location, search, routing, the ElevenLabs voice,
    /// voice input, obstacle detection, indoor scanning, Gemini descriptions, haptics, and tones.
    /// Only color recognition is still a mock.
    static func live(config: AppConfig) -> AppServices {
        let mock = AppServices.mock()
        let auth = Auth0AuthService(config: config)
        let client = SupabaseClientFactory.make(config: config, auth: auth)
        let functions = EdgeFunctionClient(baseURL: config.functionsURL, apiKey: config.functionsKey, auth: auth)
        return AppServices(
            auth: auth,
            users: SupabaseUserService(client: client),
            preferences: AccountAwarePreferencesService(
                auth: auth,
                remote: SupabasePreferencesService(client: client, auth: auth),
                local: LocalPreferencesService()
            ),
            savedPlaces: AccountAwareSavedPlacesService(
                auth: auth,
                remote: SupabaseSavedPlacesService(client: client),
                local: LocalSavedPlacesService()
            ),
            location: LiveLocationService(),
            geocoding: LiveGeocodingService(client: functions),
            routing: LiveRoutingService(client: functions),
            speech: ElevenLabsSpeechService(client: functions),
            speechRecognition: LiveSpeechRecognitionService(),
            haptics: LiveHapticsService(),
            tones: LiveTonesService(),
            obstacleDetection: LiDARObstacleDetectionService.isSupported
                ? LiDARObstacleDetectionService() : CameraObstacleDetectionService(),
            indoorScan: RoomScanService(),
            sceneDescription: GeminiSceneDescriptionService(client: functions),
            colorRecognition: mock.colorRecognition
        )
    }

    /// Live services when ResonateConfig.plist is filled in, otherwise mocks.
    static func makeDefault() -> AppServices {
        if let config = AppConfig.load() { return .live(config: config) }
        print("[Resonate] ResonateConfig.plist missing or incomplete; running on mock services.")
        return .mock()
    }
}
