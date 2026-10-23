import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var auth: Auth
    @EnvironmentObject private var currentUser: CurrentUser
    @EnvironmentObject private var subscription: Subscription
    @AppStorage("x5.face_id_enabled") private var faceIDEnabled = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var isLocked = false
    /// Timestamp when the app last went to background — used to re-lock only after a long absence.
    @State private var backgroundedAt: Date?
    /// Lock again only after this many seconds in background. Anything shorter = quick task switch.
    private let relockAfter: TimeInterval = 300 // 5 min
    /// True after first successful Face ID unlock in this app session.
    @State private var hasUnlockedThisSession = false
    @State private var routedUserId: String?
    @State private var profileRoutingError: String?

    var body: some View {
        ZStack {
            Group {
                if !auth.isAuthenticated {
                    LoginView()
                } else if routedUserId != auth.userId {
                    profileLoadingView
                } else if needsOnboarding {
                    OnboardingView()
                } else {
                    AppTabView()
                }
            }
            .animation(.easeInOut(duration: 0.2), value: auth.isAuthenticated)
            .animation(.easeInOut(duration: 0.2), value: routedUserId)
            .animation(.easeInOut(duration: 0.2), value: needsOnboarding)

            // Face ID gate — covers everything when locked
            if isLocked {
                AppLockView(isLocked: $isLocked)
                    .transition(.opacity)
            }
        }
        .task(id: auth.userId) { await refreshProfileBeforeRouting() }
        .onChange(of: isLocked) { locked in
            // Mark unlocked once so we don't re-prompt on every onAppear within this session.
            if !locked { hasUnlockedThisSession = true }
        }
        .onAppear {
            // Cold launch: lock once. After successful unlock the user won't see Face ID
            // again unless the app stays in background for `relockAfter` seconds.
            if faceIDEnabled && auth.isAuthenticated && !hasUnlockedThisSession {
                isLocked = true
            }
        }
        .onChange(of: scenePhase) { phase in
            guard faceIDEnabled, auth.isAuthenticated else { return }
            switch phase {
            case .background:
                backgroundedAt = Date()
            case .active:
                // Re-lock only if the app was in background long enough.
                if let t = backgroundedAt, Date().timeIntervalSince(t) >= relockAfter {
                    isLocked = true
                }
                backgroundedAt = nil
            default: break
            }
        }
    }

    private var profileLoadingView: some View {
        ZStack {
            X5Background()
            if let profileRoutingError {
                VStack(spacing: 16) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundColor(.white.opacity(0.86))
                    Text("Не удалось загрузить профиль")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text(profileRoutingError)
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.68))
                        .multilineTextAlignment(.center)
                    Button("Повторить") {
                        Task { await refreshProfileBeforeRouting() }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Выйти") {
                        Task { await auth.signOut() }
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
                .padding(24)
                .frame(maxWidth: 420)
            } else {
                ProgressView().controlSize(.large).tint(.white)
            }
        }
    }

    /// Onboarding is evaluated only against the freshly loaded signed-in user.
    private var needsOnboarding: Bool {
        guard let profile = currentUser.profile,
              let userId = auth.userId,
              profile.id.caseInsensitiveCompare(userId) == .orderedSame
        else { return false }
        let cleanName = (profile.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerName = cleanName.lowercased()
        let cleanNickname = (profile.nickname ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasRealName = cleanName.count >= 2 && lowerName != "user" && lowerName != "x5"
        let hasValidNickname = cleanNickname.range(of: "^[a-z0-9_]{3,}$", options: .regularExpression) != nil
        return !hasRealName || !hasValidNickname || (profile.userRole ?? "").isEmpty
    }

    private func refreshProfileBeforeRouting() async {
        routedUserId = nil
        profileRoutingError = nil
        guard auth.isAuthenticated, let uid = auth.userId else { return }
        guard let token = await auth.freshAccessToken() else {
            if auth.isAuthenticated, auth.userId == uid {
                profileRoutingError = "Не удалось обновить сессию. Проверьте интернет и повторите."
            }
            return
        }
        // Always reload — fixes "paid Pro but stayed Free" if the profile was cached before purchase.
        let loaded = await currentUser.load(userId: uid, accessToken: token)
        guard auth.isAuthenticated, auth.userId == uid else { return }
        guard loaded,
              let profile = currentUser.profile,
              profile.id.caseInsensitiveCompare(uid) == .orderedSame
        else {
            profileRoutingError = currentUser.error ?? "Сервер не вернул профиль текущего пользователя."
            return
        }
        subscription.sync(from: profile)
        routedUserId = uid
    }
}
