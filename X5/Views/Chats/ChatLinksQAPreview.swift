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
        taskTitle: "Нужен таргетолог",
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
        // Сегодня в фиксированное время — совпадает со строкой состояния скрина (13:35).
        func row(_ id: String, _ sender: String, _ type: String, _ content: String, minute: Int, second: Int = 0) -> ChatMessageRow {
            let date = Calendar.current.date(bySettingHour: 13, minute: minute, second: second, of: Date()) ?? Date()
            return ChatMessageRow(
                id: id,
                chatId: chat.id,
                senderId: sender,
                type: type,
                content: content,
                mediaUrl: nil,
                mediaMime: nil,
                createdAt: formatter.string(from: date)
            )
        }
        // Как в проде: «Откликнуться» → карточка от исполнителя, через секунду
        // сервер присылает автосообщение автора. Сообщения со ссылками для этого скрина убраны.
        let card = #"{"id":"6f1c2a9e-4b7d-4e2a-9c51-3d8e0f7a1b24","title":"Нужен таргетолог","description":"В команду требуется профессиональный специалист","budget":"Обговаривается","category":"marketing","authorName":"X5"}"#
        return [
            row("qa-1", peer, "task_card", card, minute: 20),
            row("qa-2", me, "text", "Здравствуйте! Спасибо за отклик. Пришлите портфолио и сроки", minute: 20, second: 1)
        ]
    }
}
#endif
