import Foundation
import SwiftUI
import Testing
@testable import Resonate

@MainActor
struct SpeechLifecycleTests {
    @Test func navigationStopsSpeechAndClearsRepeat() async throws {
        let app = AppModel(services: .mock())
        let speech = try #require(app.services.speech as? MockSpeechService)
        let transitions: [@MainActor () -> Void] = [
            { app.router.tab = .search },
            { app.router.push(.route(SampleData.places[0])) },
            { app.router.binding(for: .search).wrappedValue = [] },
            { app.router.cover = .walk(nil) },
            { app.router.cover = nil },
        ]
        for transition in transitions {
            await app.feedback.announce("Old screen information", priority: .info)
            transition()
            #expect(speech.lastSpoken == nil)
            let count = speech.log.count
            await app.feedback.repeatLast()
            #expect(speech.log.count == count)
        }
        await app.feedback.announce("New screen information", priority: .info)
        #expect(speech.lastSpoken == "New screen information")
    }

    @Test func closingOutdoorScreenDiscardsLateDescription() async throws {
        let app = AppModel(services: .mock())
        let speech = try #require(app.services.speech as? MockSpeechService)
        app.router.cover = .walk(nil)
        let model = WalkViewModel(mode: .freeWalk, services: app.services, feedback: app.feedback)
        let task = Task { await model.describeScene() }
        while !model.isDescribing { await Task.yield() }
        app.router.cover = nil
        await task.value
        #expect(model.sceneDescription == nil)
        #expect(speech.lastSpoken == nil)
        #expect(!speech.log.contains { $0.priority == .snapshot })
    }

    @Test func closingIndoorScreenDiscardsLateDescription() async throws {
        let app = AppModel(services: .mock())
        let speech = try #require(app.services.speech as? MockSpeechService)
        app.router.cover = .indoor
        let model = IndoorScanViewModel(services: app.services, feedback: app.feedback)
        let task = Task { await model.describeRoom() }
        while !model.isDescribing { await Task.yield() }
        app.router.cover = nil
        await task.value
        #expect(model.roomDescription == nil)
        #expect(speech.lastSpoken == nil)
        #expect(!speech.log.contains { $0.priority == .snapshot })
    }

    @Test func cancelledScreenTaskCannotSpeak() async throws {
        let app = AppModel(services: .mock())
        let speech = try #require(app.services.speech as? MockSpeechService)
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            await app.feedback.announce("Late cancelled message", priority: .info)
        }
        task.cancel()
        await task.value
        #expect(speech.log.isEmpty)
    }

    @Test func stoppingLiveSpeechCancelsLoadingAndClearsQueuedPhrases() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PendingSpeechRequest.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = EdgeFunctionClient(baseURL: try #require(URL(string: "https://speech.test/functions/v1")),
                                        apiKey: "test", auth: MockAuthService(), session: session)
        let speech = ElevenLabsSpeechService(client: client)
        await speech.speak(UUID().uuidString, priority: .info)
        while !speech.isSpeaking { await Task.yield() }
        await speech.speak("Queued old screen phrase", priority: .info)
        speech.stop()
        await Task.yield()
        #expect(!speech.isSpeaking)
        #expect(speech.lastSpoken == nil)
        await speech.repeatLast()
        #expect(!speech.isSpeaking)
        await speech.preview(UUID().uuidString, voiceID: nil)
        #expect(speech.isSpeaking)
        speech.stop()
        await Task.yield()
        #expect(!speech.isSpeaking)
    }
}

private nonisolated final class PendingSpeechRequest: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}
