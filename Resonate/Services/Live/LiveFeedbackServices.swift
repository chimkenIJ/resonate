import AVFoundation
import CoreHaptics
import Foundation
import OSLog
import UIKit

/// Vibration cues with Core Haptics. Two quick pulses mean "heads up"; a long buzz means "stop";
/// left and right turns feel different (long-short vs short-long).
final class LiveHapticsService: HapticsServicing {
    private var engine: CHHapticEngine?
    private let fallback = UIImpactFeedbackGenerator(style: .heavy)

    init() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            let engine = try CHHapticEngine()
            engine.playsHapticsOnly = true
            engine.isAutoShutdownEnabled = true
            engine.resetHandler = { [weak engine] in try? engine?.start() }
            try engine.start()
            self.engine = engine
        } catch {
            Log.vision.error("Haptics unavailable: \(String(describing: error), privacy: .public)")
        }
    }

    func play(_ cue: HapticCue) {
        guard let engine else {
            fallback.impactOccurred()
            return
        }
        do {
            try engine.start()
            let player = try engine.makePlayer(with: CHHapticPattern(events: Self.events(for: cue), parameters: []))
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            fallback.impactOccurred()
        }
    }

    private static func tap(at time: TimeInterval, intensity: Float = 1, sharpness: Float = 0.5) -> CHHapticEvent {
        CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
        ], relativeTime: time)
    }

    private static func buzz(at time: TimeInterval, duration: TimeInterval, intensity: Float = 1) -> CHHapticEvent {
        CHHapticEvent(eventType: .hapticContinuous, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3),
        ], relativeTime: time, duration: duration)
    }

    private static func events(for cue: HapticCue) -> [CHHapticEvent] {
        switch cue {
        case .tap: [tap(at: 0, intensity: 0.6)]
        case .headsUp: [tap(at: 0), tap(at: 0.16)]
        case .stop: [buzz(at: 0, duration: 0.6)]
        case .turnLeft: [buzz(at: 0, duration: 0.3, intensity: 0.8), tap(at: 0.4)]
        case .turnRight: [tap(at: 0), buzz(at: 0.1, duration: 0.3, intensity: 0.8)]
        case .arrived: [tap(at: 0, intensity: 0.5), tap(at: 0.15, intensity: 0.75), tap(at: 0.3, intensity: 1)]
        }
    }
}

/// Short generated tones for users who chose "Tones". Mixes with other audio and ducks it briefly.
final class LiveTonesService: TonesServicing {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var buffers: [ToneCue: AVAudioPCMBuffer] = [:]

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        // (frequency Hz, duration s) notes per cue. Rising = good news, low = warning.
        let notes: [ToneCue: [(Double, Double)]] = [
            .headsUp: [(880, 0.09), (0, 0.05), (880, 0.09)],
            .stop: [(330, 0.45)],
            .turn: [(660, 0.12)],
            .arrived: [(523, 0.1), (659, 0.1), (784, 0.16)],
            .listening: [(988, 0.07)],
        ]
        for (cue, sequence) in notes { buffers[cue] = makeBuffer(sequence) }
    }

    func play(_ cue: ToneCue) {
        guard let buffer = buffers[cue] else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            if session.category != .playAndRecord {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers, .duckOthers])
            }
            try session.setActive(true)
            if !engine.isRunning { try engine.start() }
            player.scheduleBuffer(buffer, at: nil, options: .interrupts)
            player.play()
        } catch {
            Log.vision.error("Tone failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func makeBuffer(_ notes: [(frequency: Double, duration: Double)]) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let total = AVAudioFrameCount(notes.reduce(0) { $0 + $1.duration } * rate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total),
              let samples = buffer.floatChannelData?[0] else { return nil }
        var index = 0
        for note in notes {
            let count = Int(note.duration * rate)
            for i in 0..<count {
                // 5 ms fade in and out so notes don't click.
                let fade = min(1, Double(min(i, count - i)) / (0.005 * rate))
                let value = note.frequency == 0 ? 0 : sin(2 * .pi * note.frequency * Double(i) / rate) * 0.4 * fade
                samples[index] = Float(value)
                index += 1
            }
        }
        buffer.frameLength = AVAudioFrameCount(index)
        return buffer
    }
}
