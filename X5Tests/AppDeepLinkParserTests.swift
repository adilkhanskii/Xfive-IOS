import XCTest
@testable import X5

final class AppDeepLinkParserTests: XCTestCase {
    func testParsesDirectTaskIdentifier() {
        XCTAssertEqual(
            AppDeepLinkParser.parse(userInfo: ["task_id": "task-123"]),
            .hubTask(id: "task-123")
        )
    }

    func testParsesProductionTaskPushPayload() {
        XCTAssertEqual(
            AppDeepLinkParser.parse(userInfo: [
                "type": "task_response",
                "event_id": "event-1",
                "task_id": "task-production"
            ]),
            .hubTask(id: "task-production")
        )
    }

    func testParsesProductionMessagePushPayload() {
        XCTAssertEqual(
            AppDeepLinkParser.parse(userInfo: [
                "type": "message",
                "message_id": "message-1",
                "chat_id": "chat-production"
            ]),
            .chat(id: "chat-production")
        )
    }

    func testParsesNestedJSONPayload() {
        XCTAssertEqual(
            AppDeepLinkParser.parse(userInfo: [
                "data": "{\"object_type\":\"task\",\"object_id\":\"task-456\"}"
            ]),
            .hubTask(id: "task-456")
        )
    }

    func testParsesCustomSchemeTaskURL() {
        XCTAssertEqual(
            AppDeepLinkParser.parse(userInfo: ["deep_link": "x5://hub/task/task-789"]),
            .hubTask(id: "task-789")
        )
    }

    func testRejectsUnrelatedObjectIdentifier() {
        XCTAssertNil(AppDeepLinkParser.parse(userInfo: [
            "object_type": "portfolio",
            "object_id": "post-1"
        ]))
    }

    @MainActor
    func testNewestRouteClearsAnyStaleTargetOfTheOtherKind() {
        let router = AppDeepLinkRouter()

        router.route(.chat(id: "chat-old"))
        router.route(.hubTask(id: "task-new"))
        XCTAssertNil(router.pendingChatID)
        XCTAssertEqual(router.pendingHubTaskID, "task-new")

        router.route(.chat(id: "chat-new"))
        XCTAssertNil(router.pendingHubTaskID)
        XCTAssertEqual(router.pendingChatID, "chat-new")
    }
}
