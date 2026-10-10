import Foundation

/// Sends an alert through whichever channels the user picked (voice, buzzes, tones)
/// and keeps the same obstacle from being repeated every frame.
@Observable
final class FeedbackCenter {
    private let speech: any SpeechServicing
    private let haptics: any HapticsServicing
    private let tones: any TonesServicing

    var preferences: UserPreferences
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
        if channels.contains(.voice) { await speech.speak(alert.spokenText, priority: .safety) }
        return true
    }

    /// Speaks a navigation or info message, plus a turn buzz if the user wants buzzes.
    func announce(_ text: String, priority: SpeechPriority = .navigation, haptic: HapticCue? = nil) async {
        if let haptic, preferences.alertChannels.contains(.buzzes) { haptics.play(haptic) }
        if preferences.alertChannels.contains(.voice) || priority == .info {
            await speech.speak(text, priority: priority)
        }
    }

    func repeatLast() async {
        await speech.repeatLast()
    }
}
