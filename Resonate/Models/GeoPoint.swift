import Foundation
import CoreLocation

/// A WGS84 coordinate. Kept free of CoreLocation so models stay Codable and Sendable.
nonisolated struct GeoPoint: Codable, Hashable, Sendable {
    var latitude: Double
    var longitude: Double

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Great-circle distance in meters (haversine).
    func distance(to other: GeoPoint) -> Double {
        let earthRadius = 6_371_000.0
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let dLat = (other.latitude - latitude) * .pi / 180
        let dLon = (other.longitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return earthRadius * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}

/// The only area Resonate has map data for: the US state of Georgia
/// (Geofabrik north-america/us/georgia). This box is a fast first check;
/// the backend also tests against the real state outline in PostGIS.
nonisolated enum GeorgiaRegion {
    static let minLatitude = 30.3558
    static let maxLatitude = 35.0008
    static let minLongitude = -85.6052
    static let maxLongitude = -80.7514

    static func contains(_ point: GeoPoint) -> Bool {
        (minLatitude...maxLatitude).contains(point.latitude)
            && (minLongitude...maxLongitude).contains(point.longitude)
    }
}
