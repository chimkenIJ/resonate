# Resonate: app context and code map

Read this file before changing the app. It explains the product, the main execution paths, and where to find the code. It is a source-code snapshot reviewed on **2026-10-10**, not a statement that every service has been deployed or tested on a phone.

The working tree includes a new Claude voice assistant and Siri shortcuts. Some changes from earlier development sessions are absent from the current files. The section on requested behavior distinguishes those requirements from what is implemented here. Recheck the relevant source and `git status` before editing; preserve other contributors' work.

## What the app does

Resonate is a native iPhone accessibility app, initially focused on blind and low-vision users. It helps users find destinations, plan walking routes, detect nearby obstacles, scan indoor rooms, identify colors, and receive spoken, vibration, and tone feedback. Users choose the accessibility features and feedback channels they need.

Outdoor place and accessibility data is scoped to **Atlanta and Georgia, USA**, using OpenStreetMap. Valhalla calculates outdoor routes. Indoor scanning uses the phone's camera and LiDAR through Apple frameworks. MapKit displays maps; it is not the current routing backend.

The app supplements a cane or guide dog. OSM tags, GPS fixes, object recognition, and distance estimates are incomplete or approximate; do not describe a route or scene as guaranteed safe.

The backend is **Supabase**, not Tiger Data. Authentication is **Auth0**. ElevenLabs provides the app voice, Gemini provides requested scene descriptions, and Claude powers the optional voice assistant. There is no OpenRouteService integration or Core ML depth model for non-LiDAR phones in the current service wiring.

## Architecture and startup

The app uses MVVM and SwiftUI Observation (`@Observable`, `@State`, `@Bindable`, and environment injection).

```text
ResonateApp
  └─ AppModel
       ├─ AppServices: protocol-backed live services or mocks
       ├─ FeedbackCenter: shared speech, vibration, and tone delivery
       ├─ AppRouter: tabs, navigation stacks, and camera covers
       ├─ DestinationSearchViewModel: shared Search tab and assistant results
       └─ VoiceAssistant: optional conversation loop and app actions
            ↓
         RootView → Login / Onboarding / MainTabView
```

- [ResonateApp.swift](Resonate/ResonateApp.swift) creates the model, injects it into SwiftUI, and registers the same instance with `AppDependencyManager` for Siri/Shortcuts.
- [AppModel.swift](Resonate/ViewModels/AppModel.swift) owns authentication state, preferences, onboarding, shared services, search, and the assistant. Its phases are `launching`, `login`, `onboarding`, and `ready`.
- `bootstrap()` prewarms cached safety speech in the background, restores authentication, and selects the next phase.
- Signed-in users call `ensureUser()` to create their database row and starter folders. Failure is logged and retried on a later launch rather than blocking local features.
- Onboarding completion for an account is stored under `onboarding.<Auth0 user ID>` in UserDefaults.
- [AppServices.swift](Resonate/Services/AppServices.swift) is the service factory. `makeDefault()` selects live services only when `AppConfig.load()` succeeds; otherwise it selects mocks.
- [ServiceProtocols.swift](Resonate/Services/Protocols/ServiceProtocols.swift) defines service contracts, including camera preview sources and assistant replies. View models should use these contracts.

The app deployment target is iOS 17. The Xcode project uses Swift 5 language mode with default MainActor isolation and Approachable Concurrency. Some syntax requires a newer Swift compiler than the language-mode number suggests. Keep UI state on the main actor. Spell actor isolation explicitly on stored async UI callbacks when needed; an earlier login crash was traced to an incorrectly converted async callback under these settings.

## Screens and navigation

[AppRouter.swift](Resonate/ViewModels/AppRouter.swift) defines:

- `AppTab`: `home`, `search`, `saved`, `settings`.
- `AppRoute`: a saved-place folder or destination route, pushed within a tab's stack.
- `CoverRoute`: `walk(Route?)`, `indoor`, or `colors`, presented full screen.
- `listenRequest`: a counter that asks Search to begin voice input once for each request.

