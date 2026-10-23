import SwiftUI

/// List of all chats for the current user.
struct ChatsListView: View {
    @EnvironmentObject private var auth: Auth
    @EnvironmentObject private var loc: LocalizationService
    @StateObject private var service = ChatsService()
    @StateObject private var deepLinkRouter = AppDeepLinkRouter.shared
    @State private var profiles: [String: UserProfile] = [:]
    /// Bumped to force `visibleChats` recomputation after archive/mute/hide.
    /// `ChatsLocalState` is a static enum so the view doesn't observe it.
    @State private var localStateTick: Int = 0
    @State private var showArchive: Bool = false
    @State private var deepLinkedChat: ChatRoom?
    @State private var deepLinkError: String?

    var body: some View {
        NavigationStack {
            Group {
                if service.isLoading && service.chats.isEmpty {
                    ProgressView().tint(.accentColor).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if visibleChats.isEmpty {
                    EmptyState(
                        systemImage: "bubble.left.and.bubble.right",
                        title: loc.t("chats_empty_title"),
                        subtitle: loc.t("chats_empty_sub")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    chatList
                }
            }
            .background { X5Background() }
            .navigationTitle(loc.t("chats_title"))
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .task {
                service.configureAccessTokenProvider(auth: auth)
                await reload()
            }
            .onChange(of: deepLinkRouter.pendingChatID) { chatID in
                guard chatID != nil else { return }
                Task { await openPendingChatIfNeeded() }
            }
            .navigationDestination(isPresented: Binding(
                get: { deepLinkedChat != nil },
                set: { if !$0 { deepLinkedChat = nil } }
            )) {
                if let chat = deepLinkedChat {
                    let peerID = chat.otherParticipantId(currentUser: auth.userId ?? "") ?? ""
                    ChatThreadView(chat: chat, initialOther: profiles[peerID])
                }
            }
            .alert("Чат не открылся", isPresented: Binding(
                get: { deepLinkError != nil },
                set: { if !$0 { deepLinkError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deepLinkError ?? "")
            }
        }
    }

    @ViewBuilder
    private var chatList: some View {
        List {
            // Archive entry — only when the user actually has archived chats,
            // mirrors WhatsApp/Telegram pattern.
            if !archivedChats.isEmpty {
                Section {
                    NavigationLink {
                        ArchivedChatsView(
                            chats: archivedChats,
                            profiles: profiles,
                            currentUserId: auth.userId ?? "",
                            onChange: { localStateTick &+= 1 }
                        )
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "archivebox.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.white.opacity(0.6))
                                .frame(width: 44, height: 44)
                                .background(Color.white.opacity(0.06))
                                .clipShape(Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(loc.t("chats_archive"))
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.white)
                                Text("\(archivedChats.count)")
                                    .font(.system(size: 13))
                                    .foregroundColor(.white.opacity(0.55))
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(Color.white.opacity(0.04))
                }
            }

            ForEach(visibleChats) { chat in
                let otherId = chat.otherParticipantId(currentUser: auth.userId ?? "") ?? ""
                ChatRowLink(
                    chat: chat,
                    currentUserId: auth.userId ?? "",
                    other: profiles[otherId],
                    peerId: otherId
                )
                .listRowBackground(Color.white.opacity(0.04))
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        ChatsLocalState.hide(chat.id)
                        localStateTick &+= 1
                    } label: {
                        Label(loc.t("chats_delete"), systemImage: "trash")
                    }
                    Button {
                        ChatsLocalState.archive(chat.id)
                        localStateTick &+= 1
                    } label: {
                        Label(loc.t("chats_archive"), systemImage: "archivebox")
                    }
                    .tint(.indigo)
                }
                .swipeActions(edge: .leading) {
                    let pinned = ChatsLocalState.isPinned(chat.id)
                    Button {
                        if pinned { ChatsLocalState.unpin(chat.id) }
                        else { ChatsLocalState.pin(chat.id) }
                        localStateTick &+= 1
                    } label: {
                        Label(
                            pinned ? loc.t("chats_unpin") : loc.t("chats_pin"),
                            systemImage: pinned ? "pin.slash" : "pin"
                        )
                    }
                    .tint(.blue)
                    let muted = ChatsLocalState.isMuted(chat.id)
                    Button {
                        if muted { ChatsLocalState.unmute(chat.id) }
                        else { ChatsLocalState.mute(chat.id) }
                        localStateTick &+= 1
                    } label: {
                        Label(
                            muted ? loc.t("chats_unmute") : loc.t("chats_mute"),
                            systemImage: muted ? "bell" : "bell.slash"
                        )
                    }
                    .tint(.accentColor)
                }
                .contextMenu {
                    let pinned = ChatsLocalState.isPinned(chat.id)
                    Button {
                        if pinned { ChatsLocalState.unpin(chat.id) }
                        else { ChatsLocalState.pin(chat.id) }
                        localStateTick &+= 1
                    } label: {
                        Label(
                            pinned ? loc.t("chats_unpin") : loc.t("chats_pin"),
                            systemImage: pinned ? "pin.slash" : "pin"
                        )
                    }
                    let muted = ChatsLocalState.isMuted(chat.id)
                    Button {
                        if muted { ChatsLocalState.unmute(chat.id) }
                        else { ChatsLocalState.mute(chat.id) }
                        localStateTick &+= 1
                    } label: {
                        Label(
                            muted ? loc.t("chats_unmute") : loc.t("chats_mute"),
                            systemImage: muted ? "bell" : "bell.slash"
                        )
                    }
                    Button {
                        ChatsLocalState.archive(chat.id)
                        localStateTick &+= 1
                    } label: {
                        Label(loc.t("chats_archive"), systemImage: "archivebox")
                    }
                    Button(role: .destructive) {
                        ChatsLocalState.hide(chat.id)
                        localStateTick &+= 1
                    } label: {
                        Label(loc.t("chats_delete"), systemImage: "trash")
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        .refreshable { await reload() }
        // Reading the tick here makes SwiftUI reread visibleChats / archivedChats
        // whenever local state mutations bump it.
        .id(localStateTick)
    }

    /// Server chats minus blocked peers and minus locally-hidden chats.
    private var nonBlocked: [ChatRoom] {
        let me = auth.userId ?? ""
        return service.chats.filter { chat in
            if ChatsLocalState.isHidden(chat.id) { return false }
            guard chat.isValidPeerChat(currentUser: me),
                  let otherId = chat.otherParticipantId(currentUser: me)
            else { return false }
            return !BlockList.contains(otherId)
        }
    }

    /// Active inbox — excludes archived chats. Pinned chats float to the top
    /// in their original recency order, regular chats follow underneath.
    private var visibleChats: [ChatRoom] {
        let inbox = nonBlocked.filter { !ChatsLocalState.isArchived($0.id) }
        let pinned = inbox.filter { ChatsLocalState.isPinned($0.id) }
        let regular = inbox.filter { !ChatsLocalState.isPinned($0.id) }
        return pinned + regular
    }

    /// Archived bucket shown under the "Архив" entry.
    private var archivedChats: [ChatRoom] {
        nonBlocked.filter { ChatsLocalState.isArchived($0.id) }
    }

    private func reload() async {
        guard let uid = auth.userId, let token = auth.accessToken else { return }
        await service.loadChats(currentUserId: uid, accessToken: token)
        // Pre-load profiles of all peers so rows show name + avatar instead of "?"
        for chat in service.chats {
            guard let otherId = chat.otherParticipantId(currentUser: uid),
                  profiles[otherId] == nil else { continue }
            if let p = await service.loadPublicProfile(userId: otherId, accessToken: token) {
                profiles[otherId] = p
            }
        }
        await openPendingChatIfNeeded()
    }

    private func openPendingChatIfNeeded() async {
        guard let chatID = deepLinkRouter.pendingChatID,
              let uid = auth.userId,
              let token = await auth.freshAccessToken()
        else { return }
        let room: ChatRoom?
        if let loadedRoom = service.chats.first(where: { $0.id == chatID }) {
            room = loadedRoom
        } else {
            room = await service.loadChat(chatId: chatID, accessToken: token)
        }
        guard let room, room.isValidPeerChat(currentUser: uid) else {
            deepLinkError = "Чат недоступен или был удалён."
            deepLinkRouter.consumeChat(id: chatID)
            return
        }
        if let peerID = room.otherParticipantId(currentUser: uid), profiles[peerID] == nil {
            profiles[peerID] = await service.loadPublicProfile(userId: peerID, accessToken: token)
        }
        deepLinkedChat = room
        deepLinkRouter.consumeChat(id: chatID)
    }
}

/// Extracted to keep the main list builder readable. `NavigationLink` wrapping
/// a custom row label needs its own scope so swipeActions / contextMenu attach
/// cleanly without confusing the gesture system.
private struct ChatRowLink: View {
    let chat: ChatRoom
    let currentUserId: String
    let other: UserProfile?
    let peerId: String

    var body: some View {
        NavigationLink {
            ChatThreadView(chat: chat, initialOther: other)
        } label: {
            ChatRow(chat: chat,
                    currentUserId: currentUserId,
                    other: other,
                    peerId: peerId)
        }
    }
}

/// Standalone screen for archived chats. Same row look as the inbox, with
/// a swipe-action to unarchive (back to inbox) or fully delete.
private struct ArchivedChatsView: View {
    let chats: [ChatRoom]
    let profiles: [String: UserProfile]
    let currentUserId: String
    let onChange: () -> Void
    @EnvironmentObject private var loc: LocalizationService
    @State private var tick: Int = 0

    var body: some View {
        Group {
            if chats.isEmpty || tick < 0 /* never true; tick triggers reread */ {
                EmptyState(
                    systemImage: "archivebox",
                    title: loc.t("chats_archive_empty_title"),
                    subtitle: loc.t("chats_archive_empty_sub")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(chats.filter { !ChatsLocalState.isHidden($0.id) && ChatsLocalState.isArchived($0.id) }) { chat in
                        let otherId = chat.otherParticipantId(currentUser: currentUserId) ?? ""
                        ChatRowLink(chat: chat,
                                    currentUserId: currentUserId,
                                    other: profiles[otherId],
                                    peerId: otherId)
                            .listRowBackground(Color.white.opacity(0.04))
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    ChatsLocalState.hide(chat.id)
                                    tick &+= 1
                                    onChange()
                                } label: {
                                    Label(loc.t("chats_delete"), systemImage: "trash")
                                }
                                Button {
                                    ChatsLocalState.unarchive(chat.id)
                                    tick &+= 1
                                    onChange()
                                } label: {
                                    Label(loc.t("chats_unarchive"), systemImage: "tray.and.arrow.up")
                                }
                                .tint(.indigo)
                            }
                    }
                }
                .scrollContentBackground(.hidden)
                .listStyle(.plain)
                .id(tick)
            }
        }
        .background(Color(red: 0.04, green: 0.05, blue: 0.10).ignoresSafeArea())
        .navigationTitle(loc.t("chats_archive"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

private struct ChatRow: View {
    let chat: ChatRoom
    let currentUserId: String
    let other: UserProfile?
    let peerId: String
    @EnvironmentObject private var loc: LocalizationService

    /// Fallback name when peer profile didn't load — shorter UID prefix
    /// is more useful than a generic "User" label for distinguishing chats.
    private var displayName: String {
        if let p = other?.displayName, !p.isEmpty { return p }
        if !peerId.isEmpty { return "ID " + String(peerId.prefix(6)) }
        return loc.t("common_user")
    }

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(urlString: other?.avatar, name: other?.displayName ?? peerId, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    if other?.hasActiveVerifiedBadge == true {
                        VerifiedChip(size: 12)
                    }
                    if other?.isPro == true {
                        Text("PRO")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundColor(.black)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(Color.accentColor)
                            .clipShape(Capsule())
                    }
                    if ChatsLocalState.isPinned(chat.id) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.55))
                            .rotationEffect(.degrees(45))
                    }
                    if ChatsLocalState.isMuted(chat.id) {
                        Image(systemName: "bell.slash.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
                Text(preview)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                if let at = chat.lastMessageAt { Text(formatRelative(at)).font(.system(size: 11)).foregroundColor(.white.opacity(0.4)) }
                let unread = chat.unreadCount(for: currentUserId)
                if unread > 0 {
                    Text("\(unread)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(ChatsLocalState.isMuted(chat.id) ? Color.white.opacity(0.25) : Color.accentColor)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// Last message if present, otherwise task title (so the row is never empty).
    private var preview: String {
        if let last = chat.lastMessage, !last.isEmpty { return last }
        if let task = chat.taskTitle, !task.isEmpty { return "\(loc.t("chats_task")) \(task)" }
        return loc.t("chats_no_messages")
    }

    private func formatRelative(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return "" }
        let r = RelativeDateTimeFormatter()
        r.unitsStyle = .short
        return r.localizedString(for: d, relativeTo: Date())
    }
}
