import Foundation
import Testing
@testable import Resonate

/// The "change a setting, kill the app, it's gone" bug: a failed Supabase sync must never roll settings back.
@MainActor
struct PreferencesSyncTests {
    final class FlakyRemote: PreferencesServicing {
        var stored: UserPreferences?
        var failing = true
        func load() async -> UserPreferences? { stored }
        func save(_ preferences: UserPreferences) async throws {
            if failing { throw AppError.offline }
            stored = preferences
        }
    }

    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "prefs-\(UUID().uuidString).json")
    }

    @Test func settingsSurviveARelaunchWhenSyncFails() async throws {
        let file = tempFile()
        let auth = MockAuthService()
        _ = try await auth.signIn()
        let remote = FlakyRemote()
        remote.stored = UserPreferences() // the account's older copy: avoid stairs on

        var changed = UserPreferences()
        changed.routing.avoidSteps = false
        changed.routing.maxIncline = HillLimit.gentle.incline
        let first = AccountAwarePreferencesService(auth: auth, remote: remote, local: LocalPreferencesService(fileURL: file))
        try await first.save(changed)
        #expect(remote.stored?.routing.avoidSteps == true)

        // "Kill the app": a brand-new service reading the same file.
        let relaunched = AccountAwarePreferencesService(auth: auth, remote: remote, local: LocalPreferencesService(fileURL: file))
        let loaded = try #require(await relaunched.load())
        #expect(loaded.routing.avoidSteps == false)
        #expect(loaded.routing.maxIncline == HillLimit.gentle.incline)

        // Once Supabase works again, the phone's newer copy is uploaded and marked synced.
        remote.failing = false
        _ = await relaunched.load()
        #expect(remote.stored?.routing.avoidSteps == false)
        #expect(LocalPreferencesService(fileURL: file).needsSync == false)
    }

    @Test func syncedPhonesFollowTheAccount() async throws {
        let file = tempFile()
        let auth = MockAuthService()
        _ = try await auth.signIn()
        let remote = FlakyRemote()
        remote.failing = false
        var fromOtherPhone = UserPreferences()
        fromOtherPhone.alertChannels = [.voice, .tones]
        remote.stored = fromOtherPhone
        let local = LocalPreferencesService(fileURL: file)
        local.replace(with: UserPreferences())
        let loaded = try #require(await AccountAwarePreferencesService(auth: auth, remote: remote, local: local).load())
        #expect(loaded.alertChannels == [.voice, .tones])
    }

    @Test func hillLimitsMatchStoredInclines() {
        #expect(HillLimit(incline: 0.08) == .moderate)
        #expect(HillLimit(incline: 0.05) == .gentle)
        #expect(HillLimit(incline: 0.15) == .steep)
    }

    @Test func deletingAFolderDeletesItsPlaces() async throws {
        let store = LocalSavedPlacesService(fileURL: tempFile())
        let folder = try await store.createFolder(name: "Gym", accent: .mauve, icon: .gym)
        let place = Place(id: "test", name: "Rec Center", address: "", coordinate: GeoPoint(latitude: 33.7754, longitude: -84.4036))
        _ = try await store.save(place, routeSummary: nil, to: folder.id)
        try await store.deleteFolder(folder.id)
        #expect(try await store.folders().contains { $0.id == folder.id } == false)
        #expect(try await store.places(in: folder.id).isEmpty)
    }
}