[MainTabView.swift](Resonate/Views/MainTabView.swift) builds the tab roots, pushed screens, and camera covers. The camera button opens free-walk mode; a non-nil route opens navigation mode.

| Screen | Main responsibility | State / logic |
| --- | --- | --- |
| [RootView](Resonate/Views/RootView.swift) | Select login or main app; present onboarding | `AppModel.phase` |
| [LoginView](Resonate/Views/LoginView.swift) | Auth0 sign-in or guest access | `LoginViewModel` |
| [PersonalizeView](Resonate/Views/PersonalizeView.swift) | Onboarding and Settings; needs, feedback, routing, voice, assistant, account | `PersonalizeViewModel`, `AppModel` |
| [HomeView](Resonate/Views/HomeView.swift) | Entry points to search and camera tools | `AppRouter` |
| [DestinationSearchView](Resonate/Views/DestinationSearchView.swift) | Typed or spoken destination lookup; results; save/go actions | `DestinationSearchViewModel` |
| [RouteView](Resonate/Views/RouteView.swift) | Route map, duration, accessibility features, steps, Start walking | `RouteViewModel` |
| [WalkView](Resonate/Views/WalkView.swift) | Outdoor obstacle detection and optional turn-by-turn guidance | `WalkViewModel`, `NavigationEngine` |
| [IndoorScanView](Resonate/Views/IndoorScanView.swift) | Room layout, obstacles, guidance, requested room description | `IndoorScanViewModel` |
| [ColorIdentifyView](Resonate/Views/ColorIdentifyView.swift) | Camera color identification and Repeat | `ColorIdentifyViewModel` |
| [SavedPlacesView](Resonate/Views/SavedPlacesView.swift) | Folder list, creation, deletion | `SavedPlacesViewModel` |
| [FolderView](Resonate/Views/FolderView.swift) | Places within a folder; remove places or folder | `FolderViewModel` |
| [SaveToFolderView](Resonate/Views/SaveToFolderView.swift) | Save a destination into a folder | `SaveToFolderViewModel` |
| [AddFolderView](Resonate/Views/AddFolderView.swift) | Folder name, color, icon | `AddFolderViewModel` |
| [VoicePickerView](Resonate/Views/VoicePickerView.swift) | Preview a voice, then save the selection | `PersonalizeViewModel` |

The three folder-related models are in [SavedPlacesViewModels.swift](Resonate/ViewModels/SavedPlacesViewModels.swift). Shared buttons, cards, camera previews, overlays, maps, and the tab bar live in `Resonate/Components/`. `Theme/Metrics.swift`, `Palette.swift`, and `Typography.swift` define the visual system. Reuse those components and values.

## Main feature paths

### Authentication and saved data

```text
LoginView → LoginViewModel → Auth0AuthService → Auth0 Universal Login
AppModel → SupabaseUserService.ensureUser() → Postgres ensure_user()
Saved-place / preference models → account-aware services → local files or Supabase
```

- [Auth0AuthService.swift](Resonate/Services/Live/Auth0AuthService.swift) uses Auth0's CredentialsManager and Keychain for credentials. Guest mode is remembered locally.
- [SupabaseServices.swift](Resonate/Services/Live/SupabaseServices.swift) builds the Supabase client with Auth0 access tokens and implements user, folder, destination, and preference access.
- [LocalStores.swift](Resonate/Services/Live/LocalStores.swift) stores guest saved places and preferences in local JSON files. Preferences are written locally first, with pending sync state, so failed remote saves do not discard changes.
- Account-aware services select local guest data or account data. Do not assume that signing in uploads every guest folder; check the implementation before changing migration behavior.
- Auth0 and Supabase are separate services: Auth0 supplies the identity token; Supabase stores application data and enforces ownership with row-level security.

### Search and outdoor routing

```text
DestinationSearchViewModel → LiveGeocodingService → geocode Edge Function → Nominatim
RouteViewModel / WalkViewModel → LiveRoutingService → route Edge Function → Valhalla
                                                         └─ PostGIS accessibility lookups
```

