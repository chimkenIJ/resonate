import Foundation
import OSLog

/// Calls Resonate's Supabase Edge Functions. Guests can call them with the publishable key alone;
/// signed-in users also send their Auth0 token.
final class EdgeFunctionClient {
    private let baseURL: URL
    private let apiKey: String
    private let auth: any AuthServicing
    private let session: URLSession

    init(baseURL: URL, apiKey: String, auth: any AuthServicing, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.auth = auth
        self.session = session
    }

    private nonisolated struct ErrorBody: Decodable, Sendable {
        let error: String
        let message: String?
    }

    /// True when the functions run on a Mac on this network (development), not in the cloud.
    private var isLocalServer: Bool {
        guard let host = baseURL.host() else { return false }
        return host.hasSuffix(".local") || host == "localhost" || host.hasPrefix("127.")
            || host.hasPrefix("10.") || host.hasPrefix("192.168.") || host.hasPrefix("172.")
    }

    func post<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        _ function: String, body: Body, as: Response.Type, timeout: TimeInterval = 20
    ) async throws -> Response {
        try JSONDecoder.snakeCase.decode(Response.self, from: await postForData(function, body: body, timeout: timeout))
    }

    /// Raw response body (for audio).
    func postForData<Body: Encodable & Sendable>(_ function: String, body: Body, timeout: TimeInterval = 20) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: function))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        if let token = try? await auth.accessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder.snakeCase.encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed].contains(error.code) {
            throw AppError.offline
        } catch let error as URLError where [.timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(error.code) {
            Log.data.error("\(function, privacy: .public) unreachable at \(self.baseURL.absoluteString, privacy: .public): \(error.code.rawValue)")
            if isLocalServer {
                throw AppError.server(message: "I can't reach the map server on your Mac. Make sure the Mac is awake, the map server is running, and the phone and Mac are on the same Wi-Fi.")
            }
            throw AppError.server(message: "The map server isn't answering. Try again in a moment.")
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
            Log.data.error("\(function, privacy: .public) failed \(status): \(String(decoding: data.prefix(300), as: UTF8.self), privacy: .public)")
            if body?.error == "outside_georgia" { throw AppError.outsideGeorgia }
            throw AppError.server(message: body?.message ?? "Something went wrong. Try again in a moment.")
        }
        return data
    }
}

extension JSONEncoder {
    nonisolated static var snakeCase: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }
}

extension JSONDecoder {
    nonisolated static var snakeCase: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

// MARK: - Geocoding

final class LiveGeocodingService: GeocodingServicing {
    private let client: EdgeFunctionClient

    init(client: EdgeFunctionClient) {
        self.client = client
    }

    private nonisolated struct Request: Encodable, Sendable {
        let query: String
        let latitude: Double
        let longitude: Double
        let limit: Int
    }

    private nonisolated struct Response: Decodable, Sendable {
        nonisolated struct PlaceDTO: Decodable, Sendable {
            let id: String
            let name: String
            let address: String
            let latitude: Double
            let longitude: Double
            let distanceM: Double
        }
        let places: [PlaceDTO]
    }

    func search(_ query: String, near location: GeoPoint, limit: Int) async throws -> [Place] {
        guard GeorgiaRegion.contains(location) else { throw AppError.outsideGeorgia }
        let response = try await client.post(
            "geocode",
            body: Request(query: query, latitude: location.latitude, longitude: location.longitude, limit: limit),
            as: Response.self
        )
        return response.places.map {
            Place(id: $0.id, name: $0.name, address: $0.address,
                  coordinate: GeoPoint(latitude: $0.latitude, longitude: $0.longitude),
                  distanceMeters: $0.distanceM)
        }
    }
}

// MARK: - Routing

final class LiveRoutingService: RoutingServicing {
    private let client: EdgeFunctionClient

    init(client: EdgeFunctionClient) {
        self.client = client
    }

    private nonisolated struct Coordinate: Encodable, Sendable {
        let latitude: Double
        let longitude: Double
    }

    private nonisolated struct Request: Encodable, Sendable {
        nonisolated struct Preferences: Encodable, Sendable {
            let avoidSteps: Bool
            let maxIncline: Double
            let preferTactilePaving: Bool
            let preferAudioSignals: Bool
        }
        let origin: Coordinate
        let destination: Coordinate
        let preferences: Preferences
    }

