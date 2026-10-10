import Foundation
import OSLog
import Observation

/// Backs both onboarding (Personalize) and the Settings tab.
@Observable
final class PersonalizeViewModel {
    enum Mode { case onboarding, settings }

    let mode: Mode
    private(set) var needs: Set<AssistNeed>
    private(set) var channels: Set<AlertChannel>
    private(set) var message: String?
    private(set) var isSaving = false

    var routing: RoutingPreferences { didSet { autosave() } }
    var voiceID: String? { didSet { autosave() } }
    private(set) var voices: [SpeechVoice] = []

    func loadVoices(using speech: any SpeechServicing) async {
        voices = (try? await speech.availableVoices()) ?? []
    }

    /// Matilda, the voice used when none is chosen.
    static let defaultVoiceID = "XrExE9yKIg1WjnnlVkGX"

    /// Short name of the chosen voice ("Matilda").
    var currentVoiceName: String {
        guard let voiceID, voiceID != Self.defaultVoiceID else { return "Matilda" }
        return voices.first { $0.id == voiceID }.map { Self.shortName($0.name) } ?? "Chosen voice"
    }

    /// "Matilda - Knowledgable, Professional" → "Matilda".
    static func shortName(_ name: String) -> String { name.components(separatedBy: " - ").first ?? name }

    /// Plays a short sample in the chosen voice right away.
    func preview(name: String, voiceID: String?, using speech: any SpeechServicing) async {
        await speech.preview("Hi, I'm \(name).",
                             voiceID: voiceID ?? Self.defaultVoiceID)
    }

    private var base: UserPreferences
    private let save: @MainActor (UserPreferences) async throws -> Void

    init(mode: Mode, preferences: UserPreferences, save: @escaping @MainActor (UserPreferences) async throws -> Void) {
        self.mode = mode
        self.routing = preferences.routing
        self.voiceID = preferences.voiceID
        self.base = preferences
        self.needs = preferences.needs
        self.channels = preferences.alertChannels
        self.save = save
    }

    func toggle(_ need: AssistNeed) {
        if needs.contains(need) {
            guard needs.count > 1 else {
                message = "Pick at least one thing to help with."
                return
            }
            needs.remove(need)
        } else {
            needs.insert(need)
        }
        message = nil
        autosave()
    }

    func toggle(_ channel: AlertChannel) {
        if channels.contains(channel) {
            guard channels.count > 1 else {
                message = "Keep at least one way to get alerts."
                return
            }
            channels.remove(channel)
        } else {
            channels.insert(channel)
        }
        message = nil
        autosave()
    }

    /// Onboarding "Continue". Settings saves on every change instead.
    func commit() async {
        isSaving = true
        defer { isSaving = false }
        var updated = base
        updated.routing = routing
        updated.voiceID = voiceID
        updated.needs = needs
        updated.alertChannels = channels
        do {
            try await save(updated)
            base = updated
        } catch {
            Log.data.error("Couldn't save preferences: \(String(describing: error), privacy: .public)")
            message = "Couldn't save your choices. Try again."
        }
    }

    private func autosave() {
        guard mode == .settings else { return }
        Task { await commit() }
    }
}