- [MapServices.swift](Resonate/Services/Live/MapServices.swift) contains `EdgeFunctionClient`, `LiveGeocodingService`, `LiveRoutingService`, and JSON coding helpers.
- The client attaches the functions key and an Auth0 token when available, maps HTTP errors to app errors, and reports local-server connectivity problems.
- `DestinationSearchViewModel` obtains GPS with a timeout, checks the Georgia region, and requests up to five places. `searchQuietly()` updates the same results for the assistant without reading them aloud itself.
- The current [geocode function](supabase/functions/geocode/index.ts) searches nearby first, widens to Georgia, removes out-of-state results, and sorts by distance. It currently calls Nominatim; a local `osm_places` search index is not present in the checked-in migration files.
- [route/index.ts](supabase/functions/route/index.ts) uses Valhalla's pedestrian routing and accessibility preferences. It decodes the route shape, maps maneuver types, and adds crossing notes, route features, avoided stairs, and hazards from OSM/PostGIS.
- [NavigationEngine.swift](Resonate/Models/NavigationEngine.swift) is the pure, on-device GPS state machine. It handles approaching/reached maneuvers, arrival, hazards, off-route delay, and recovery. Preserve its GPS-accuracy handling and test timing changes.
- `RouteStep.distanceMeters` is the length **from that maneuver to the next**. `RouteStep.start` is where that maneuver happens. Do not interpret the segment length as an instruction to turn immediately.
- Region checks currently use a Georgia bounding box; it includes small portions of neighboring states. The backend supports replacing the service-area boundary with an exact outline.

### Camera and indoor processing

| Files | Responsibility |
| --- | --- |
| `Services/Live/Vision/ObstacleDetectionServices.swift` | LiDAR-backed and camera-only obstacle streams; permission requests; snapshots |
| `ObjectDetector.swift`, `Models/ObjectCatalog.swift` | YOLO11s through Vision/Core ML; recognized labels and approximate object sizes |
| `DepthReader.swift`, `Models/TerrainAnalyzer.swift` | LiDAR depth, coordinate conversion, terrain and obstacle analysis |
| `RoomScanService.swift`, `Models/IndoorComposer.swift` | RoomPlan elements converted into indoor snapshots and guidance |
| `Models/IndoorMap.swift`, `IndoorNavigator.swift` | Temporary room map (camera/depth finds kept 3 min, people 4 s, merged and forgotten when seen gone); a silent 360° mapping step first; then what's in front, left to right, from the map plus live vision, measured from the walking direction. Indoors never says where to go (no routing); "Find door" says where doors are |
| `LiveColorRecognitionService.swift`, `Models/ColorNamer.swift` | Sample camera colors and map them to spoken names |
| `Models/Alerts.swift`, `Detection.swift`, `Indoor.swift` | Detection, severity, guidance, and indoor data types |
| `Components/CameraPreviewView.swift`, `Overlays.swift` | Camera session presentation and detection overlays |

Live service wiring uses LiDAR obstacle detection when supported, otherwise camera-based detection with object-size distance estimates. RoomPlan scanning requires a supported LiDAR device. Color recognition is implemented as a live service in this checkout, despite an older README statement that it is mocked.

The YOLO model is in `Resonate/Resources/Models/YOLO11s.mlpackage`. Read [its model notes](Resonate/Resources/Models/README.md) before replacing or redistributing it. Do not alter camera/depth coordinate transforms or distance calibration casually.

### Speech and other feedback

