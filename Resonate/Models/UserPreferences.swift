import Foundation

/// Needs chosen on the Personalize screen. Each one turns on a feature module.
nonisolated enum AssistNeed: String, CaseIterable, Codable, Hashable, Sendable {
    case gettingAround
    case colors

    var title: String {
        switch self {
        case .gettingAround: "Getting around"
        case .colors: "Telling colors apart"
        }
    }

    var subtitle: String {
        switch self {
        case .gettingAround: "Obstacles and routes"
        case .colors: "Name any color you point at"
        }
    }

    var systemImage: String {
        switch self {
        case .gettingAround: "location"
        case .colors: "paintpalette"
        }
    }

    var accent: Accent {
        switch self {
        case .gettingAround: .sage
        case .colors: .mauve
        }
    }
}

/// How alerts reach the user.
nonisolated enum AlertChannel: String, CaseIterable, Codable, Hashable, Sendable {
    case voice, buzzes, tones

    var title: String {
        switch self {
        case .voice: "Voice"
        case .buzzes: "Buzzes"
        case .tones: "Tones"
        }
    }

    var accent: Accent {
        switch self {
        case .voice: .sand
        case .buzzes: .clay
        case .tones: .slate
        }
    }
}

nonisolated struct UserPreferences: Codable, Hashable, Sendable {
    var needs: Set<AssistNeed> = [.gettingAround]
    var alertChannels: Set<AlertChannel> = [.voice, .buzzes]
    var routing = RoutingPreferences()

    /// "Spoken + 2 buzzes", shown in the alert sheet.
    func deliveryDescription(for severity: AlertSeverity) -> String {
        var parts: [String] = []
        if alertChannels.contains(.voice) { parts.append("Spoken") }
        if alertChannels.contains(.buzzes), let cue = severity.hapticCue {
            parts.append(cue == .headsUp ? "2 buzzes" : "long buzz")
        }
        if alertChannels.contains(.tones), severity != .info { parts.append("tone") }
        return parts.isEmpty ? "Silent" : parts.joined(separator: " + ")
    }
}

/// The signed-in user. `id` is the Auth0 `sub`, which is also the RLS key in Supabase.
nonisolated struct UserAccount: Codable, Hashable, Sendable {
    var id: String
    var name: String?
    var email: String?
}

nonisolated enum AuthState: Hashable, Sendable {
    case signedOut
    /// Using the app without an account. Safety features work; saved places stay on this phone.
    case guest
    case signedIn(UserAccount)
}
