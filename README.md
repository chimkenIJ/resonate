# Resonate

Resonate is an iOS accessibility prototype that helps blind and low-vision users explore their surroundings through obstacle detection, spoken feedback, vibration cues, and walking routes with accessibility information.

The app brings outdoor navigation and indoor room scanning into one interface, with preferences for how users receive feedback. Outdoor search and routing currently focus on Atlanta and Georgia; indoor room scanning requires a supported LiDAR iPhone.

Resonate is a prototype intended to supplement a cane or guide dog. Detection and map information can be incomplete, and distance estimates are approximate. See [Limits](#limits) before trying the app.

## Features

- **Explore surroundings:** detect supported objects and provide distance estimates with speech, vibration, and audio cues.
- **Find a destination:** search places and follow walking routes informed by available accessibility tags.
- **Scan a room:** use RoomPlan on a supported LiDAR iPhone.
- **Describe a scene:** request a camera-based description through Gemini.
- **Recognize colors:** name colors sampled from the center of the camera view.
- **Save places:** organize destinations in folders and choose feedback preferences.

These features use simulated services in demo mode. Live services require the configuration below.

## App flow

Sign in or continue as a guest → onboarding and preferences → home.

From home, choose a destination for outdoor navigation or open a tool to explore nearby surroundings. Saved places are organized into folders for later use.

With live services configured, signed-in users store saved places and preferences in the backend; guests keep them on the phone. Choosing guest access does not by itself enable demo mode: the app configuration determines whether services are live or simulated.

## Stack

| Part | Implementation |
| --- | --- |
| iOS app | Swift and SwiftUI, built in Xcode using MVVM |
| Object detection | Apple Vision and Core ML running YOLO11s on the device |
| Distance | ARKit LiDAR where available; object-size estimates on non-LiDAR phones |
| Indoor scanning | Apple RoomPlan with LiDAR |
| Color recognition | AVFoundation camera sampling and on-device color naming |
| Maps and outdoor routes | MapKit for display, OpenStreetMap data, Nominatim search, and Valhalla walking routes |
| Feedback | ElevenLabs voice, AVSpeechSynthesizer as an offline fallback, Core Haptics, and audio cues |
| Scene descriptions | Gemini through a backend function, requested by the user |
| Authentication | Auth0 |
| Backend | Supabase Postgres/PostGIS and Edge Functions |

## Geographic coverage

Outdoor search, routing, and accessibility features are scoped to Atlanta and Georgia using OpenStreetMap data. The map server imports the Georgia extract, including tags for crossings, curb ramps, tactile paving, steps, and other accessibility features. MapKit supplies the map display.

The current region checks use a Georgia bounding box, which includes small parts of neighboring states. See the [backend setup guide](docs/BACKEND_SETUP.md#2e-exact-georgia-border-optional) for loading the exact state boundary.

## Requirements

| Goal | Requirements |
| --- | --- |
| Explore the demo interface | Mac, compatible Xcode release, and an iPhone simulator or iPhone |
| Try live camera tools | Physical iPhone running iOS 17 or later, camera permission, and live app configuration |
| Scan indoor rooms | Supported LiDAR iPhone |
| Run local routing services | Mac with Docker Desktop, Node.js/npm, and Python 3 |

The deployment target is iOS 17.0. Use a recent Xcode release compatible with the project's Swift syntax; the minimum iOS version does not specify the required Xcode version.

## Run the demo

1. Clone this repository and open `Resonate.xcodeproj` in Xcode.
2. Let Xcode resolve the Swift packages. If needed, use **File → Packages → Resolve Package Versions**.
3. Select the **Resonate** scheme and an iPhone simulator.
4. Press **⌘R** to build and run.
5. Choose **Continue without account**, finish onboarding, and try the home, search, route, and saved-place screens.

Without a complete `ResonateConfig.plist`, the app automatically uses mock services. No API keys or backend are needed for this demo. Locations, routes, detection, and feedback are simulated; this mode is for trying the interface.

To confirm demo mode, check the Xcode console for `ResonateConfig.plist missing or incomplete; running on mock services.` If you already configured live services, use a separate checkout without your local configuration file to try the demo.

### Run on an iPhone

Select your device in Xcode and set your development team under **Signing & Capabilities**, then build and run. Grant camera and location access when using the corresponding tools.

Real camera detection and color recognition require a physical device and live services. Indoor room scanning also requires supported LiDAR hardware. On phones without LiDAR, obstacle distances use object-size estimates. The simulator cannot validate camera accuracy, LiDAR depth, or vibration behavior.

## Configure live services

### Accounts and saved places

Follow the [backend setup guide](docs/BACKEND_SETUP.md) to configure Auth0, connect Supabase, and apply the database migrations. Then run this command from the repository root on your Mac:

```sh
cp config/ResonateConfig.example.plist Resonate/Resources/ResonateConfig.plist
```

Fill in `SupabaseURL`, `SupabaseKey`, `Auth0Domain`, `Auth0ClientID`, and `Auth0Audience`. Use the Supabase publishable or legacy anon key in the app. Keep service-role keys and third-party API secrets on the backend.

The local plist is gitignored. Missing, empty, or `YOUR_` placeholder values in required fields cause the app to use mock services. Rebuild after changing the configuration.

### Search and routing

Follow [Map server setup](docs/MAP_SERVER.md) for the Georgia OSM import, Valhalla, Nominatim, accessibility data, and the `geocode` and `route` Edge Functions.

For local testing on your Mac, install Docker Desktop, Node.js/npm, and Python 3. Complete [account configuration](#accounts-and-saved-places) first, then create `supabase/functions/.env.local` containing:

```dotenv
VALHALLA_URL=http://host.docker.internal:8002
NOMINATIM_URL=https://nominatim.openstreetmap.org
```

Then run from the repository root:

```sh
server/scripts/dev_up.sh
```

The script starts local routing and Supabase, loads accessibility points, and updates the app's `FunctionsURL` and `FunctionsKey`. The first run downloads Georgia map data and builds routing tiles, so allow time for it to finish. Accounts and saved places still use your configured hosted Supabase project.

Rebuild the app in Xcode. For a phone, keep the Mac awake, put both devices on the same Wi-Fi, and allow Local Network access when prompted. For a simulator, set `FunctionsURL` to `http://127.0.0.1:54321/functions/v1` if the Mac's `.local` address is unreachable.

Stop the local services with:

```sh
server/scripts/dev_down.sh
```

Local search uses public Nominatim for light personal testing. Use the self-hosted Nominatim setup in the map server guide for a deployed app.

### Voice and scene descriptions

Configure `ELEVENLABS_API_KEY` and `GEMINI_API_KEY` as Supabase function secrets, then deploy the `speak` and `describe` functions. For local functions, add the keys to the gitignored `supabase/functions/.env.local` and restart the local services. Optional settings are `ELEVENLABS_VOICE_ID` and `GEMINI_MODEL`.

Obstacle detection and color naming run on the device. A scene-description request sends a camera snapshot to the `describe` backend function for Gemini processing; ElevenLabs speech uses the `speak` function. These remote features require network access. Device speech provides a fallback when remote speech is unavailable.

The YOLO Core ML model is included in `Resonate/Resources/Models/`. See the [model notes](Resonate/Resources/Models/README.md) for export instructions and licensing.

## Project structure

The app follows MVVM: views render the interface, view models handle screen state and actions, and services handle accounts, maps, vision, and feedback.

```text
Resonate/
  Views/          SwiftUI screens
  ViewModels/     Screen state and actions
  Models/         App data and navigation logic
  Services/       Protocols, live implementations, and mocks
  Components/     Shared interface components
  Theme/          Colors, typography, and spacing
  Resources/      Fonts, Core ML model, and local configuration
ResonateTests/    Unit tests
supabase/        Database migrations and Edge Functions
server/          Map server containers and development scripts
docs/            Backend and map setup guides
```

To run the unit tests, select the **Resonate** scheme and an iPhone simulator in Xcode, then press **⌘U**.

## Storage and current features

Supabase stores user profiles, saved places, folders, preferences, and OSM accessibility points. The `saved_routes` table stores saved destinations rather than complete route histories. Routing runs on the separate Valhalla server.

Color recognition currently uses a mock service. On non-LiDAR phones, obstacle distances are estimated from object size; indoor room scanning requires LiDAR.

## Limits

OSM accessibility coverage varies, and a route may still include steps or unverified crossings. Camera detection can miss objects, and non-LiDAR distance estimates are approximate. Resonate is a prototype that supplements a cane or guide dog; it does not replace them.

Map data: © [OpenStreetMap contributors](https://www.openstreetmap.org/copyright).
