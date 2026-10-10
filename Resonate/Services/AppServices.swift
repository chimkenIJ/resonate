import Foundation

/// All services the app uses, injected at the root. Swap `.mock()` for `.live()` per service as each
/// real implementation lands.
struct AppServices {
    let auth: any AuthServicing
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
}
