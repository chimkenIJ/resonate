import Foundation
import OSLog
import Observation

/// Voice or text search for a destination. Shows the closest 3–5 results.
@Observable
final class DestinationSearchViewModel {
    enum Phase: Equatable {
        case idle, listening, searching, results
        case failed(String)
    }

    var query = "" {
        didSet {
            requestVersion += 1
            if !isListening {
                results = []
                phase = .idle
            }
        }
    }
    private(set) var results: [Place] = []
    private(set) var recentSearches: [String] = []
    private(set) var phase: Phase = .idle

    let resultLimit = 5

    private let recognizer: any SpeechRecognitionServicing
    private let geocoding: any GeocodingServicing
    private let location: any LocationServicing
    private let auth: any AuthServicing
    private let defaults: UserDefaults
    private var requestVersion = 0
    private var listenTask: Task<Void, Never>?
    private var handledListenRequest = 0

    init(services: AppServices, defaults: UserDefaults = .standard) {
        self.recognizer = services.speechRecognition
        self.geocoding = services.geocoding
        self.location = services.location
        self.auth = services.auth
        self.defaults = defaults
        refreshHistory()
    }

    var isListening: Bool { phase == .listening }

    private var historyKey: String {
        if case .signedIn(let user) = auth.state { return "search.history.\(user.id)" }
        return "search.history.guest"
    }

    func refreshHistory() {
        recentSearches = defaults.stringArray(forKey: historyKey) ?? []
    }

    var matchingRecentSearches: [String] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? recentSearches : recentSearches.filter { $0.localizedCaseInsensitiveContains(text) }
    }

    private func rememberSearch(_ text: String) {
        refreshHistory()
        recentSearches.removeAll { $0.caseInsensitiveCompare(text) == .orderedSame }
        recentSearches.insert(text, at: 0)
        recentSearches = Array(recentSearches.prefix(20))
        defaults.set(recentSearches, forKey: historyKey)
    }

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
        guard !text.isEmpty, phase != .searching else { return }
        guard text.count <= 200 else {
            fail(.server(message: "Use a place name up to 200 characters."))
            return
        }
        requestVersion += 1
        let version = requestVersion
        rememberSearch(text)
        phase = .searching
        do {
            let here = try await currentLocation(timeout: 8)
            guard GeorgiaRegion.contains(here) else { throw AppError.outsideGeorgia }
            let matches = try await geocoding.search(text, near: here, limit: resultLimit)
            guard version == requestVersion, !Task.isCancelled else { return }
            results = matches
            phase = .results
        } catch {
            guard version == requestVersion, !Task.isCancelled else { return }
            results = []
            fail((error as? AppError) ?? .server(message: "Search isn't working right now. Try again in a moment."))
        }
    }

    /// Search for the voice assistant: shows the results on this screen and returns them,
    /// or throws so the assistant can explain what went wrong.
    func searchQuietly(_ text: String) async throws -> [Place] {
        cancelListening()
        query = text
        let version = requestVersion
        rememberSearch(text)
        phase = .searching
        do {
            let here = try await currentLocation(timeout: 8)
            guard GeorgiaRegion.contains(here) else { throw AppError.outsideGeorgia }
            let matches = try await geocoding.search(text, near: here, limit: resultLimit)
            if version == requestVersion {
                results = matches
                phase = .results
            }
            return matches
        } catch {
            let appError = (error as? AppError) ?? .server(message: "Search isn't working right now. Try again in a moment.")
            if version == requestVersion {
                results = []
                fail(appError)
            }
            throw appError
        }
    }

    private func listen() async {
        guard await recognizer.requestAuthorization() else {
            fail(.permissionDenied(.speechRecognition))
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
                fail(.server(message: "I didn't catch that. Tap the microphone and try again."))
                return
            }
        }
        guard !Task.isCancelled else { return }
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fail(.server(message: "I didn't hear a place. Tap the microphone to try again."))
        } else {
            await search()
        }
    }

    /// The user's location, or an error if GPS doesn't answer in time (indoors, no signal).
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

    private func fail(_ error: AppError) {
        phase = .failed(error.spokenMessage)
    }
}
