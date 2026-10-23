import SwiftUI

extension Notification.Name {
    /// Posted with `userInfo: ["tab": "profile"]` to programmatically switch tabs from anywhere.
    static let x5SwitchTab = Notification.Name("x5.tab.switch")
}

enum X5AppTab: Int, CaseIterable, Identifiable {
    case home
    case courses
    case chats
    case hub
    case profile

    var id: Int { rawValue }

    var notificationKey: String {
        switch self {
        case .home: return "home"
        case .courses: return "courses"
        case .chats: return "chats"
        case .hub: return "hub"
        case .profile: return "profile"
        }
    }

    var titleKey: String {
        switch self {
        case .home: return "tab_home"
        case .courses: return "tab_courses"
        case .chats: return "tab_chats"
        case .hub: return "tab_hub"
        case .profile: return "tab_profile"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .courses: return "graduationcap.fill"
        case .chats: return "bubble.left.and.bubble.right.fill"
        case .hub: return "briefcase.fill"
        case .profile: return "person.crop.circle.fill"
        }
    }

    init?(notificationKey: String) {
        guard let tab = Self.allCases.first(where: { $0.notificationKey == notificationKey }) else {
            return nil
        }
        self = tab
    }
}

/// Five functional app tabs presented by the system iOS tab bar.
struct AppTabView: View {
    @EnvironmentObject private var loc: LocalizationService
    @StateObject private var deepLinkRouter = AppDeepLinkRouter.shared
    @State private var selectedTab: X5AppTab = .home

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView()
                .tabItem { Label(loc.t(X5AppTab.home.titleKey), systemImage: X5AppTab.home.icon) }
                .tag(X5AppTab.home)
                .onAppear { DiagnosticLogger.log(event: "home_appeared") }

            CoursesView()
                .tabItem { Label(loc.t(X5AppTab.courses.titleKey), systemImage: X5AppTab.courses.icon) }
                .tag(X5AppTab.courses)

            ChatsListView()
                .tabItem { Label(loc.t(X5AppTab.chats.titleKey), systemImage: X5AppTab.chats.icon) }
                .tag(X5AppTab.chats)

            HubView()
                .tabItem { Label(loc.t(X5AppTab.hub.titleKey), systemImage: X5AppTab.hub.icon) }
                .tag(X5AppTab.hub)

            ProfileView(showsDoneButton: false)
                .tabItem { Label(loc.t(X5AppTab.profile.titleKey), systemImage: X5AppTab.profile.icon) }
                .tag(X5AppTab.profile)
        }
        .tint(X5Style.blue)
        .onChange(of: selectedTab) { newValue in
            X5Feedback.selection()
            DiagnosticLogger.log(
                event: "tab_switched",
                extra: ["tab": String(newValue.rawValue)]
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .x5SwitchTab)) { note in
            guard
                let key = note.userInfo?["tab"] as? String,
                let tab = X5AppTab(notificationKey: key)
            else { return }
            selectedTab = tab
        }
        .onChange(of: deepLinkRouter.pendingHubTaskID) { taskID in
            if taskID != nil { selectedTab = .hub }
        }
        .onChange(of: deepLinkRouter.pendingChatID) { chatID in
            if chatID != nil { selectedTab = .chats }
        }
        .onAppear {
            if deepLinkRouter.pendingHubTaskID != nil {
                selectedTab = .hub
            } else if deepLinkRouter.pendingChatID != nil {
                selectedTab = .chats
            }
        }
    }
}
