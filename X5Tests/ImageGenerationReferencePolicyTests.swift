import XCTest
@testable import X5

final class ImageGenerationReferencePolicyTests: XCTestCase {
    func testAcceptsSupportedReferenceWithinLimits() {
        XCTAssertTrue(ImageGenerationReferencePolicy.accepts([
            ImageGenerationReference(mimeType: "image/jpeg", base64: "aW1hZ2U=")
        ]))
    }

    func testRejectsTooManyOrUnsupportedReferences() {
        let valid = ImageGenerationReference(mimeType: "image/jpeg", base64: "aW1hZ2U=")
        XCTAssertFalse(ImageGenerationReferencePolicy.accepts(
            Array(repeating: valid, count: ImageGenerationReferencePolicy.maximumCount + 1)
        ))
        XCTAssertFalse(ImageGenerationReferencePolicy.accepts([
            ImageGenerationReference(mimeType: "application/pdf", base64: "aW1hZ2U=")
        ]))
    }
}
