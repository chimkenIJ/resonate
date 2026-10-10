import Foundation

/// Public client settings, read from ResonateConfig.plist in the app bundle.
/// None of these are secrets: the Supabase publishable key is safe in the app because every
/// table has Row Level Security, and third-party API keys live only in Edge Functions.
/// Copy config/ResonateConfig.example.plist to Resonate/Resources/ResonateConfig.plist (gitignored).
nonisolated struct AppConfig: Sendable {
    let supabaseURL: URL
    let supabaseKey: String
    let auth0Domain: String
    let auth0ClientID: String
    /// Auth0 API identifier. Required so the access token is a JWT that Supabase can verify.
    let auth0Audience: String
    /// Edge Functions base URL. Defaults to the project's; set FunctionsURL to test against
    /// `supabase functions serve` on your Mac.
    let functionsURL: URL
    /// API key for `functionsURL`. Defaults to SupabaseKey; the local stack has its own key.
    let functionsKey: String

    /// Nil when the file is missing or still has placeholder values; the app then runs on mocks.
    static func load(from bundle: Bundle = .main) -> AppConfig? {
        guard let url = bundle.url(forResource: "ResonateConfig", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        else { return nil }

        func value(_ key: String) -> String? {
            guard let raw = values[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty, !raw.contains("YOUR_") else { return nil }
            return raw
        }

        guard let urlString = value("SupabaseURL"), let supabaseURL = URL(string: urlString),
              let supabaseKey = value("SupabaseKey"),
              let auth0Domain = value("Auth0Domain"),
              let auth0ClientID = value("Auth0ClientID"),
              let auth0Audience = value("Auth0Audience")
        else { return nil }

        return AppConfig(
            supabaseURL: supabaseURL,
            supabaseKey: supabaseKey,
            auth0Domain: auth0Domain,
            auth0ClientID: auth0ClientID,
            auth0Audience: auth0Audience,
            functionsURL: value("FunctionsURL").flatMap(URL.init(string:)) ?? supabaseURL.appending(path: "functions/v1"),
            functionsKey: value("FunctionsKey") ?? supabaseKey
        )
    }
}
