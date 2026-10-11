import Testing
@testable import Resonate

struct SpeechQueueTests {
    /// Plays everything left, sentence by sentence.
    private func drain(_ queue: inout SpeechQueue) -> [String] {
        var said: [String] = []
        while let sentence = queue.next() { said.append(sentence.text) }
        return said
    }

    @Test func playsOneSentenceAtATime() {
        var queue = SpeechQueue()
        #expect(queue.enqueue("Veer left. Person on your right, 6 feet.", priority: .navigation) == .play)
        #expect(drain(&queue) == ["Veer left.", "Person on your right, 6 feet."])
        #expect(queue.isIdle)
    }

    @Test func piecesSplitWhereASentenceEnds() {
        let sentences = SpeechQueue.sentences(
            "", fragments: ["Path clear.", "Person", "on your right,", "6 feet."], priority: .navigation, message: 1
        )
        #expect(sentences.map(\.text) == ["Path clear.", "Person on your right, 6 feet."])
        #expect(sentences.last?.fragments == ["Person", "on your right,", "6 feet."])
    }

    @Test func somethingNewReplacesTheRestOfAnOldMessage() {
        var queue = SpeechQueue()
        _ = queue.enqueue("A bench on the left. A tree ahead. A bus stop on the right.", priority: .snapshot)
        #expect(queue.next()?.text == "A bench on the left.")
        // The user walked on: a direction arrives while the description is playing.
        #expect(queue.enqueue("Turn right onto Main Street.", priority: .navigation) == .play)
        #expect(drain(&queue) == ["Turn right onto Main Street."])
    }

    @Test func safetyCutsInRightAway() {
        var queue = SpeechQueue()
        _ = queue.enqueue("In 50 feet, turn left. Then continue for 200 feet.", priority: .navigation)
        _ = queue.next()
        #expect(queue.enqueue("Stop. Veer left. Post straight ahead.", priority: .safety) == .interruptNow)
        #expect(queue.current == nil)
        #expect(drain(&queue) == ["Stop.", "Veer left.", "Post straight ahead."])
    }

    @Test func aWarningNeverCutsOffAnother() {
        var queue = SpeechQueue()
        _ = queue.enqueue("Stop. Veer left. Post straight ahead.", priority: .safety)
        _ = queue.next()
        #expect(queue.enqueue("Stop. Watch the edge. Drop-off on your right.", priority: .safety) == .play)
        #expect(queue.enqueue("Stop. Watch the step. Curb drop straight ahead.", priority: .safety) == .play)
        #expect(drain(&queue) == ["Veer left.", "Post straight ahead.", "Stop.", "Watch the step.", "Curb drop straight ahead."])
    }

    @Test func lessImportantWaitsAndOnlyTheNewestWaits() {
        var queue = SpeechQueue()
        _ = queue.enqueue("Turn left.", priority: .navigation)
        _ = queue.next()
        _ = queue.enqueue("Saved Kroger to Food.", priority: .info)
        _ = queue.enqueue("Removed Kroger.", priority: .info)
        #expect(drain(&queue) == ["Removed Kroger."])
    }

    @Test func aQueuedAlertIsNotReplacedBeforeItStarts() {
        var queue = SpeechQueue()
        _ = queue.enqueue("Stop. Watch the step.", priority: .safety)
        // Not started yet when the next summary comes in.
        _ = queue.enqueue("Path clear.", priority: .navigation)
        #expect(drain(&queue) == ["Stop.", "Watch the step.", "Path clear."])
    }

    @Test func theSameAlertIsntRestarted() {
        var queue = SpeechQueue()
        _ = queue.enqueue("Stop. Watch the edge.", priority: .safety)
        _ = queue.next()
        #expect(queue.enqueue("Stop. Watch the edge.", priority: .safety) == .ignored)
    }

    @Test func clearStopsEverything() {
        var queue = SpeechQueue()
        _ = queue.enqueue("One. Two. Three.", priority: .info)
        _ = queue.next()
        queue.clear()
        #expect(queue.next() == nil)
        #expect(queue.isIdle)
    }
}
