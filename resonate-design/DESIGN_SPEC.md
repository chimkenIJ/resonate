# AccessAble Design Spec

AI accessibility app for blind and low-vision users. Dark mode only. SwiftUI, iOS 17+.

`screenshots/` has a PNG of every screen (390x844 @2x), which is the visual source of truth.
`html/` has the same screens as HTML, which holds the exact sizes, colors, and copy. Each screen's links show where its buttons go.

## Design tokens

### Colors
| Token | Hex | Use |
|---|---|---|
| background | #121314 | Screen background |
| surface | #1C1D1F | Cards, sheets, back buttons |
| surfaceRaised | #2A2C30 | Rows inside cards, secondary buttons |
| border | #333538 | 2px borders on cards and round buttons |
| textPrimary | #F2F0EB | Main text; also the primary button fill |
| textSecondary | #CFCCC5 | Subtitles on cards |
| textMuted | #B4B1AA | Counts, captions |
| onAccent | #121314 | Text and icons on any accent color |
| sand | #D9B26A | Walk outside, Home folder, warnings |
| sage | #8FAE8B | Scan indoors, Errands folder, doors |
| slate | #7E9CC4 | Saved places, Classes folder, routes, walls |
| clay | #C9785D | Food folder, obstacles (bike, chair) |
| mauve | #A99AC9 | Gym folder, signs, audio crossings |
| rose | #C98F96 | Friends folder |

Accent colors differ in brightness as well as hue, so color-blind users can still tell them apart. Never put white text on an accent color. Always use #121314.

### Type
- Font: Atkinson Hyperlegible Next (free from Google Fonts, built for low vision). Fall back to SF Pro Rounded if needed.
- Screen title: 40-44pt, weight 800
- Card title: 22-26pt, weight 800
- Body and subtitles: 16-18pt, weight 600
- Minimum text size anywhere: 15pt. Support Dynamic Type.

### Shape and spacing
- Screen padding: 20pt sides, 60pt top
- Gap between big elements: 20-28pt
- Card corner radius: 26-32pt. Pills are fully rounded.
- Minimum touch target: 60pt. Primary buttons are 64pt tall.
- Round icon buttons: 60pt circles

## Screens and navigation (no tab bar)

1. **Home** (`Main`)
   - Settings button (top right) → Setup
   - Large off-white search button "Where do you want to go?": tapping it starts voice input
   - Tile "Walk outside" → Detect
   - Tile "Scan indoors" → Indoors
   - Tile "Saved places" → Saved
2. **Saved places** (`Saved`): 2-column grid of folders (Classes, Home, Food, Gym, Friends, Errands), each with a count. Tapping a folder → that folder's list (`Classes` is the example).
3. **Folder list** (`Classes`): big rows (92pt), each showing a place name and "12 min · step-free". Tapping a row → Route.
4. **Route** (`Route`): dark map with the step-free route in slate and obstacles avoided. Bottom sheet shows the time, feature chips, turn steps, and a "Start walking" button → Detect.
5. **Walk outside** (`Detect`): live camera with labeled bounding boxes. Bottom sheet has a one-sentence spoken alert, a guidance row, and Repeat / video call / Route buttons.
6. **Scan indoors** (`Indoors`): live camera that labels walls, doors, and furniture with distances. The sheet has a mini top-down map, one sentence about the nearest obstacle, a guidance row, and Repeat / Describe room buttons.
7. **Personalize** (`Setup`): onboarding step for choosing which needs to support (multi-select cards) and how alerts arrive (Voice / Buzzes / Tones).

Every screen except Home has a 60pt back button at the top left.

## Accessibility requirements
- Every control needs a VoiceOver label (see `aria-label` in the HTML for the wording).
- Spoken alerts use AVSpeechSynthesizer. Haptics use UIImpactFeedbackGenerator (2 pulses = heads up).
- Treat the bounding-box overlays as decoration for sighted helpers. The spoken sentence is the real output.
- Respect Reduce Motion and Bold Text.

## Suggested tech
- Camera: AVFoundation. Detection: Vision + Core ML (e.g. YOLO), with LiDAR/ARKit depth for distances where available.
- Maps: MapKit. Speech input: Speech framework.
- Saved places: SwiftData (Folder → [SavedRoute]).
