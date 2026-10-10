import Foundation

// Every ViewModel talks to these protocols, never to a concrete service.
// Real implementations arrive in build steps 3–7; Mocks/ has a stand-in for each.

// MARK: - Account and data

/// Auth0 Universal Login. Signing in is optional: guests get every on-device feature.
protocol AuthServicing: AnyObject {
    var state: AuthState { get }
    /// Restores a saved session on launch, if there is one.
    func restoreSession() async -> AuthState
    func signIn() async throws -> UserAccount
    func continueAsGuest()
    func signOut() async throws
    /// Auth0 access token (a JWT) that Supabase accepts as a third-party token.
    func accessToken() async throws -> String?
}

/// The `users` row in Supabase. Created on first sign-in along with the starter folders.
protocol UserProfileServicing: AnyObject {
    func ensureUser(_ account: UserAccount) async throws
}

protocol PreferencesServicing: AnyObject {
    /// Nil until the user has finished onboarding.
    func load() async -> UserPreferences?
    func save(_ preferences: UserPreferences) async throws
}

protocol SavedPlacesServicing: AnyObject {
    func folders() async throws -> [PlaceFolder]
    func places(in folderID: UUID) async throws -> [SavedPlace]
    func createFolder(name: String, accent: Accent, icon: FolderIcon) async throws -> PlaceFolder
    func save(_ place: Place, routeSummary: String?, to folderID: UUID) async throws -> SavedPlace
    func deletePlace(_ id: UUID) async throws
}

// MARK: - Location, search, routing

protocol LocationServicing: AnyObject {
    func requestAuthorization() async -> Bool
    func currentLocation() async throws -> GeoPoint
    /// Continuous fixes for turn-by-turn, also while the phone is locked. Ends when the consumer stops iterating.
    func updates() -> AsyncStream<LocationFix>
    /// Compass heading in degrees, used to say "on your left" while walking.
    func headings() -> AsyncStream<Double>
}

/// Geocoding against the Georgia OSM extract (self-hosted Nominatim via the `geocode` Edge Function).
protocol GeocodingServicing: AnyObject {
    /// Closest matches first. Throws `AppError.outsideGeorgia` or `.noResults`.
    func search(_ query: String, near location: GeoPoint, limit: Int) async throws -> [Place]
}

/// Accessible pedestrian routing (self-hosted Valhalla via the `route` Edge Function).
protocol RoutingServicing: AnyObject {
    func route(from origin: GeoPoint, to destination: Place, preferences: RoutingPreferences) async throws -> Route
}

// MARK: - Voice and feedback

/// The app's voice. ElevenLabs is the only voice: live phrases stream from the API,
/// and safety phrases come from clips cached on the phone so they work offline.
protocol SpeechServicing: AnyObject {
    var isSpeaking: Bool { get }
    var lastSpoken: String? { get }
    /// Speaks `text`. A higher priority interrupts anything lower that is playing.
    /// Returns once the phrase is queued, not when it finishes, so callers never block on audio.
    func speak(_ text: String, priority: SpeechPriority) async
    func stop()
    func repeatLast() async
}

/// Voice input for destination search. Runs on-device so it works without a connection.
/// The microphone is only on between `transcribe()` and `stop()`/`cancel()`, or until a pause.
protocol SpeechRecognitionServicing: AnyObject {
    func requestAuthorization() async -> Bool
    /// Partial transcripts as the user talks. Finishes when they pause or `stop()` is called.
    func transcribe() -> AsyncThrowingStream<String, Error>
    /// Turns the microphone off now; the stream finishes with what was heard.
    func stop()
    /// Turns the microphone off and ends the stream; the result is discarded.
    func cancel()
}

protocol HapticsServicing: AnyObject {
    func play(_ cue: HapticCue)
}

protocol TonesServicing: AnyObject {
    func play(_ cue: ToneCue)
}

// MARK: - Vision

/// Outdoor obstacle detection: camera + YOLO + depth. Fully on-device.
protocol ObstacleDetectionServicing: AnyObject {
    /// `.lidar` on LiDAR phones, `.estimated` when the depth model is used.
    var depthSource: DepthSource { get }
    func frames() -> AsyncStream<DetectionFrame>
    /// JPEG of the latest camera frame, for "Describe the whole scene".
    func latestFrameJPEG() async -> Data?
}

/// Indoor scanning with ARKit LiDAR / RoomPlan.
protocol IndoorScanServicing: AnyObject {
    var isSupported: Bool { get }
    func snapshots() -> AsyncStream<IndoorSnapshot>
    func latestFrameJPEG() async -> Data?
}

/// On-demand descriptions from Gemini, through a Supabase Edge Function.
protocol SceneDescriptionServicing: AnyObject {
    func describe(jpeg: Data, setting: SceneSetting) async throws -> String
}

/// Color recognition module ("Telling colors apart").
protocol ColorRecognitionServicing: AnyObject {
    /// Names the color at the center of the camera frame.
    func readings() -> AsyncStream<ColorReading>
}
