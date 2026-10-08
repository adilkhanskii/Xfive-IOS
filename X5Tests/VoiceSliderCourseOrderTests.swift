import Foundation
import XCTest
@testable import X5

/// 08.10, просьбы Адильхана: ползунок у голосового и порядок курсов без «хаоса».
final class VoiceSliderCourseOrderTests: XCTestCase {
    func testVoiceTimeLabelIsMinutesSeconds() {
        XCTAssertEqual(VoiceMessageTime.format(0), "0:00")
        XCTAssertEqual(VoiceMessageTime.format(12.7), "0:12")
        XCTAssertEqual(VoiceMessageTime.format(65), "1:05")
        XCTAssertEqual(VoiceMessageTime.format(.infinity), "0:00")
        XCTAssertEqual(VoiceMessageTime.format(.nan), "0:00")
        XCTAssertEqual(VoiceMessageTime.format(-3), "0:00")
    }

    func testVoiceDurationFallbackReadsWebAndClockFormats() {
        XCTAssertEqual(VoiceMessageTime.parse("12s"), 12)
        XCTAssertEqual(VoiceMessageTime.parse("0:40"), 40)
        XCTAssertEqual(VoiceMessageTime.parse("1:05"), 65)
        XCTAssertEqual(VoiceMessageTime.parse(nil), 0)
        XCTAssertEqual(VoiceMessageTime.parse("Голосовое"), 0)
    }

    func testCourseListOrderHasStableTieBreakers() throws {
        let request = try CourseListRequestBuilder.makeRequest(
            baseURL: URL(string: "https://example.supabase.co")!,
            anonKey: "anon-key",
            includeHidden: false,
            accessToken: nil
        )
        let url = try XCTUnwrap(request.url)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(
            items.first { $0.name == "order" }?.value,
            "sort_order.asc.nullslast,created_at.asc,id.asc"
        )
    }

    func testCourseOrderNumbersEveryCourseOnceFromZero() {
        let positions = CourseOrder.positions(for: ["b", "a", "c", "a"])
        XCTAssertEqual(positions.map(\.0), [0, 1, 2])
        XCTAssertEqual(positions.map(\.1), ["b", "a", "c"])
    }

    /// 08.10 вечер: перетаскивание карточек прямо в каталоге.
    func testDraggingCourseTakesPlaceOfCardUnderFinger() {
        let ids = ["a", "b", "c", "d"]
        // Вниз: «a» над «c» → встаёт на место «c», b и c сдвигаются вверх.
        XCTAssertEqual(CourseOrder.moving(ids, id: "a", over: "c"), ["b", "c", "a", "d"])
        // Вверх: «d» над «b» → встаёт на место «b», b и c сдвигаются вниз.
        XCTAssertEqual(CourseOrder.moving(ids, id: "d", over: "b"), ["a", "d", "b", "c"])
        // Наверх, в большую карточку.
        XCTAssertEqual(CourseOrder.moving(ids, id: "c", over: "a"), ["c", "a", "b", "d"])
        // Над собой или неизвестный id — порядок не меняется.
        XCTAssertEqual(CourseOrder.moving(ids, id: "b", over: "b"), ids)
        XCTAssertEqual(CourseOrder.moving(ids, id: "x", over: "b"), ids)
        XCTAssertEqual(CourseOrder.moving(ids, id: "b", over: "x"), ids)
    }
}
