import Foundation

/// Offline stand-in for Claude: matches a few phrases ("find Kroger", "open settings",
/// "start walking") to the same tool calls the real assistant makes.
final class MockAssistantService: AssistantServicing {
    func respond(to messages: [JSONValue]) async throws -> AssistantReply {
        try await Task.sleep(for: .milliseconds(400))
        guard case .array(let blocks)? = messages.last?["content"] else { return Self.say("Sorry, I missed that.") }

        // After a tool ran: a short spoken wrap-up.
        if let result = blocks.first(where: { $0["type"]?.stringValue == "tool_result" }) {
            return Self.say(Self.summary(of: result["content"]?.stringValue ?? ""))
        }

        let heard = blocks.last?["text"]?.stringValue?.lowercased() ?? ""
        if heard.contains("stop listening") || heard.contains("goodbye") {
            return Self.call("stop_listening", [:], saying: "Okay, talk soon.")
        }
        for keyword in ["take me to ", "navigate to ", "go to ", "where is ", "search for ", "find "] {
            if let range = heard.range(of: keyword) {
                let query = heard[range.upperBound...].trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
                if !query.isEmpty { return Self.call("search_places", ["query": .string(query)], saying: "Looking for \(query).") }
            }
        }
        let screens: [(String, String, JSONValue)] = [
            ("settings", "open_screen", ["screen": "settings"]),
            ("saved", "open_screen", ["screen": "saved_places"]),
            ("home", "open_screen", ["screen": "home"]),
            ("walk", "open_camera_mode", ["mode": "walk"]),
            ("scan", "open_camera_mode", ["mode": "indoor_scan"]),
            ("color", "open_camera_mode", ["mode": "colors"]),
            ("close", "close_screen", [:]),
            ("back", "close_screen", [:]),
        ]
        if let match = screens.first(where: { heard.contains($0.0) }) {
            return Self.call(match.1, match.2, saying: nil)
        }
        // Anything else is treated as a place name, like the mock microphone's "Kroger".
        let query = heard.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        guard !query.isEmpty else {
            return Self.say("This preview can find places, open saved places or settings, and start walk mode.")
        }
        return Self.call("search_places", ["query": .string(query)], saying: "Looking for \(query).")
    }

    private static func summary(of resultText: String) -> String {
        let data = Data(resultText.utf8)
        guard let result = try? JSONDecoder().decode(JSONValue.self, from: data) else { return "Done." }
        if let error = result["error"]?.stringValue { return error }
        if case .array(let places)? = result["places"], let first = places.first?["name"]?.stringValue {
            return places.count == 1 ? "I found \(first)." : "I found \(places.count) places. The closest is \(first)."
        }
        return "Done."
    }

    private static func say(_ text: String) -> AssistantReply {
        AssistantReply(content: [["type": "text", "text": .string(text)]], stopReason: "end_turn")
    }

    private static func call(_ name: String, _ input: JSONValue, saying text: String?) -> AssistantReply {
        var content: [JSONValue] = []
        if let text { content.append(["type": "text", "text": .string(text)]) }
        content.append(["type": "tool_use", "id": .string("mock_\(UUID().uuidString)"), "name": .string(name), "input": input])
        return AssistantReply(content: content, stopReason: "tool_use")
    }
}