    private nonisolated struct Response: Decodable, Sendable {
        nonisolated struct RouteDTO: Decodable, Sendable {
            nonisolated struct Step: Decodable, Sendable {
                let instruction: String
                let spokenInstruction: String?
                let alertInstruction: String?
                let distanceM: Double
                let maneuver: String
                let latitude: Double
                let longitude: Double
                let shapeIndex: Int?
            }
            nonisolated struct Feature: Decodable, Sendable {
                let kind: String
                let count: Int
            }
            nonisolated struct Point: Decodable, Sendable {
                let label: String?
                let kind: String?
                let latitude: Double
                let longitude: Double
            }
            let durationS: Double
            let distanceM: Double
            let isStepFree: Bool
            let polyline: [[Double]]
            let steps: [Step]
            let features: [Feature]
            let avoided: [Point]
            let hazards: [Point]
            nonisolated struct Entrance: Decodable, Sendable {
                let latitude: Double
                let longitude: Double
                let isMain: Bool
                let door: String?
            }
            let entrance: Entrance?
            let crossings: [Point]?
        }
        let route: RouteDTO
    }

    func route(from origin: GeoPoint, to destination: Place, preferences: RoutingPreferences) async throws -> Route {
        guard GeorgiaRegion.contains(origin), GeorgiaRegion.contains(destination.coordinate) else {
            throw AppError.outsideGeorgia
        }
        let dto = try await client.post(
            "route",
            body: Request(
                origin: Coordinate(latitude: origin.latitude, longitude: origin.longitude),
                destination: Coordinate(latitude: destination.coordinate.latitude, longitude: destination.coordinate.longitude),
                preferences: .init(
                    avoidSteps: preferences.avoidSteps,
                    maxIncline: preferences.maxIncline,
                    preferTactilePaving: preferences.preferTactilePaving,
                    preferAudioSignals: preferences.preferAudioSignals
                )
            ),
            as: Response.self
        ).route

        return Route(
            id: UUID(),
            destination: destination,
            durationSeconds: dto.durationS,
            distanceMeters: dto.distanceM,
            isStepFree: dto.isStepFree,
            features: dto.features.compactMap(Self.feature),
            steps: dto.steps.enumerated().map { index, step in
                RouteStep(
                    id: index,
                    instruction: RouteWording.relative(step.instruction),
                    distanceMeters: step.distanceM,
                    maneuver: Maneuver(rawValue: step.maneuver) ?? .straight,
                    start: GeoPoint(latitude: step.latitude, longitude: step.longitude),
                    spokenInstruction: step.spokenInstruction.map(RouteWording.relative),
                    alertInstruction: step.alertInstruction.map(RouteWording.relative),
                    shapeIndex: step.shapeIndex
                )
            },
            polyline: dto.polyline.compactMap { $0.count == 2 ? GeoPoint(latitude: $0[0], longitude: $0[1]) : nil },
            avoided: dto.avoided.enumerated().map { index, point in
                AvoidedHazard(id: index, label: point.label ?? "Stairs avoided",
                              coordinate: GeoPoint(latitude: point.latitude, longitude: point.longitude))
            },
            hazards: dto.hazards.compactMap { point in
                guard let kind = point.kind.flatMap(RouteHazard.Kind.init(rawValue:)) else { return nil }
                return RouteHazard(kind: kind, coordinate: GeoPoint(latitude: point.latitude, longitude: point.longitude))
            },
            crossings: (dto.crossings ?? []).map { GeoPoint(latitude: $0.latitude, longitude: $0.longitude) },
            entrance: dto.entrance.map {
                RouteEntrance(coordinate: GeoPoint(latitude: $0.latitude, longitude: $0.longitude), isMain: $0.isMain, door: $0.door)
            }
        )
    }

    private static func feature(_ dto: Response.RouteDTO.Feature) -> RouteFeature? {
        switch dto.kind {
        case "curb_ramps": .curbRamps
        case "audio_crossings": .audioCrossings
        case "tactile_paving": .tactilePaving
        case "elevators": .elevators(dto.count)
        case "steps": .steps(dto.count)
        case "raised_curbs": .raisedCurbs(dto.count)
        case "unverified_curbs": .unverifiedSegments
        default: nil
        }
    }
}
