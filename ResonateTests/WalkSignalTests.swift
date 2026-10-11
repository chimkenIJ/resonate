import Foundation
import Testing
@testable import Resonate

struct WalkSignalTests {
    /// A dark housing with a lit patch of one color.
    private func signal(lit: (Double, Double, Double), fraction: Double = 0.1) -> [(r: Double, g: Double, b: Double)] {
        (0..<400).map { i in Double(i) / 400 < fraction ? lit : (0.08, 0.08, 0.08) }
    }

    @Test func whiteFigureMeansWalk() {
        #expect(SignalClassifier.classify(signal(lit: (0.95, 0.95, 0.9))) == .walk)
    }

    @Test func orangeHandMeansDontWalk() {
        #expect(SignalClassifier.classify(signal(lit: (1.0, 0.55, 0.1))) == .dontWalk)
    }

    @Test func greenCarLightSaysNothing() {
        #expect(SignalClassifier.classify(signal(lit: (0.1, 0.9, 0.5))) == .unreadable)
    }

    @Test func brightSkyIsNotASignal() {
        #expect(SignalClassifier.classify(signal(lit: (0.9, 0.9, 0.95), fraction: 0.9)) == .unreadable)
    }

    @Test func reportsChangesOnceAndToleratesFlashing() {
        var tracker = WalkSignalTracker()
        let start = Date(timeIntervalSince1970: 0)
        var said: [SignalReading] = []
        // Flashing hand: lit, off, lit, off…
        for i in 0..<12 {
            if let change = tracker.update(i % 2 == 0 ? .dontWalk : .unreadable, now: start.addingTimeInterval(Double(i) * 0.1)) {
                said.append(change)
            }
        }
        for i in 12..<30 {
            if let change = tracker.update(.walk, now: start.addingTimeInterval(Double(i) * 0.1)) { said.append(change) }
        }
        #expect(said == [.dontWalk, .walk])
        // Out of view for a while: forgotten.
        _ = tracker.update(nil, now: start.addingTimeInterval(10))
        #expect(tracker.state == nil)
    }
}
