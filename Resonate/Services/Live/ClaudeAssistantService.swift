import Foundation

/// The voice assistant's model (Claude), through the `assistant` Edge Function, which holds the
/// API key, the system prompt, and the tool list. One call is one model turn.
final class ClaudeAssistantService: AssistantServicing {
    private let client: EdgeFunctionClient

    init(client: EdgeFunctionClient) {
        self.client = client
    }

    private nonisolated struct Request: Encodable, Sendable {
        let messages: [JSONValue]
    }

    func respond(to messages: [JSONValue]) async throws -> AssistantReply {
        // Plain coders so content blocks go back with their keys unchanged. Sorted keys keep each
        // request's history identical to the last one, which prompt caching needs.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try await client.postForData("assistant", body: Request(messages: messages), timeout: 45, encoder: encoder)
        let body = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .array(let content)? = body["content"] else {
            throw AppError.server(message: "The assistant sent back something I couldn't read.")
        }
        return AssistantReply(content: content, stopReason: body["stop_reason"]?.stringValue ?? "end_turn")
    }
}
