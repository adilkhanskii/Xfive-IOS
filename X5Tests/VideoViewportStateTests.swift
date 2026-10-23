import XCTest
@testable import X5

final class VideoViewportStateTests: XCTestCase {
    func testInitialStateUsesAnUnzoomedCenteredViewport() {
        let state = VideoViewportState()

        XCTAssertEqual(state.scale, 1, accuracy: 0.000_001)
        XCTAssertEqual(state.translationX, 0, accuracy: 0.000_001)
        XCTAssertEqual(state.translationY, 0, accuracy: 0.000_001)
    }

    func testApplyMagnificationKeepsValuesWithinOneAndFour() {
        var state = VideoViewportState()

        state.applyMagnification(0.25)
        XCTAssertEqual(state.scale, 1, accuracy: 0.000_001)

        state.applyMagnification(2.5)
        XCTAssertEqual(state.scale, 2.5, accuracy: 0.000_001)

        state.applyMagnification(8)
        XCTAssertEqual(state.scale, 4, accuracy: 0.000_001)
    }

    func testTranslationIsIgnoredWhileViewportIsNotZoomed() {
        var state = VideoViewportState()

        state.applyTranslation(x: 32, y: -18, viewportWidth: 320, viewportHeight: 180)

        XCTAssertEqual(state.translationX, 0, accuracy: 0.000_001)
        XCTAssertEqual(state.translationY, 0, accuracy: 0.000_001)
    }

    func testTranslationIsAppliedWhileViewportIsZoomed() {
        var state = VideoViewportState()
        state.applyMagnification(2)

        state.applyTranslation(x: 32, y: -18, viewportWidth: 320, viewportHeight: 180)

        XCTAssertEqual(state.translationX, 32, accuracy: 0.000_001)
        XCTAssertEqual(state.translationY, -18, accuracy: 0.000_001)
    }

    func testReturningToMinimumMagnificationRecentersViewport() {
        var state = VideoViewportState()
        state.applyMagnification(3)
        state.applyTranslation(x: 40, y: 24, viewportWidth: 320, viewportHeight: 180)

        state.applyMagnification(1)

        XCTAssertEqual(state.scale, 1, accuracy: 0.000_001)
        XCTAssertEqual(state.translationX, 0, accuracy: 0.000_001)
        XCTAssertEqual(state.translationY, 0, accuracy: 0.000_001)
    }

    func testResetRestoresDefaultViewport() {
        var state = VideoViewportState()
        state.applyMagnification(4)
        state.applyTranslation(x: -12, y: 90, viewportWidth: 320, viewportHeight: 180)

        state.reset()

        XCTAssertEqual(state.scale, 1, accuracy: 0.000_001)
        XCTAssertEqual(state.translationX, 0, accuracy: 0.000_001)
        XCTAssertEqual(state.translationY, 0, accuracy: 0.000_001)
    }

    func testTranslationIsClampedToScaledViewportEdges() {
        var state = VideoViewportState()
        state.applyMagnification(2)

        state.applyTranslation(x: 900, y: -900, viewportWidth: 320, viewportHeight: 180)

        XCTAssertEqual(state.translationX, 160, accuracy: 0.000_001)
        XCTAssertEqual(state.translationY, -90, accuracy: 0.000_001)
    }

    func testReducingScaleReclampsExistingTranslation() {
        var state = VideoViewportState()
        state.applyMagnification(4)
        state.applyTranslation(x: 480, y: 270, viewportWidth: 320, viewportHeight: 180)

        state.applyMagnification(1.5, viewportWidth: 320, viewportHeight: 180)

        XCTAssertEqual(state.translationX, 80, accuracy: 0.000_001)
        XCTAssertEqual(state.translationY, 45, accuracy: 0.000_001)
    }

    func testPreviewTranslationUsesGestureScaleAndGeometry() {
        let state = VideoViewportState()

        let translation = state.clampedTranslation(
            x: -500,
            y: 500,
            scale: 3,
            viewportWidth: 300,
            viewportHeight: 200
        )

        XCTAssertEqual(translation.x, -300, accuracy: 0.000_001)
        XCTAssertEqual(translation.y, 200, accuracy: 0.000_001)
    }

    func testViewportRotationReclampsCommittedTranslation() {
        var state = VideoViewportState()
        state.applyMagnification(2)
        state.applyTranslation(x: 90, y: 160, viewportWidth: 180, viewportHeight: 320)

        state.clampTranslation(viewportWidth: 320, viewportHeight: 180)

        XCTAssertEqual(state.translationX, 90, accuracy: 0.000_001)
        XCTAssertEqual(state.translationY, 90, accuracy: 0.000_001)
    }
}
