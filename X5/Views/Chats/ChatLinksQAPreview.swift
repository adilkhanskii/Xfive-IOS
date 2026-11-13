#if DEBUG
import SwiftUI

/// Только QA-скрин в симуляторе: настоящий ChatThreadView с мок-сообщениями
/// из кэша, без входа и сети (X5_CHAT_QA_PREVIEW=1).
struct ChatLinksQAPreview: View {
    @EnvironmentObject private var auth: Auth
    @State private var ready = false

    private static let me = "qa-author"
    private static let peer = "qa-specialist"
    private static let chat = ChatRoom(
        id: "qa-author_qa-specialist",
        participants: [me, peer],
        taskId: nil,
        taskTitle: "Снять рилс для кофейни",
        lastMessage: nil,
        lastMessageAt: nil,
        // 0 у собеседника = свои сообщения прочитаны (две галочки).
        unread: [peer: 0],
        createdAt: nil
    )

    var body: some View {
        Group {
            if ready {
                NavigationStack {
                    ChatThreadView(chat: Self.chat, initialOther: Self.peerProfile)
                }
            } else {
                Color.black
            }
        }
        .onAppear {
            auth.qaPreviewUserId(Self.me)
            ChatsService().persistMessageCache(chatId: Self.chat.id, rows: Self.rows())
            ready = true
        }
    }

    private static var peerProfile: UserProfile? {
        try? JSONDecoder().decode(
            UserProfile.self,
            from: Data(#"{"id":"qa-specialist","name":"Даурен Видеограф"}"#.utf8)
        )
    }

    private static func rows() -> [ChatMessageRow] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func row(_ id: String, _ sender: String, _ text: String, minutesAgo: Double) -> ChatMessageRow {
            ChatMessageRow(
                id: id,
                chatId: chat.id,
                senderId: sender,
                type: "text",
                content: text,
                mediaUrl: nil,
                mediaMime: nil,
                createdAt: formatter.string(from: Date().addingTimeInterval(-minutesAgo * 60))
            )
        }
        return [
            row("qa-1", me, "Здравствуйте! Спасибо за отклик. Пришлите портфолио и сроки", minutesAgo: 12),
            row("qa-2", peer, "Портфолио тут: https://www.behance.net/x5-design", minutesAgo: 8),
            row("qa-3", me, "Бриф здесь: www.x5marketing.com/brief", minutesAgo: 3)
        ]
    }
}
#endif
