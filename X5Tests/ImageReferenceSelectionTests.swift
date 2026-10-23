import XCTest
@testable import X5

final class ImageReferenceSelectionTests: XCTestCase {
    /// The client saw the spinner run on every pick and the thumbnail strip
    /// jump back to the first photo. Both came from reloading everything.
    func testAddingOnePhotoDecodesOnlyThatPhoto() {
        let plan = ImageReferenceSelection.plan(
            requested: ["a", "b", "c", "d"],
            alreadyLoaded: ["a", "b", "c"]
        )

        XCTAssertEqual(plan.needsDecoding, ["d"])
        XCTAssertTrue(plan.needsWork)
    }

    func testRepickingTheSamePhotosDoesNothing() {
        let plan = ImageReferenceSelection.plan(
            requested: ["a", "b"],
            alreadyLoaded: ["a", "b"]
        )

        XCTAssertEqual(plan.needsDecoding, [])
        XCTAssertFalse(plan.needsWork, "An unchanged selection must not reload or re-render")
    }

    func testReorderingReusesEveryDecodedPhoto() {
        let plan = ImageReferenceSelection.plan(
            requested: ["b", "a"],
            alreadyLoaded: ["a", "b"]
        )

        XCTAssertEqual(plan.needsDecoding, [], "Reordering must not decode anything again")
        XCTAssertTrue(plan.needsWork, "The new order still has to be applied")
    }

    func testRemovingAPhotoKeepsTheRestDecoded() {
        let plan = ImageReferenceSelection.plan(
            requested: ["a", "c"],
            alreadyLoaded: ["a", "b", "c"]
        )

        XCTAssertEqual(plan.needsDecoding, [])
        XCTAssertTrue(plan.needsWork)
    }

    func testFirstPickDecodesEverythingOnce() {
        let plan = ImageReferenceSelection.plan(
            requested: ["a", "b"],
            alreadyLoaded: []
        )

        XCTAssertEqual(plan.needsDecoding, ["a", "b"])
        XCTAssertTrue(plan.needsWork)
    }

    func testSelectionCapMatchesThePicker() {
        XCTAssertEqual(ImageReferenceSelection.maximumCount, 6)
    }
}