- [SpeechQueue.swift](Resonate/Models/SpeechQueue.swift) decides what's said next: one sentence at a time; safety cuts in at once; a newer message at least as important replaces the rest of the current one; only one less important message waits. Priorities: info < snapshot (scene description) < navigation < safety.
- [FeedbackCenter.swift](Resonate/Services/Feedback/FeedbackCenter.swift) applies feedback preferences and deduplicates obstacle alerts. With voice on, buzzes and tones are only for immediate danger; without voice, turns and proximity still buzz. It routes speech, haptics, tones, one-time notices, and Repeat.
- [ElevenLabsSpeechService.swift](Resonate/Services/Live/ElevenLabsSpeechService.swift) manages voice selection, cached clips, a playback queue, priorities, previews, interruption, and device speech fallback.
- `SpeechClipStore` caches clips in Application Support by a hash of their text and voice version. Safety phrases can be assembled from cached fragments.
- [SpeechPhrases.swift](Resonate/Models/SpeechPhrases.swift) defines prewarmed safety fragments; keep phrase generation and fragment coverage tests consistent.
- [LiveFeedbackServices.swift](Resonate/Services/Live/LiveFeedbackServices.swift) implements vibration and tones.
- `SpeechServicing.speak()` currently returns when the phrase is **queued**, not when playback finishes. Awaiting it does not prove the user has finished hearing the message.
- [describe/index.ts](supabase/functions/describe/index.ts) sends a requested JPEG to Gemini for a short description. The code does not store the photo.

### Claude voice assistant and Siri

```text
AssistantMicButton / Siri intent → VoiceAssistant
  → Apple speech recognition → ClaudeAssistantService → assistant Edge Function
  → Claude text/tool replies → local app actions → FeedbackCenter / ElevenLabs
```

- [VoiceAssistant.swift](Resonate/ViewModels/VoiceAssistant.swift) is push-to-talk: hold the mic to talk, let go to send (VoiceOver: activate to start, again to send). It owns `off`, `listening`, `thinking`, and `speaking` states. It keeps conversation messages and known place IDs in memory, runs each tool call as an App Intent, and waits for speech before listening again. It does not show what the user said.
- The enable setting is local UserDefaults state under `assistant.enabled`. Each press is one request; the conversation is kept between presses, tool rounds are capped, and history is bounded. Siri's Talk to Resonate listens once until the user pauses.
- [ClaudeAssistantService.swift](Resonate/Services/Live/ClaudeAssistantService.swift) sends Messages API content using plain, sorted JSON. [JSONValue.swift](Resonate/Models/JSONValue.swift) preserves content blocks, including thinking/tool blocks; do not run these through snake-case conversion.
- [assistant/index.ts](supabase/functions/assistant/index.ts) owns the system prompt, provider configuration, request limits, and tool schemas. Keep its tool definitions synchronized with the intents in [AssistantToolIntents.swift](Resonate/Intents/AssistantToolIntents.swift), matched by `toolName`.
- Allowed tools are `open_screen`, `search_places`, `show_route`, `start_navigation`, `open_camera_mode`, `close_screen`, `list_saved_places`, `save_place`, `change_setting`, and `stop_listening`. Route/save actions resolve IDs from places the app actually knows.
- [AssistantMicButton.swift](Resonate/Components/AssistantMicButton.swift) replaces the tab bar's middle camera button while the assistant is on (camera tools remain on Home) and sits at the top right of every other screen: the route and folder screens place it in their own top rows, and camera screens get it as an overlay on the full-screen cover. It cannot be dragged.
- [ResonateIntents.swift](Resonate/Intents/ResonateIntents.swift) defines Talk to Resonate, Find a Place, and Start Walking intents and the shortcut phrases. The tool intents are also available in Shortcuts; from Siri, place parameters take a name and use the closest match, while Claude must pass a known place ID. They act on the shared AppModel registered at startup.

The assistant is distinct from Search's microphone. Both use the same speech-recognition service, so concurrent listening and the app hearing its own speech need careful handling. The assistant intentionally navigates between screens; distinguish its ongoing conversation from stale narration belonging to a closed screen.

## Backend structure

| Location | Purpose |
| --- | --- |
| `supabase/config.toml` | Local Supabase and Edge Function configuration |
| `supabase/functions/_shared/http.ts` | CORS, JSON/error responses, request validation, upstream requests |
| `_shared/georgia.ts` | Georgia region checks and geographic helpers |
| `_shared/polyline.ts` | Valhalla polyline decoding |
| `functions/geocode/` | Place lookup; returns `places` |
| `functions/route/` | Walking route; returns `route` |
| `functions/speak/` | ElevenLabs speech as MP3; voice-list requests |
| `functions/describe/` | Gemini scene descriptions |
| `functions/assistant/` | Claude conversation and tool declarations |
| `server/docker-compose.yml` | Valhalla, Nominatim, and Caddy containers |
| `server/Caddyfile` | Map-server gateway configuration |
| `server/scripts/dev_up.sh`, `dev_down.sh` | Start/stop the local development backend |
| `server/scripts/load_access_points.sh` | Import accessibility tags from the Georgia OSM extract |
| `auth0/actions/add-supabase-role.js` | Auth0 post-login action supplying the Supabase role claim |

