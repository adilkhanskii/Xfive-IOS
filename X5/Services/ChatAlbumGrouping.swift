import Foundation

/// Альбом фото в чате, как в WhatsApp (Адильхан 10.10: «разом до 10 фоток, а то по одному»).
///
/// Зачем так: поля «альбом» в базе нет, миграцию не делаем — старые версии
/// приложения и сайт должны видеть пачку как обычные фото. Поэтому каждое фото
/// пачки — отдельное сообщение, а «альбом» — только способ показа:
/// подряд идущие фото одного человека (без текста, пауза ≤ 2 мин) клеим
/// в один пузырь-сетку. Те же правила на сайте: web/src/services/chatAlbum.ts.
enum ChatAlbumGrouping {
    /// Сколько фото/видео можно выбрать за раз.
    static let pickLimit = 10
    /// Пауза между соседними фото, после которой альбом рвётся.
    static let window: TimeInterval = 120
    /// Больше 10 в один пузырь не клеим: две пачки подряд — два альбома.
    static let maxAlbumSize = pickLimit

    /// Один пузырь ленты: 1 сообщение — обычное, 2+ — альбом.
    struct Item: Equatable, Identifiable {
        let messages: [ChatMessageRow]
        /// Позиция первого сообщения пузыря в исходном массиве (для заголовка даты).
        let startIndex: Int

        var id: String { messages[0].id }
        var first: ChatMessageRow { messages[0] }
        var last: ChatMessageRow { messages[messages.count - 1] }
        var isAlbum: Bool { messages.count > 1 }

        func contains(_ messageID: String?) -> Bool {
            guard let messageID else { return false }
            return messages.contains { $0.id == messageID }
        }
    }

    /// Фото без подписи — только такие идут в альбом (видео и фото с текстом — отдельно).
    static func isAlbumPhoto(_ message: ChatMessageRow) -> Bool {
        message.type == "image"
            && !(message.mediaUrl ?? "").isEmpty
            && (message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func group(
        _ messages: [ChatMessageRow],
        window: TimeInterval = ChatAlbumGrouping.window,
        maxSize: Int = ChatAlbumGrouping.maxAlbumSize
    ) -> [Item] {
        var items: [Item] = []
        var start = 0
        while start < messages.count {
            let first = messages[start]
            var end = start + 1
            if isAlbumPhoto(first) {
                while end < messages.count,
                      end - start < maxSize,
                      isAlbumPhoto(messages[end]),
                      messages[end].senderId == first.senderId,
                      // Сравниваем с соседом, а не с первым: 10 фото по медленному
                      // интернету грузятся дольше 2 минут, альбом не должен рваться.
                      let previous = date(messages[end - 1].createdAt),
                      let current = date(messages[end].createdAt),
                      abs(current.timeIntervalSince(previous)) <= window {
                    end += 1
                }
            }
            items.append(Item(messages: Array(messages[start..<end]), startIndex: start))
            start = end
        }
        return items
    }

    /// Фото внутри альбома не имеет своей строки в ленте — крутим к первому фото альбома.
    static func anchorID(for messageID: String, in items: [Item]) -> String {
        items.first { $0.contains(messageID) }?.id ?? messageID
    }

    enum Shape: Equatable {
        /// 2 фото — два в ряд.
        case pair
        /// 3 фото — одно большое сверху и два под ним.
        case hero
        /// 4+ — сетка 2×2, на 4-й плитке «+N».
        case grid
    }

    struct Layout: Equatable {
        let shape: Shape
        let visible: Int
        let extra: Int
    }

    static func layout(count: Int) -> Layout {
        if count <= 2 { return Layout(shape: .pair, visible: max(0, count), extra: 0) }
        if count == 3 { return Layout(shape: .hero, visible: 3, extra: 0) }
        return Layout(shape: .grid, visible: 4, extra: count - 4)
    }

    /// Подпись прогресса пачки: «Отправка 3 из 10».
    static func progressLabel(current: Int, total: Int) -> String {
        "Отправка \(current) из \(total)"
    }

    // Форматтеры дорогие — создаём один раз (ISO8601DateFormatter потокобезопасен).
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plainFormatter = ISO8601DateFormatter()

    private static func date(_ iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        return fractionalFormatter.date(from: iso) ?? plainFormatter.date(from: iso)
    }
}
