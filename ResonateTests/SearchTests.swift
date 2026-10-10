import Foundation
import Testing
@testable import Resonate

@MainActor
struct SearchTests {
    @Test func recentSearchesPersistNewestFirstWithoutDuplicates() async throws {
        let suite = "search-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppModel(services: .mock())
        let model = DestinationSearchViewModel(services: app.services, defaults: defaults)
        for text in ["  Kroger  ", "Piedmont Park", "kroger"] {
            model.query = text
            await model.search()
        }
        #expect(model.recentSearches == ["kroger", "Piedmont Park"])
        let reopened = DestinationSearchViewModel(services: app.services, defaults: defaults)
        #expect(reopened.matchingRecentSearches == ["kroger", "Piedmont Park"])
        reopened.query = "KRO"
        #expect(reopened.matchingRecentSearches == ["kroger"])
        _ = try await app.services.auth.signIn()
        reopened.refreshHistory()
        #expect(reopened.recentSearches.isEmpty)
        reopened.query = "ResonateNonexistentFixtureXYZ"
        await reopened.search()
        guard case .failed = reopened.phase else {
            Issue.record("A failed search must still display an error")
            return
        }
        let speech = try #require(app.services.speech as? MockSpeechService)
        #expect(speech.log.isEmpty)
    }

    @Test func changingQueryDiscardsAnOlderSearchResult() async throws {
        let suite = "search-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppModel(services: .mock())
        let model = DestinationSearchViewModel(services: app.services, defaults: defaults)
        model.query = "Kroger"
        let task = Task { await model.search() }
        while model.phase != .searching { await Task.yield() }
        model.query = "Publix"
        await task.value
        #expect(model.results.isEmpty)
        #expect(model.phase == .idle)
    }
}
