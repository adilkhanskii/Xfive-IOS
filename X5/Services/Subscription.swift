import Foundation
import Combine

extension Notification.Name {
    static let x5UserDidSignOut = Notification.Name("x5.user.did_sign_out")
    /// Fired when CurrentUser.profile is loaded, created, or patched.
    /// `userInfo` carries only the evaluated `is_pro` flag, never the profile.
    static let x5ProfileDidUpdate = Notification.Name("x5.profile.did_update")
}

@MainActor
final class Subscription: ObservableObject {
    @Published private(set) var isPro: Bool = false

    private let key = "x5.subscription.is_pro"
    private let migrationKey = "x5.subscription.migrated_v14"
    private var observers = Set<AnyCancellable>()

    init() {
        // Migration: build 12 had a paywall that locally activated Pro on tap.
        // From build 14 onward, Pro state must come from a real receipt.
        // Force a one-time reset for users carrying that stale flag.
        if !UserDefaults.standard.bool(forKey: migrationKey) {
            UserDefaults.standard.removeObject(forKey: key)
            UserDefaults.standard.set(true, forKey: migrationKey)
        }
        isPro = UserDefaults.standard.bool(forKey: key)

        NotificationCenter.default.publisher(for: .x5UserDidSignOut)
            .sink { [weak self] _ in self?.reset() }
            .store(in: &observers)

        // Only the refreshed, account-fenced profile may activate cached Pro.
        // A delayed legacy purchase notification is not a profile snapshot.

        // CurrentUser posts this whenever profile loads / refreshes / patches.
        // Server `profiles.plan` is the single source of truth — the local
        // UserDefaults cache is reconciled here so SettingsView ("Pro активна")
        // and ProfileView (server `isPro`) never disagree.
        // Payload is only the already-evaluated paid-access flag (narrowed for
        // PII safety and inclusive of the subscription expiration date).
        NotificationCenter.default.publisher(for: .x5ProfileDidUpdate)
            .sink { [weak self] note in
                self?.syncIsPro(note.userInfo?["is_pro"] as? Bool ?? false)
            }
            .store(in: &observers)
    }

    /// Reactively syncs from a fresh profile load (e.g. on app launch / refresh).
    /// Treats a nil/missing `plan` as Free so a stale `isPro = true` from the
    /// build-12 paywall or an outdated IAP cache cannot survive a clean
    /// server-side state of "no plan column / null".
    func sync(from profile: UserProfile?) {
        syncIsPro(profile?.isPro ?? false)
    }

    /// Boolean entry point used by the notification observer — keeps the
    /// observer payload narrow (no full UserProfile broadcast).
    func syncIsPro(_ value: Bool) {
        if value != isPro { setPro(value) }
    }

    func reset() {
        isPro = false
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// Cache the already evaluated server profile entitlement.
    func setPro(_ value: Bool) {
        isPro = value
        UserDefaults.standard.set(value, forKey: key)
    }

    static let monthlyPrice = "2000 ₸"
    static let monthlyProductID = IAPService.proMonthlyProductID
}
