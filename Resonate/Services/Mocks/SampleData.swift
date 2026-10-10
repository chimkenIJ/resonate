import CoreGraphics
import Foundation

/// Fixed data for mocks and previews. Coordinates are around Georgia Tech in Midtown Atlanta.
nonisolated enum SampleData {
    static let userLocation = GeoPoint(latitude: 33.7756, longitude: -84.3963)

    static let places: [Place] = [
        Place(id: "mock:skiles", name: "Skiles Classroom Building", address: "686 Cherry St NW, Atlanta", coordinate: GeoPoint(latitude: 33.7737, longitude: -84.3962)),
        Place(id: "mock:clough", name: "Clough Learning Commons", address: "266 4th St NW, Atlanta", coordinate: GeoPoint(latitude: 33.7748, longitude: -84.3964)),
        Place(id: "mock:howey", name: "Howey Physics Building", address: "837 State St NW, Atlanta", coordinate: GeoPoint(latitude: 33.7774, longitude: -84.3989)),
        Place(id: "mock:mse", name: "Molecular Science and Engineering", address: "901 Atlantic Dr NW, Atlanta", coordinate: GeoPoint(latitude: 33.7797, longitude: -84.3966)),
        Place(id: "mock:crc", name: "Campus Recreation Center", address: "750 Ferst Dr NW, Atlanta", coordinate: GeoPoint(latitude: 33.7754, longitude: -84.4036)),
        Place(id: "mock:kroger-midtown", name: "Kroger", address: "725 Ponce De Leon Ave NE, Atlanta", coordinate: GeoPoint(latitude: 33.7740, longitude: -84.3660)),
        Place(id: "mock:kroger-west", name: "Kroger", address: "800 Glenwood Ave SE, Atlanta", coordinate: GeoPoint(latitude: 33.7400, longitude: -84.3580)),
        Place(id: "mock:kroger-atlantic", name: "Kroger", address: "1715 Howell Mill Rd NW, Atlanta", coordinate: GeoPoint(latitude: 33.8030, longitude: -84.4130)),
        Place(id: "mock:publix", name: "Publix at Atlantic Station", address: "1380 Atlantic Dr NW, Atlanta", coordinate: GeoPoint(latitude: 33.7929, longitude: -84.3969)),
        Place(id: "mock:north-ave", name: "North Avenue MARTA Station", address: "713 W Peachtree St NE, Atlanta", coordinate: GeoPoint(latitude: 33.7716, longitude: -84.3870)),
        Place(id: "mock:midtown", name: "Midtown MARTA Station", address: "41 10th St NE, Atlanta", coordinate: GeoPoint(latitude: 33.7810, longitude: -84.3864)),
        Place(id: "mock:piedmont", name: "Piedmont Park", address: "400 Park Dr NE, Atlanta", coordinate: GeoPoint(latitude: 33.7851, longitude: -84.3738)),
        Place(id: "mock:ponce-city", name: "Ponce City Market", address: "675 Ponce De Leon Ave NE, Atlanta", coordinate: GeoPoint(latitude: 33.7726, longitude: -84.3656)),
        Place(id: "mock:starbucks", name: "Starbucks", address: "650 Ferst Dr NW, Atlanta", coordinate: GeoPoint(latitude: 33.7752, longitude: -84.3990)),
    ]

    /// Places whose name or address mention something outside Georgia, to exercise the out-of-area error.
    static let outOfAreaQueries = ["chattanooga", "birmingham", "nashville", "charlotte", "jacksonville", "tbilisi"]

    // MARK: Saved places

    static let classesFolderID = UUID(uuidString: "6F0C5E2A-1B7D-4C55-9A41-000000000001")!

    static let folders: [PlaceFolder] = [
        PlaceFolder(id: classesFolderID, name: "Classes", accent: .slate, icon: .classes, placeCount: 5),
        PlaceFolder(id: UUID(uuidString: "6F0C5E2A-1B7D-4C55-9A41-000000000002")!, name: "Home", accent: .sand, icon: .home, placeCount: 2),
        PlaceFolder(id: UUID(uuidString: "6F0C5E2A-1B7D-4C55-9A41-000000000003")!, name: "Food", accent: .clay, icon: .food, placeCount: 3),
        PlaceFolder(id: UUID(uuidString: "6F0C5E2A-1B7D-4C55-9A41-000000000004")!, name: "Gym", accent: .mauve, icon: .gym, placeCount: 2),
        PlaceFolder(id: UUID(uuidString: "6F0C5E2A-1B7D-4C55-9A41-000000000005")!, name: "Friends", accent: .rose, icon: .friends, placeCount: 4),
        PlaceFolder(id: UUID(uuidString: "6F0C5E2A-1B7D-4C55-9A41-000000000006")!, name: "Errands", accent: .sage, icon: .errands, placeCount: 3),
    ]

    static let classes: [SavedPlace] = [
        saved("Calculus", "Skiles Classroom Building", 33.7737, -84.3962, "12 min · step-free"),
        saved("Biology", "Cherry Emerson Building", 33.7781, -84.3974, "8 min · 1 elevator"),
        saved("English", "Clough Learning Commons", 33.7748, -84.3964, "6 min · step-free"),
        saved("Chemistry lab", "Molecular Science and Engineering", 33.7797, -84.3966, "15 min · curb ramps"),
        saved("Physics", "Howey Physics Building", 33.7774, -84.3989, "10 min · step-free"),
    ]

    private static func saved(_ name: String, _ building: String, _ lat: Double, _ lon: Double, _ summary: String) -> SavedPlace {
        SavedPlace(
            id: UUID(),
            folderID: classesFolderID,
            place: Place(id: "mock:\(name.lowercased())", name: name, address: building, coordinate: GeoPoint(latitude: lat, longitude: lon)),
            routeSummary: summary
        )
    }

    // MARK: Routing

    static func route(to destination: Place, from origin: GeoPoint = userLocation) -> Route {
        let distance = origin.distance(to: destination.coordinate)
        let walking = distance * 1.3
        let corner = GeoPoint(latitude: origin.latitude, longitude: destination.coordinate.longitude)
        return Route(
            id: UUID(),
            destination: destination,
            durationSeconds: max(60, walking / 1.1),
            distanceMeters: walking,
            isStepFree: true,
            features: [.curbRamps, .audioCrossings, .elevators(1)],
            steps: [
                RouteStep(id: 0, instruction: "Straight, then turn right", distanceMeters: 40, maneuver: .straight, start: origin),
                RouteStep(id: 1, instruction: "Cross at the audio signal", distanceMeters: 90, maneuver: .audioCrossing, start: corner),
                RouteStep(id: 2, instruction: "Turn left onto the ramp", distanceMeters: 60, maneuver: .left, start: corner),
                RouteStep(id: 3, instruction: "Arrive at \(destination.name)", distanceMeters: 0, maneuver: .arrive, start: destination.coordinate),
            ],
            polyline: [origin, corner, destination.coordinate],
            // Off to the side of the route, where a shorter path would have used stairs.
            avoided: [AvoidedHazard(id: 0, label: "Stairs avoided", coordinate: GeoPoint(latitude: (origin.latitude + destination.coordinate.latitude) / 2, longitude: origin.longitude - 0.0012))]
        )
    }

    // MARK: Detection

    static let outdoorFrames: [DetectionFrame] = [
        DetectionFrame(objects: [
            DetectedObject(label: "Bike", category: .vehicle, confidence: 0.91, boundingBox: CGRect(x: 0.17, y: 0.34, width: 0.32, height: 0.18), distanceMeters: 2),
            DetectedObject(label: "Sign", category: .sign, confidence: 0.84, boundingBox: CGRect(x: 0.60, y: 0.38, width: 0.20, height: 0.12), distanceMeters: 6),
            DetectedObject(label: "Curb drop", category: .dropOff, confidence: 0.77, boundingBox: CGRect(x: 0.08, y: 0.64, width: 0.85, height: 0.04), distanceMeters: 4),
        ], depthSource: .lidar),
        DetectionFrame(objects: [
            DetectedObject(label: "Person", category: .person, confidence: 0.95, boundingBox: CGRect(x: 0.62, y: 0.30, width: 0.18, height: 0.40), distanceMeters: 3),
            DetectedObject(label: "Pole", category: .obstacle, confidence: 0.80, boundingBox: CGRect(x: 0.42, y: 0.20, width: 0.06, height: 0.50), distanceMeters: 5),
        ], depthSource: .lidar),
        DetectionFrame(objects: [], depthSource: .lidar),
    ]

    static let indoorSnapshots: [IndoorSnapshot] = [
        IndoorSnapshot(
            objects: [
                DetectedObject(label: "Wall", category: .wall, confidence: 0.99, boundingBox: CGRect(x: 0.02, y: 0.13, width: 0.31, height: 0.45), distanceMeters: 1),
                DetectedObject(label: "Door", category: .door, confidence: 0.93, boundingBox: CGRect(x: 0.42, y: 0.22, width: 0.16, height: 0.17), distanceMeters: 6),
                DetectedObject(label: "Chair", category: .furniture, confidence: 0.88, boundingBox: CGRect(x: 0.62, y: 0.44, width: 0.23, height: 0.11), distanceMeters: 2),
            ],
            headline: "Chair 2 steps ahead, on your right.",
            guidance: "Walk straight. Wall stays on your left. Door is open ahead.",
            guidanceIcon: .straight,
            miniMap: [
                MiniMapItem(category: .wall, rect: CGRect(x: 0.10, y: 0.10, width: 0.08, height: 0.80)),
                MiniMapItem(category: .door, rect: CGRect(x: 0.42, y: 0.08, width: 0.19, height: 0.06)),
                MiniMapItem(category: .furniture, rect: CGRect(x: 0.60, y: 0.46, width: 0.17, height: 0.17)),
            ]
        ),
    ]
}
