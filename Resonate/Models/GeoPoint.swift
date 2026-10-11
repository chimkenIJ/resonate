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

    /// Compass bearing to `other` in degrees (0 = north, 90 = east).
    func bearing(to other: GeoPoint) -> Double {
        let lat1 = latitude * .pi / 180, lat2 = other.latitude * .pi / 180
        let dLon = (other.longitude - longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let degrees = atan2(y, x) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    /// Meters to the closest point on the segment a–b. Uses a flat projection, accurate at walking scale.
    func distance(toSegmentFrom a: GeoPoint, to b: GeoPoint) -> Double {
        let metersPerDegreeLat = 111_320.0
        let metersPerDegreeLon = 111_320.0 * cos(latitude * .pi / 180)
        let ax = (a.longitude - longitude) * metersPerDegreeLon, ay = (a.latitude - latitude) * metersPerDegreeLat
        let bx = (b.longitude - longitude) * metersPerDegreeLon, by = (b.latitude - latitude) * metersPerDegreeLat
        let dx = bx - ax, dy = by - ay
        let lengthSquared = dx * dx + dy * dy
        let t = lengthSquared == 0 ? 0 : max(0, min(1, -(ax * dx + ay * dy) / lengthSquared))
        let px = ax + t * dx, py = ay + t * dy
        return (px * px + py * py).squareRoot()
    }
}

/// One GPS reading.
nonisolated struct LocationFix: Hashable, Sendable {
    var point: GeoPoint
    /// Horizontal accuracy in meters (lower is better).
    var accuracy: Double
    var timestamp: Date
    /// Direction of travel from GPS, compass degrees. Nil when standing still or unknown.
    var course: Double? = nil
    /// Meters per second. Nil when unknown.
    var speed: Double? = nil
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
