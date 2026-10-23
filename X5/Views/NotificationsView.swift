import SwiftUI

struct NotificationsView: View {
    @EnvironmentObject private var auth: Auth
    @EnvironmentObject private var loc: LocalizationService
    @Environment(\.dismiss) private var dismiss
    @StateObject private var service = NotificationsService()

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.04, green: 0.05, blue: 0.10).ignoresSafeArea()
                content
            }
            .navigationTitle(loc.t("notif_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(loc.t("btn_done")) { dismiss() }
                }
            }
            .task { await reload() }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var content: some View {
        if service.items.isEmpty && !service.isLoading {
            emptyState
        } else {
            List {
                ForEach(service.items) { item in
                    Button {
                        open(item)
                    } label: {
                        NotificationRow(item: item)
                    }
                    .buttonStyle(.plain)
                    .disabled(AppDeepLinkParser.parse(notification: item) == nil)
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(Color.white.opacity(0.08))
                        .task { await markRead(item) }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await reload() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "bell")
                .font(.system(size: 38, weight: .light))
                .foregroundColor(.white.opacity(0.4))
            Text(loc.t("notif_empty"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
            Text(loc.t("notif_empty_desc"))
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private func reload() async {
        guard let uid = auth.userId, let token = await auth.freshAccessToken() else { return }
        await service.load(userId: uid, accessToken: token)
    }

    private func markRead(_ item: AppNotification) async {
        guard let token = await auth.freshAccessToken() else { return }
        await service.markRead(item, accessToken: token)
    }

    private func open(_ item: AppNotification) {
        guard let link = AppDeepLinkParser.parse(notification: item) else { return }
        AppDeepLinkRouter.shared.route(link)
        dismiss()
    }
}

private struct NotificationRow: View {
    let item: AppNotification
    @EnvironmentObject private var loc: LocalizationService

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 36, height: 36)
                .background(item.isRead ? Color.white.opacity(0.08) : accent)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(displayTitle)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                    Spacer()
                    if let time = relativeTime(item.createdAt) {
                        Text(time)
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.42))
                    }
                }
                if let body = item.body, !body.isEmpty {
                    Text(body)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.62))
                        .lineLimit(3)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var icon: String {
        switch item.type {
        case "portfolio_like", "like": return "heart.fill"
        case "follow", "new_follower", "follower": return "person.badge.plus"
        case "followed_user_posted": return "person.crop.circle.badge.plus"
        case "message", "chat_message", "new_message": return "message.fill"
        default: return "bell.fill"
        }
    }

    private var accent: Color {
        switch item.type {
        case "portfolio_like", "like": return .pink.opacity(0.95)
        case "follow", "new_follower", "follower", "followed_user_posted": return .cyan.opacity(0.85)
        case "message", "chat_message", "new_message": return X5Style.blue.opacity(0.95)
        default: return X5Style.blue.opacity(0.75)
        }
    }

    private var displayTitle: String {
        switch item.type {
        case "message", "chat_message", "new_message":
            return item.title == "New message" ? loc.t("notif_message_title") : item.title
        case "portfolio_like", "like":
            return item.title.isEmpty ? loc.t("notif_like_title") : item.title
        case "follow", "new_follower", "follower":
            return item.title.isEmpty ? loc.t("notif_follow_title") : item.title
        case "followed_user_posted":
            return item.title.isEmpty ? loc.t("notif_followed_post_title") : item.title
        default:
            return item.title
        }
    }

    private func relativeTime(_ iso: String?) -> String? {
        guard let iso else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