The schema migrations create `users`, `preferences`, `folders`, `saved_routes`, `service_areas`, and `osm_access_points`, plus helper functions/views. The `saved_routes` name is historical: it stores **saved destinations in folders**, not complete recorded journeys. Personal rows are owned by the Auth0 `sub`; public OSM/service-area data is readable separately. Preserve RLS policies and validation of saved coordinates.

Current migrations are the initial schema, OSM accessibility points, and the `voice_id` preference column. [rls_check.sql](supabase/tests/rls_check.sql) checks ownership isolation, anonymous access, and area restrictions using rolled-back fixtures.

## Local setup and common failures

1. Open `Resonate.xcodeproj`, let Swift Package Manager resolve packages, select the Resonate scheme and a simulator or iPhone, and run with **⌘R**. Auth0.swift and supabase-swift are the direct app package dependencies.
2. For live services, copy `config/ResonateConfig.example.plist` to `Resonate/Resources/ResonateConfig.plist` and fill in `SupabaseURL`, `SupabaseKey`, `Auth0Domain`, `Auth0ClientID`, and `Auth0Audience`.
3. Keep the plist valid XML with string values. Validate it with `plutil -lint Resonate/Resources/ResonateConfig.plist`. Rebuild after changing it; it is read from the app bundle, not directly from the source folder.
4. Follow [BACKEND_SETUP.md](docs/BACKEND_SETUP.md) for Auth0/Supabase and [MAP_SERVER.md](docs/MAP_SERVER.md) for maps and functions. Check examples against the actual bundle ID and configuration rather than copying old identifiers blindly.
5. For a local Mac backend, use Docker Desktop, Node/npm, and Python 3. Configure the gitignored `supabase/functions/.env.local`, then run `server/scripts/dev_up.sh` from the repo root. Stop with `server/scripts/dev_down.sh`.

Relevant function settings are `VALHALLA_URL`, `NOMINATIM_URL`, `RESONATE_UPSTREAM_KEY`, `UPSTREAM_USER_AGENT`, `ELEVENLABS_API_KEY`, optional `ELEVENLABS_VOICE_ID`, `GEMINI_API_KEY`, optional `GEMINI_MODEL`, `ANTHROPIC_API_KEY`, and optional `ANTHROPIC_MODEL` / `ANTHROPIC_EFFORT`. Check each function for which settings it actually requires. There is no separate local ElevenLabs or Claude model server: local Edge Functions call those hosted APIs.

The app's optional `FunctionsURL` / `FunctionsKey` override its function gateway without changing the hosted account database. An iPhone uses `http://<your-mac-hostname>.local:54321/functions/v1`; a simulator can use `http://127.0.0.1:54321/functions/v1`. The phone and Mac need a reachable network connection, the Mac must stay awake, and iOS Local Network access must be allowed. The local functions key must belong to the local Supabase instance.

| Symptom | Check first |
| --- | --- |
| Signed in as sample user Alex | Missing/invalid/bundled plist, mock services, debug launch override, or an older installed app |
| Auth0 callback URL mismatch | The full allowed URL and the Auth0 application matching `Auth0ClientID` |
| Apple bundle ID registration failure | Development-team signing ownership; separate teams may need separate bundle IDs |
| Search fails but route works | Nominatim URL, upstream response/logs, and request identification; do not substitute invented places |
| Voice/assistant does not work | Server-side provider key, function deployment/runtime, provider model configuration, local gateway reachability |
| Preferences disappear after a failed sync | Local-first storage and pending sync handling in `LocalStores.swift` |

