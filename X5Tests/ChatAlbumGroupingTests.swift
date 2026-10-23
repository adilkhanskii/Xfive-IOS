import XCTest
@testable import X5

/// Альбом в чате (Адильхан 10.10): пачка фото = отдельные сообщения, альбом — только показ.
final class ChatAlbumGroupingTests: XCTestCase {
    func testConsecutivePhotosOfOneSenderBecomeOneAlbum() {
        let items = ChatAlbumGrouping.group([
            text("t1", at: "2026-10-10T14:00:00Z"),
            photo("p1", at: "2026-10-10T14:00:01Z"),
            photo("p2", at: "2026-10-10T14:00:02.500Z"),
            photo("p3", at: "2026-10-10T14:00:03Z"),
            text("t2", at: "2026-10-10T14:00:04Z")
        ])

        XCTAssertEqual(items.map { $0.messages.map(\.id) }, [["t1"], ["p1", "p2", "p3"], ["t2"]])
        XCTAssertEqual(items[1].startIndex, 1)
        XCTAssertTrue(items[1].isAlbum)
        XCTAssertEqual(items[1].id, "p1")
        XCTAssertEqual(items[1].last.id, "p3")
    }

    func testSinglePhotoStaysNormalBubble() {
        let items = ChatAlbumGrouping.group([photo("p1", at: "2026-10-10T14:00:00Z")])
        XCTAssertEqual(items.count, 1)
        XCTAssertFalse(items[0].isAlbum)
    }

    func testAlbumBreaksOnSenderCaptionVideoAndLongGap() {
        let items = ChatAlbumGrouping.group([
            photo("a1", sender: "me", at: "2026-10-10T14:00:00Z"),
            photo("a2", sender: "me", at: "2026-10-10T14:00:01Z"),
            photo("b1", sender: "peer", at: "2026-10-10T14:00:02Z"),
            photo("b2", sender: "peer", at: "2026-10-10T14:00:03Z"),
            photo("c1", sender: "peer", at: "2026-10-10T14:02:04Z"),
            photo("c2", sender: "peer", at: "2026-10-10T14:02:05Z", content: "подпись"),
            row("v1", sender: "peer", type: "video", at: "2026-10-10T14:02:06Z", mediaUrl: "https://x/v.mp4")
        ])

        XCTAssertEqual(items.map { $0.messages.map(\.id) }, [["a1", "a2"], ["b1", "b2"], ["c1"], ["c2"], ["v1"]])
    }

    func testGapIsMeasuredBetweenNeighboursSoSlowBatchStaysOneAlbum() {
        let slow = (0..<10).map { i in
            photo("p\(i)", at: String(format: "2026-10-10T14:%02d:%02dZ", (i * 90) / 60, (i * 90) % 60))
        }
        let items = ChatAlbumGrouping.group(slow)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].messages.count, 10)
    }

    func testAlbumHoldsAtMostTenPhotos() {
        let many = (0..<13).map { i in photo("p\(i)", at: String(format: "2026-10-10T14:00:%02dZ", i)) }
        let items = ChatAlbumGrouping.group(many)
        XCTAssertEqual(items.map { $0.messages.count }, [10, 3])
    }

    func testMissingDateDoesNotGlueMessages() {
        let items = ChatAlbumGrouping.group([
            photo("p1", at: "2026-10-10T14:00:00Z"),
            photo("p2", at: nil)
        ])
        XCTAssertEqual(items.count, 2)
    }

    func testOnlyCaptionlessPhotosWithURLQualify() {
        XCTAssertTrue(ChatAlbumGrouping.isAlbumPhoto(photo("p", at: nil)))
        XCTAssertTrue(ChatAlbumGrouping.isAlbumPhoto(photo("p", at: nil, content: "  ")))
        XCTAssertFalse(ChatAlbumGrouping.isAlbumPhoto(photo("p", at: nil, content: "текст")))
        XCTAssertFalse(ChatAlbumGrouping.isAlbumPhoto(row("p", type: "image", at: nil, mediaUrl: nil)))
    }

    func testAnchorOfPhotoInsideAlbumIsTheAlbumFirstPhoto() {
        let items = ChatAlbumGrouping.group([
            photo("p1", at: "2026-10-10T14:00:00Z"),
            photo("p2", at: "2026-10-10T14:00:01Z"),
            text("t1", at: "2026-10-10T14:00:02Z")
        ])
        XCTAssertEqual(ChatAlbumGrouping.anchorID(for: "p2", in: items), "p1")
        XCTAssertEqual(ChatAlbumGrouping.anchorID(for: "t1", in: items), "t1")
        XCTAssertEqual(ChatAlbumGrouping.anchorID(for: "gone", in: items), "gone")
    }

    func testGridLayout() {
        XCTAssertEqual(ChatAlbumGrouping.layout(count: 2), .init(shape: .pair, visible: 2, extra: 0))
        XCTAssertEqual(ChatAlbumGrouping.layout(count: 3), .init(shape: .hero, visible: 3, extra: 0))
        XCTAssertEqual(ChatAlbumGrouping.layout(count: 4), .init(shape: .grid, visible: 4, extra: 0))
        XCTAssertEqual(ChatAlbumGrouping.layout(count: 10), .init(shape: .grid, visible: 4, extra: 6))
        XCTAssertEqual(ChatAlbumGrouping.pickLimit, 10)
        XCTAssertEqual(ChatAlbumGrouping.progressLabel(current: 3, total: 10), "Отправка 3 из 10")
    }

    private func photo(_ id: String, sender: String = "me", at: String?, content: String? = nil) -> ChatMessageRow {
        row(id, sender: sender, type: "image", at: at, content: content, mediaUrl: "https://x/\(id).jpg")
    }

    private func text(_ id: String, at: String) -> ChatMessageRow {
        row(id, type: "text", at: at, content: "привет", mediaUrl: nil)
    }

    private func row(
        _ id: String,
        sender: String = "me",
        type: String,
        at: String?,
        content: String? = nil,
        mediaUrl: String?
    ) -> ChatMessageRow {
        ChatMessageRow(
            id: id,
            chatId: "chat",
            senderId: sender,
            type: type,
            content: content,
            mediaUrl: mediaUrl,
            mediaMime: type == "image" ? "image/jpeg" : nil,
            createdAt: at
        )
    }
}
