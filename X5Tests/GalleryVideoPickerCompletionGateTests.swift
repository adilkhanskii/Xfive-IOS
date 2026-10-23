import XCTest
@testable import X5

final class GalleryVideoPickerCompletionGateTests: XCTestCase {
    func testCancelPreventsLateSelectionCompletion() {
        let gate = GalleryVideoPickerCompletionGate()

        XCTAssertTrue(gate.beginLoading())
        XCTAssertTrue(gate.cancel())
        XCTAssertFalse(gate.finishLoading())
        XCTAssertFalse(gate.cancel())
    }

    func testDuplicateSelectionCallbacksAreIgnored() {
        let gate = GalleryVideoPickerCompletionGate()

        XCTAssertTrue(gate.beginLoading())
        XCTAssertFalse(gate.beginLoading())
        XCTAssertTrue(gate.finishLoading())
        XCTAssertFalse(gate.finishLoading())
        XCTAssertFalse(gate.cancel())
    }
}
