import Foundation
import OSLog
import Observation

/// Voice or text search for a destination. Shows and reads aloud the closest 3–5 results.
@Observable
final class DestinationSearchViewModel {
    enum Phase: Equatable {
        case idle, listening, searching, results
        case failed(String)
    }

    var query = ""
    private(set) var results: [Place] = []
    private(set) var phase: Phase = .idle

    let resultLimit = 5

    private let recognizer: any SpeechRecognitionServicing
    private let geocoding: any GeocodingServicing
    private let location: any LocationServicing
    private let feedback: FeedbackCenter
    private var listenTask: Task<Void, Never>?
    private var handledListenRequest = 0

    init(services: AppServices, feedback: FeedbackCenter) {
        self.recognizer = services.speechRecognition
        self.geocoding = services.geocoding
        self.location = services.location
        self.feedback = feedback
    }

    var isListening: Bool { phase == .listening }

    /// Home's "Where do you want to go?" sends a request; each one is handled once.
    func handleListenRequest(_ request: Int) {
        guard request != handledListenRequest else { return }
        handledListenRequest = request
        startListening()
    }

    func toggleListening() {
        isListening ? stopListening() : startListening()
    }

    func startListening() {
        listenTask?.cancel()
        listenTask = Task { await listen() }
    }

    /// Mic off now; searches for whatever was heard so far.
    func stopListening() {
        recognizer.stop()
    }

    /// Mic off and nothing searched (for example, leaving the screen).
    func cancelListening() {
        guard isListening else { return }
        recognizer.cancel()
        listenTask?.cancel()
        phase = .idle
    }

    func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        phase = .searching
        do {
            results = try await places(matching: text)
            phase = .results
            await feedback.announce(spokenResults, priority: .info)
        } catch {
            results = []
            await fail(Self.appError(error))
        }
    }

    /// Search for the voice assistant: shows the results on this screen but doesn't read them out,
    /// because the assistant answers in its own words.
    func searchQuietly(_ text: String) async throws -> [Place] {
        cancelListening()
        query = text
        phase = .searching
        do {
            results = try await places(matching: text)
            phase = .results
            return results
        } catch {
            results = []
            let appError = Self.appError(error)
            phase = .failed(appError.spokenMessage)
            throw appError
        }
    }

    private func places(matching text: String) async throws -> [Place] {
        let here = try await currentLocation(timeout: 8)
        guard GeorgiaRegion.contains(here) else { throw AppError.outsideGeorgia }
        return try await geocoding.search(text, near: here, limit: resultLimit)
    }

    private static func appError(_ error: Error) -> AppError {
        (error as? AppError) ?? .server(message: "Search isn't working right now. Try again in a moment.")
    }

    private func listen() async {
        guard await recognizer.requestAuthorization() else {
            await fail(.permissionDenied(.speechRecognition))
            return
        }
        query = ""
        results = []
        phase = .listening
        do {
            for try await partial in recognizer.transcribe() {
                if Task.isCancelled { return }
                query = partial
            }
        } catch {
            // The recognizer often ends with an error right after the mic turns off. If it heard
            // something, search for that instead of throwing it away.
            Log.data.error("Speech recognition ended with: \(String(describing: error), privacy: .public)")
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await fail(.server(message: "I didn't catch that. Tap the microphone and try again."))
                return
            }
        }
        guard !Task.isCancelled else { return }
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            phase = .idle
            await feedback.announce("I didn't hear a place. Tap the microphone to try again.", priority: .info)
        } else {
            await search()
        }
    }

    /// The user's location, or a spoken error if GPS doesn't answer in time (indoors, no signal).
    private func currentLocation(timeout seconds: Double) async throws -> GeoPoint {
        let location = location
        return try await withThrowingTaskGroup(of: GeoPoint.self) { group in
            group.addTask { try await location.currentLocation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw AppError.server(message: "I couldn't find where you are. Try again near a window or outside.")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func fail(_ error: AppError) async {
        phase = .failed(error.spokenMessage)
        await feedback.announce(error.spokenMessage, priority: .info)
    }

    /// "Found 3 places, closest first. 1: Kroger, 1.4 kilometers away. ..."
    var spokenResults: String {
        let intro = results.count == 1 ? "Found 1 place." : "Found \(results.count) places, closest first."
        let items = results.enumerated().map { index, place in
            let distance = place.distanceMeters.map { ", \(DistanceText.spoken($0)) away" } ?? ""
            return "\(index + 1): \(place.name)\(distance)."
        }
        return ([intro] + items).joined(separator: " ")
    }
}
