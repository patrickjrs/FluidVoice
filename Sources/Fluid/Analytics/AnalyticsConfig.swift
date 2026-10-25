import Foundation

struct AnalyticsConfig {
    let postHogApiKey: String
    let postHogHost: String

    /// Default ingestion host disabled for local-only privacy builds.
    nonisolated static let defaultEUHost = ""

    nonisolated static func fromBundle() -> AnalyticsConfig {
        return AnalyticsConfig(postHogApiKey: "", postHogHost: "")
    }

    nonisolated var isConfigured: Bool {
        false
    }
}
