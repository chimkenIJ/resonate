import Foundation

/// Sends an alert through whichever channels the user picked (voice, buzzes, tones)
/// and keeps the same obstacle from being repeated every frame.
@Observable
final class FeedbackCenter {
    private let speech: any SpeechServicing
    private let haptics: any HapticsServicing
    private let tones: any TonesServicing

    var preferences: UserPreferences { didSet { speech.selectVoice(preferences.voiceID) } }
    private(set) var currentAlert: ObstacleAlert?

    private var lastAlertKey: String?
    private var lastAlertTime: Date = .distantPast
    /// The same obstacle is not repeated within this window unless it gets more urgent.
    private let repeatInterval: TimeInterval = 6

    init(speech: any SpeechServicing, haptics: any HapticsServicing, tones: any TonesServicing, preferences: UserPreferences) {
        self.speech = speech
        self.haptics = haptics
        self.tones = tones
        self.preferences = preferences
    }

    /// Delivers a safety alert. Returns false if it was suppressed as a repeat.
    @discardableResult
    func deliver(_ alert: ObstacleAlert, now: Date = .now) async -> Bool {
        let isRepeat = alert.dedupeKey == lastAlertKey
            && now.timeIntervalSince(lastAlertTime) < repeatInterval
            && alert.severity <= (currentAlert?.severity ?? .info)
        guard !isRepeat else { return false }

        currentAlert = alert
        lastAlertKey = alert.dedupeKey
        lastAlertTime = now

        let channels = preferences.alertChannels
        if channels.contains(.buzzes), let cue = alert.severity.hapticCue { haptics.play(cue) }
        if channels.contains(.tones) { tones.play(alert.severity == .stop ? .stop : .headsUp) }
        if channels.contains(.voice) { await speech.speak(alert.spokenText, priority: .safety, fragments: alert.fragments) }
        return true
    }

    var isSpeaking: Bool { speech.isSpeaking }

    /// Walking: something very close in the path or coming fast. One stop buzz and a short phrase that
    /// interrupts anything playing (pre-recorded pieces, so no network wait).
    func deliverUrgent(_ alert: ObstacleAlert) async {
        currentAlert = alert
        let channels = preferences.alertChannels
        if channels.contains(.buzzes) { haptics.play(.stop) }
        if channels.contains(.tones) { tones.play(.stop) }
        if channels.contains(.voice) { await speech.speak(alert.spokenText, priority: .safety, fragments: alert.fragments) }
    }

    /// Walking: the periodic "what's ahead" summary. No buzz, and never spoken over anything else.
    func speakSummary(_ alert: ObstacleAlert) async {
        guard preferences.alertChannels.contains(.voice), !speech.isSpeaking else { return }
        await speech.speak(alert.spokenText, priority: .navigation, fragments: alert.fragments)
    }

    /// Walking: one light tap when the nearest thing in the path gets closer. The only routine buzz.
    func proximityPulse() {
        let channels = preferences.alertChannels
        if channels.contains(.buzzes) { haptics.play(.tap) }
        if channels.contains(.tones) { tones.play(.headsUp) }
    }

    /// Speaks a navigation or info message, plus a turn buzz if the user wants buzzes.
    func announce(_ text: String, priority: SpeechPriority = .navigation, haptic: HapticCue? = nil) async {
        if let haptic, preferences.alertChannels.contains(.buzzes) { haptics.play(haptic) }
        if preferences.alertChannels.contains(.voice) || priority == .info {
            await speech.speak(text, priority: priority)
        }
    }

    /// Speaks `text` only the first time `key` is seen on this phone (one-time notices).
    func announceOnce(key: String, _ text: String) async {
        let defaultsKey = "notice.\(key)"
        guard !UserDefaults.standard.bool(forKey: defaultsKey) else { return }
        UserDefaults.standard.set(true, forKey: defaultsKey)
        await speech.speak(text, priority: .info)
    }

    func stopSpeech() { speech.stop() }

    func repeatLast() async {
        await speech.repeatLast()
    }
}
