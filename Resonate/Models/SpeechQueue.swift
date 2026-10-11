import Foundation
import NaturalLanguage

/// What the app's voice says next: one voice, one sentence at a time, and never out of date.
///
/// - Safety alerts cut in at once and replace everything else, but never cut off another safety
///   alert: the newest one plays right after it.
/// - Anything else lets the sentence that's playing finish, then replaces whatever was left of a
///   message that's no more important, so old information isn't read out after something new.
/// - Something less important than what's playing waits; only the newest one waits.
///
/// Pure logic; the voice service plays the sentences.
nonisolated struct SpeechQueue: Sendable {
    nonisolated struct Sentence: Equatable, Sendable {
        let text: String
        /// Pre-recorded pieces that together say `text`, when the message was built from them.
        let fragments: [String]?
        let priority: SpeechPriority
        /// Which message this sentence belongs to.
        let message: Int
    }

    nonisolated enum Decision: Equatable, Sendable {
        /// Stop the audio now and start over with the queue.
        case interruptNow
        /// Start playing if nothing is (otherwise it plays after the current sentence).
        case play
        /// Already being said; nothing to do.
        case ignored
    }

    /// The sentence playing now.
    private(set) var current: Sentence?
    /// The rest of the current message.
    private var rest: [Sentence] = []
    /// A less important message waiting for the current one to finish.
    private var waiting: [Sentence] = []
    private var currentText: String?
    private var waitingText: String?
    private var nextMessage = 0

    var isIdle: Bool { current == nil && rest.isEmpty && waiting.isEmpty }

    mutating func enqueue(_ text: String, priority: SpeechPriority, fragments: [String]? = nil) -> Decision {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        nextMessage += 1
        let sentences = Self.sentences(text, fragments: fragments, priority: priority, message: nextMessage)
        guard !sentences.isEmpty else { return .ignored }

        // What's playing, or about to (queued but not started yet).
        guard let head = current ?? rest.first else {
            rest = sentences
            waiting = []
            currentText = text
            waitingText = nil
            return .play
        }
        // Saying it already.
        if text == currentText, priority <= head.priority { return .ignored }

        if priority == .safety {
            if current?.priority == .safety {
                waiting = sentences
                waitingText = text
                return .play
            }
            current = nil
            rest = sentences
            waiting = []
            currentText = text
            waitingText = nil
            return .interruptNow
        }
        if priority >= head.priority {
            // Newer and at least as important: what's left of the old message is out of date.
            rest = sentences
            waiting = []
            currentText = text
            waitingText = nil
        } else if waiting.first.map({ priority >= $0.priority }) ?? true {
            waiting = sentences
            waitingText = text
        }
        return .play
    }

    /// The next sentence to play, or nil when there's nothing left. Call when a sentence finishes.
    mutating func next() -> Sentence? {
        if rest.isEmpty, !waiting.isEmpty {
            rest = waiting
            currentText = waitingText
            waiting = []
            waitingText = nil
        }
        current = rest.isEmpty ? nil : rest.removeFirst()
        if current == nil { currentText = nil }
        return current
    }

    /// The sentence after the current one, so it can be fetched while the current one plays.
    var upcoming: Sentence? { rest.first ?? waiting.first }

    mutating func clear() {
        current = nil
        rest = []
        waiting = []
        currentText = nil
        waitingText = nil
    }

    /// Splits a message into sentences. Messages built from pre-recorded pieces split where a piece
    /// ends a sentence ("Path clear." | "Person" "on your right," "6 feet."), so each sentence can
    /// still be played from its pieces.
    static func sentences(_ text: String, fragments: [String]?, priority: SpeechPriority, message: Int) -> [Sentence] {
        if let fragments, !fragments.isEmpty {
            var groups: [[String]] = []
            var group: [String] = []
            for fragment in fragments {
                group.append(fragment)
                if let last = fragment.trimmingCharacters(in: .whitespaces).last, ".!?".contains(last) {
                    groups.append(group)
                    group = []
                }
            }
            if !group.isEmpty { groups.append(group) }
            return groups.map { Sentence(text: $0.joined(separator: " "), fragments: $0, priority: priority, message: message) }
        }
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var parts: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let part = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !part.isEmpty { parts.append(part) }
            return true
        }
        if parts.isEmpty { parts = [text] }
        return parts.map { Sentence(text: $0, fragments: nil, priority: priority, message: message) }
    }
}
