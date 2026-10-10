import Foundation

/// Errors shown and spoken to the user. Every case has a plain-language sentence.
nonisolated enum AppError: LocalizedError, Equatable, Sendable {
    case outsideGeorgia
    case noResults(query: String)
    case noRoute
    case offline
    case permissionDenied(Permission)
    case unsupportedDevice(feature: String)
    case server(message: String)

    nonisolated enum Permission: String, Sendable {
        case camera, microphone, speechRecognition, location
    }

    var spokenMessage: String {
        switch self {
        case .outsideGeorgia:
            "That place is outside Georgia. Resonate only has maps for Georgia right now."
        case .noResults(let query):
            "I couldn't find \(query) near you. Try saying it another way."
        case .noRoute:
            "I couldn't find an accessible walking route there."
        case .offline:
            "You're offline. Obstacle alerts still work, but search and routes need a connection."
        case .permissionDenied(let permission):
            "Resonate needs \(permission.spokenName) access. You can turn it on in Settings."
        case .unsupportedDevice(let feature):
            "\(feature) needs an iPhone with a LiDAR sensor."
        case .server(let message):
            message
        }
    }

    var errorDescription: String? { spokenMessage }
}

nonisolated extension AppError.Permission {
    var spokenName: String {
        switch self {
        case .camera: "camera"
        case .microphone: "microphone"
        case .speechRecognition: "speech recognition"
        case .location: "location"
        }
    }
}
