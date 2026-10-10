import Foundation

final class MockLocationService: LocationServicing {
    var location = SampleData.userLocation

    func requestAuthorization() async -> Bool { true }

    func currentLocation() async throws -> GeoPoint { location }

    func updates() -> AsyncStream<GeoPoint> {
        let start = location
        return AsyncStream { continuation in
            let task = Task {
                var point = start
                while !Task.isCancelled {
                    continuation.yield(point)
                    point.latitude -= 0.00005 // about 5 m south per tick
                    try? await Task.sleep(for: .seconds(2))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func headings() -> AsyncStream<Double> {
        AsyncStream { continuation in
            continuation.yield(180)
        }
    }
}

final class MockGeocodingService: GeocodingServicing {
    func search(_ query: String, near location: GeoPoint, limit: Int) async throws -> [Place] {
        try await Task.sleep(for: .milliseconds(350))
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }

        if SampleData.outOfAreaQueries.contains(where: needle.contains) || !GeorgiaRegion.contains(location) {
            throw AppError.outsideGeorgia
        }

        let matches = SampleData.places
            .filter { $0.name.lowercased().contains(needle) || $0.address.lowercased().contains(needle) }
            .map { place in
                var place = place
                place.distanceMeters = location.distance(to: place.coordinate)
                return place
            }
            .sorted { ($0.distanceMeters ?? 0) < ($1.distanceMeters ?? 0) }

        guard !matches.isEmpty else { throw AppError.noResults(query: query) }
        return Array(matches.prefix(limit))
    }
}

final class MockRoutingService: RoutingServicing {
    func route(from origin: GeoPoint, to destination: Place, preferences: RoutingPreferences) async throws -> Route {
        try await Task.sleep(for: .milliseconds(500))
        guard GeorgiaRegion.contains(origin), GeorgiaRegion.contains(destination.coordinate) else {
            throw AppError.outsideGeorgia
        }
        return SampleData.route(to: destination, from: origin)
    }
}
