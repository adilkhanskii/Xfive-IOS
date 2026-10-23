import XCTest
@testable import X5

final class ChatMessageTimelineTests: XCTestCase {
    func testMergeDeduplicatesAndSortsChronologically() {
        let old = row(id: "old", at: "2026-08-01T10:00:00Z", content: "old")
        let updated = row(id: "same", at: "2026-08-01T10:01:00Z", content: "server")
        let stale = row(id: "same", at: "2026-08-01T10:01:00Z", content: "stale")
        let newest = row(id: "new", at: "2026-08-01T10:02:00Z", content: "new")

        let result = ChatMessageTimeline.merge([stale, old], with: [newest, updated])

        XCTAssertEqual(result.map(\.id), ["old", "same", "new"])
        XCTAssertEqual(result[1].content, "server")
    }

    private func row(id: String, at: String, content: String) -> ChatMessageRow {
        ChatMessageRow(
            id: id,
            chatId: "chat",
            senderId: "sender",
            type: "text",
            content: content,
            mediaUrl: nil,
            mediaMime: nil,
            createdAt: at
        )
    }
}
