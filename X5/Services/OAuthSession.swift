import Foundation
import UIKit
import GoogleSignIn

/// Google Sign-In via the official iOS SDK (GIDSignIn) — native sheet, no Safari.
/// Returns Google idToken; SupabaseClient.signInWithGoogle(idToken:) trades it for a session.
///
/// Why native instead of ASWebAuthenticationSession + Supabase /authorize:
/// - Web flow on iOS hits "access blocked" because our OAuth app is in production but
///   branding is not Google-verified. ASWebAuthenticationSession hides the
///   "Advanced → Continue" workaround so users get a hard block.
/// - GIDSignIn renders Google's own consent UI bypassing the unverified-app check.
@MainActor
final class OAuthSession {
    static let shared = OAuthSession()

    /// iOS OAuth Client ID (project x5-marketing-app, GCP Auth Platform → Clients → "iOS client 2").
    /// Type MUST be iOS — Web client IDs do not work with GIDSignIn.
    /// Public by design: also embedded in Info.plist URL scheme.
    private let iosClientId = "931639129066-ft7bod2n3ugi4cc3j1l68avcqtq3rv2j.apps.googleusercontent.com"

    /// Set the configuration once at init. Google's iOS SDK reads this when signIn() is called.
    private init() {
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: iosClientId)
    }

    /// Triggers Google's native sign-in sheet and returns the idToken.
    /// Throws OAuthError.cancelled if the user dismisses the sheet,
    /// OAuthError.noPresenter if the SwiftUI window hierarchy isn't ready.
    func googleIdToken() async throws -> String {
        guard let presenter = topViewController() else {
            throw OAuthError.noPresenter
        }
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
        guard let idToken = result.user.idToken?.tokenString else {
            throw OAuthError.noToken
        }
        return idToken
    }

    /// Walks the scene → window → root → presented/nav/tab chain to find a presenter.
    /// SwiftUI apps that use UIApplicationDelegateAdaptor often have a UIHostingController
    /// wrapped in nav/tab containers — naive presentedViewController traversal misses those.
    private func topViewController() -> UIViewController? {
        let root = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
            .first
        return resolveTop(root)
    }

    private func resolveTop(_ vc: UIViewController?) -> UIViewController? {
        guard let vc else { return nil }
        if let presented = vc.presentedViewController {
            return resolveTop(presented)
        }
        if let nav = vc as? UINavigationController {
            return resolveTop(nav.visibleViewController) ?? nav
        }
        if let tab = vc as? UITabBarController {
            return resolveTop(tab.selectedViewController) ?? tab
        }
        return vc
    }

    enum OAuthError: LocalizedError {
        case cancelled
        case noToken
        case noPresenter

        var errorDescription: String? {
            switch self {
            case .cancelled: return "Sign in cancelled"
            case .noToken: return "Google did not return an id token"
            case .noPresenter: return "Could not find a window to present the Google sheet"
            }
        }
    }
}
