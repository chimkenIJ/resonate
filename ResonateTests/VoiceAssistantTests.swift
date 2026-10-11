import Foundation
import Testing
@testable import Resonate

@MainActor
struct VoiceAssistantTests {
    /// Plays back scripted model turns and records every request the assistant sends.
    final class ScriptedAssistant: AssistantServicing {
        var requests: [[JSONValue]] = []
        var script: [([JSONValue]) -> AssistantReply] = []

        func respond(to messages: [JSONValue]) async throws -> AssistantReply {
            requests.append(messages)
            guard !script.isEmpty else { return AssistantReply(content: [["type": "text", "text": "Okay."]], stopReason: "end_turn") }
            return script.removeFirst()(messages)
        }
    }

    private func makeApp(assistant: ScriptedAssistant) -> AppModel {
        let mock = AppServices.mock()
        let services = AppServices(
            auth: mock.auth, users: mock.users, preferences: mock.preferences, savedPlaces: mock.savedPlaces,
            location: mock.location, geocoding: mock.geocoding, routing: mock.routing, speech: mock.speech,
            speechRecognition: mock.speechRecognition, haptics: mock.haptics, tones: mock.tones,
            obstacleDetection: mock.obstacleDetection, indoorScan: mock.indoorScan,
            sceneDescription: mock.sceneDescription, colorRecognition: mock.colorRecognition,
            assistant: assistant
        )
        return AppModel.preview(services: services)
    }

    private static func toolUse(_ name: String, _ input: JSONValue, id: String) -> JSONValue {
        ["type": "tool_use", "id": .string(id), "name": .string(name), "input": input]
    }

    /// The tool result text in the last user turn, parsed.
    private static func lastToolResult(_ messages: [JSONValue]) -> JSONValue? {
        guard case .array(let blocks)? = messages.last?["content"],
              let text = blocks.first?["content"]?.stringValue else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    @Test func searchesThenStartsNavigationAndStops() async throws {
        let model = ScriptedAssistant()
        model.script = [
            { _ in AssistantReply(content: [Self.toolUse("search_places", ["query": "Kroger"], id: "t1")], stopReason: "tool_use") },
            { messages in
                guard case .array(let places)? = Self.lastToolResult(messages)?["places"],
                      let id = places.first?["id"] else { return AssistantReply(content: [], stopReason: "end_turn") }
                return AssistantReply(content: [Self.toolUse("start_navigation", ["place_id": id], id: "t2")], stopReason: "tool_use")
            },
            { _ in
                AssistantReply(content: [["type": "text", "text": "Starting directions."], Self.toolUse("stop_listening", [:], id: "t3")],
                               stopReason: "tool_use")
            },
        ]
        let app = makeApp(assistant: model)

        app.assistant.start(with: "Take me to Kroger")
        for _ in 0..<150 where app.assistant.isActive {
            try await Task.sleep(for: .milliseconds(100))
        }

        #expect(!app.assistant.isActive)
        #expect(model.requests.count == 4)
        #expect(app.search.results.contains { $0.name.contains("Kroger") })
        guard case .walk(let route?)? = app.router.cover else {
            Issue.record("Navigation didn't start")
            return
        }
        #expect(route.destination.name.contains("Kroger"))

        // The conversation sent last: user, assistant, user, ... with each tool result answering its call.
        let last = try #require(model.requests.last)
        #expect(last.map { $0["role"]?.stringValue } == ["user", "assistant", "user", "assistant", "user", "assistant", "user"])
        let resultIDs = last.compactMap { message -> String? in
            guard case .array(let blocks)? = message["content"] else { return nil }
            return blocks.first { $0["type"]?.stringValue == "tool_result" }?["tool_use_id"]?.stringValue
        }
        #expect(resultIDs == ["t1", "t2", "t3"])
    }

    @Test func unknownPlaceComesBackAsToolError() async throws {
        let model = ScriptedAssistant()
        model.script = [
            { _ in AssistantReply(content: [Self.toolUse("show_route", ["place_id": "nope"], id: "t1")], stopReason: "tool_use") },
            { _ in AssistantReply(content: [Self.toolUse("stop_listening", [:], id: "t2")], stopReason: "tool_use") },
        ]
        let app = makeApp(assistant: model)

        app.assistant.start(with: "Show me the route")
        for _ in 0..<100 where app.assistant.isActive {
            try await Task.sleep(for: .milliseconds(100))
        }

        let second = try #require(model.requests.dropFirst().first)
        guard case .array(let blocks)? = second.last?["content"] else {
            Issue.record("No tool result")
            return
        }
        let isError = blocks.first?["is_error"]?.boolValue ?? false
        #expect(isError)
        let pushedScreens = app.router.paths.values.reduce(0) { $0 + $1.count }
        #expect(pushedScreens == 0)
    }

    @Test func holdingTheButtonSendsWhatWasHeard() async throws {
        let model = ScriptedAssistant()
        let app = makeApp(assistant: model)

        app.assistant.beginTalking()
        #expect(app.assistant.state == .listening)
        try await Task.sleep(for: .milliseconds(800)) // the mock "says" Kroger
        app.assistant.finishTalking()
        for _ in 0..<100 where app.assistant.isActive {
            try await Task.sleep(for: .milliseconds(100))
        }

        #expect(!app.assistant.isActive)
        let request = try #require(model.requests.first)
        guard case .array(let blocks)? = request.last?["content"] else {
            Issue.record("No user turn")
            return
        }
        #expect(blocks.last?["text"]?.stringValue == "Kroger")
    }

    @Test func describingDuringNavigationKeepsTheRoute() async throws {
        let app = makeApp(assistant: ScriptedAssistant())
        let route = SampleData.route(to: SampleData.places[0])
        app.router.cover = .walk(route)
        let walk = WalkViewModel(mode: .navigating(route), services: app.services, feedback: app.feedback)
        app.sceneDescriber = walk

        let result = try await AssistantTools.run("describe_surroundings", input: [:], on: app)

        #expect(app.router.cover == .walk(route))
        #expect(result["description"]?.stringValue?.isEmpty == false)
    }

    @Test func describingWithoutACameraOpensScanTheArea() async throws {
        let app = makeApp(assistant: ScriptedAssistant())
        _ = try await AssistantTools.run("describe_surroundings", input: [:], on: app)
        #expect(app.router.cover == .scanArea)
    }

    @Test func leavingTheScreenYourselfStopsTheAssistant() async throws {
        let app = makeApp(assistant: ScriptedAssistant())
        app.assistant.start(with: "What's on my screen?")
        #expect(app.assistant.isActive)

        app.router.tab = .settings // the user taps a tab

        #expect(!app.assistant.isActive)
    }

    @Test func contentBlocksRoundTrip() throws {
        let text = #"{"input":{"place_id":"osm:node:1"},"signature":"abc/def","type":"tool_use","n":3}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        #expect(value["input"]?["place_id"]?.stringValue == "osm:node:1")
        #expect(value.jsonText == #"{"input":{"place_id":"osm:node:1"},"n":3,"signature":"abc/def","type":"tool_use"}"#)
    }
}
