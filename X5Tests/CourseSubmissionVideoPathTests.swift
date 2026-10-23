import XCTest
@testable import X5

final class CourseSubmissionVideoPathTests: XCTestCase {
    func testPathScopesSubmissionToAuthenticatedUserFolder() throws {
        let uniqueID = try XCTUnwrap(UUID(uuidString: "11111111-2222-4333-8444-555555555555"))

        let path = try CourseSubmissionVideoPath.make(
            userID: "EEE55A08-18D1-46E3-A303-1411D1BB9333",
            fileExtension: "mp4",
            uniqueID: uniqueID,
            timestamp: 1_721_234_567
        )

        XCTAssertEqual(
            path,
            "course-submissions/eee55a08-18d1-46e3-a303-1411d1bb9333/11111111-2222-4333-8444-555555555555-1721234567.mp4"
        )
    }

    func testPathRejectsUserIDThatCouldEscapeOwnerFolder() {
        XCTAssertThrowsError(
            try CourseSubmissionVideoPath.make(
                userID: "eee55a08-18d1-46e3-a303-1411d1bb9333/other-user",
                fileExtension: "mp4"
            )
        )
    }

    func testStableUploadIdentityKeepsRetryOnSameObjectPath() throws {
        let fileURL = URL(fileURLWithPath: "/tmp/x5-course-videos/photo-library-abc.mp4")
        let identity = CourseVideoUploadIdentity.stableToken(for: fileURL)

        XCTAssertEqual(identity, CourseVideoUploadIdentity.stableToken(for: fileURL))
        XCTAssertNotEqual(
            identity,
            CourseVideoUploadIdentity.stableToken(
                for: URL(fileURLWithPath: "/tmp/x5-course-videos/photo-library-def.mp4")
            )
        )

        let first = try CourseSubmissionVideoPath.make(
            userID: "EEE55A08-18D1-46E3-A303-1411D1BB9333",
            fileExtension: "mp4",
            uploadIdentity: identity
        )
        let retry = try CourseSubmissionVideoPath.make(
            userID: "EEE55A08-18D1-46E3-A303-1411D1BB9333",
            fileExtension: "mp4",
            uploadIdentity: identity
        )

        XCTAssertEqual(first, retry)
        XCTAssertTrue(first.hasSuffix("/\(identity).mp4"))
    }
}
