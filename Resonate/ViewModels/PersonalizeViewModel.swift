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

    private var base: UserPreferences
    private let save: (UserPreferences) async throws -> Void

    init(mode: Mode, preferences: UserPreferences, save: @escaping (UserPreferences) async throws -> Void) {
        self.mode = mode
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
