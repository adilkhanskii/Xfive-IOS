import Foundation

/// Shared compile-time configuration for X5. Replaces 3+ duplicates of the
/// same Supabase URL/anonKey scattered across IAPService, UserProfileView,
/// OnboardingView. Single source of truth so future credential rotation
/// is a one-line change.
enum X5Config {
    static let supabaseBaseURL: URL = {
        // Hardcoded literal — Foundation guarantees this URL parses.
        // We still fall back rather than force-unwrap so the binary
        // stays crash-free even under bizarre runtime conditions.
        URL(string: "https://afwznqjpshybmqhlewmy.supabase.co") ?? URL(fileURLWithPath: "/")
    }()

    static let supabaseAnonKey: String =
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFmd3pucWpwc2h5Ym1xaGxld215Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzAzNTUxMTcsImV4cCI6MjA4NTkzMTExN30.p51iPiMEUSETS9Ot_qkmtA3IcqA23kadgoBLLQDXuL0"
}