Auth0 callback/logout URLs have the form `BUNDLE_ID://AUTH0_DOMAIN/ios/BUNDLE_ID/callback`. Teammates can use one Auth0 application with multiple allowed URLs for their development builds. Changing the iOS bundle ID also affects Apple signing; an Auth0 account does not grant access to an Apple development team.

Never put third-party secret keys or a Supabase service-role key in the iOS plist, this guide, logs, or committed files. The plist, local `.env` files, and Xcode user data are gitignored. `project.pbxproj` is still a tracked project file even though `.gitignore` lists it; a local `skip-worktree` setting may hide edits. Do not remove the project file from Git as a shortcut for per-laptop signing differences.

## Requested behavior and current gaps

These are established product preferences from this development session. They are not claims that the current checkout implements them all:

- Recent searches should be saved and displayed newest first. Autocomplete suggestions were deliberately removed.
- Search should not automatically read every result or error while the user is entering another query. Results and errors must remain accessible on screen.
- Toggle speech should be a concise `Name on/off`, with one short explanation only when useful. “Avoid stairs on” needs no extra explanation. The requested custom-control speech should avoid redundant “selected” / “button” announcements.
- Closing a screen should stop its current/queued speech. Late route, scene, or save responses must not restart that screen's narration.
- Walking startup should say **“Beginning route”**, followed by **“Beginning to scan the area. Point the phone in front of you.”** It should not reread the full route overview or the first two departure commands.
- Scanning should wait for the startup message to finish playing. A turn farther along the route should be announced based on position, not immediately at startup.
- Prefer the smallest complete functional change. Do not update unrelated documentation, signing settings, or backend services unless the task requires it. This guide should be updated when architecture changes.

**Current source gaps:** Search still has automatic result/error speech and no recent-history storage; `WalkViewModel` still queues the full summary and first departure instruction; `SpeechServicing` has no playback-completion wait; `AppRouter` has no centralized speech-stop hook; selection controls still use selected traits. The former local place-index migration/importer and search/speech-lifecycle tests are not present in this checkout. Verify these areas before claiming the requested behavior is already working. This documentation task does not fix those gaps.

## Tests and verification

Run tests in Xcode with **⌘U**, or select a simulator with the command line:

```sh
xcodebuild -project Resonate.xcodeproj -scheme Resonate \
  -destination 'platform=iOS Simulator,name=<installed iPhone simulator>' \
  -derivedDataPath /tmp/resonate-validation CODE_SIGNING_ALLOWED=NO test
```

Use an installed destination, not a simulator UUID copied from another laptop. If `xcrun` points at Command Line Tools rather than Xcode, set `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` for the command.

| Tests | Coverage |
| --- | --- |
| `NavigationEngineTests.swift` | Maneuver timing, arrival, rerouting, GPS accuracy, geometry, distance formatting |
| `AlertTests.swift`, `TerrainAnalyzerTests.swift` | Obstacle guidance and terrain logic |
| `IndoorComposerTests.swift` | Indoor snapshots and room guidance |
| `ColorNamerTests.swift` | Color naming |
| `PreferencesTests.swift`, `PreferencesSyncTests.swift` | Preference serialization, local persistence, sync failures, saved-place behavior |
| `SpeechPhrasesTests.swift`, `SpeechDispatchTests.swift` | Safety-fragment coverage and real preview dispatch through service protocols |
| `VoiceAssistantTests.swift` | Assistant search/navigation actions, invalid place IDs, JSON content-block round trips |

Debug launch uses `RESONATE_SCREEN` for login, onboarding, home, search, listen, saved, folder, route, walk, navigate, indoor, colors, or settings. It defaults to mocks; add `RESONATE_LIVE=1` for configured live services. These overrides can explain why a valid plist appears to be ignored.

Simulator/unit checks do not validate physical LiDAR, camera distance calibration, vibration, real-world GPS timing, VoiceOver speech, or API credentials. Report which checks actually ran. No builds, tests, deployments, or provider connectivity checks were performed as part of writing this guide.
