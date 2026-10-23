import XCTest
@testable import X5

final class SupabaseResumableVideoUploaderTests: XCTestCase {
    private let baseURL = URL(string: "https://example.supabase.co")!

    func testDescriptorUsesDirectStorageEndpointAndRequiredSixMiBChunk() throws {
        let descriptor = try makeDescriptor()

        XCTAssertEqual(
            descriptor.endpoint.absoluteString,
            "https://example.storage.supabase.co/storage/v1/upload/resumable"
        )
        XCTAssertEqual(descriptor.chunkSize, 6 * 1024 * 1024)
    }

    func testDescriptorBuildsSupabaseUploadMetadataWithoutCredentials() throws {
        let descriptor = try makeDescriptor()

        XCTAssertEqual(
            descriptor.context,
            [
                "bucketName": "videos",
                "objectName": "courses/course-1/lesson-1.mp4",
                "contentType": "video/mp4",
                "cacheControl": "3600"
            ]
        )
        XCTAssertNil(descriptor.context["Authorization"])
        XCTAssertNil(descriptor.context["apikey"])
    }

    func testPersistentHeadersEnableUpsertButNeverPersistBearerToken() throws {
        let descriptor = try makeDescriptor()

        XCTAssertEqual(descriptor.persistentHeaders["apikey"], "anon-key")
        XCTAssertEqual(descriptor.persistentHeaders["x-upsert"], "true")
        XCTAssertNil(descriptor.persistentHeaders["Authorization"])
    }

    func testSessionConfigurationUsesLongEphemeralRequestTimeout() {
        let configuration = SupabaseTUSSessionConfiguration.make()

        XCTAssertEqual(configuration.timeoutIntervalForRequest, 300)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 24 * 60 * 60)
        XCTAssertNil(configuration.httpAdditionalHeaders?["Authorization"])
    }

    func testTransientAuthorizationHeadersAddTrimmedBearer() throws {
        let headers = try SupabaseTUSAuthorization.headers(
            persistentHeaders: ["apikey": "anon-key", "x-upsert": "true"],
            accessToken: "  fresh-token  "
        )

        XCTAssertEqual(headers["Authorization"], "Bearer fresh-token")
        XCTAssertEqual(headers["apikey"], "anon-key")
        XCTAssertEqual(headers["x-upsert"], "true")
    }

    func testTransientAuthorizationRejectsEmptyBearerToken() throws {
        XCTAssertThrowsError(
            try SupabaseTUSAuthorization.headers(
                persistentHeaders: [:],
                accessToken: " \n "
            )
        ) { error in
            XCTAssertEqual(
                error as? SupabaseResumableVideoUploadError,
                .missingAccessToken
            )
        }
    }

    func testPublicURLKeepsExistingVideosBucketSemantics() throws {
        let descriptor = try makeDescriptor()

        XCTAssertEqual(
            descriptor.publicURL.absoluteString,
            "https://example.supabase.co/storage/v1/object/public/videos/courses/course-1/lesson-1.mp4"
        )
    }

    func testDescriptorRejectsUnsafeObjectName() {
        XCTAssertThrowsError(
            try SupabaseTUSUploadDescriptor(
                baseURL: baseURL,
                anonKey: "anon-key",
                bucketName: "videos",
                objectName: "../other-user/video.mp4",
                contentType: "video/mp4"
            )
        ) { error in
            XCTAssertEqual(
                error as? SupabaseResumableVideoUploadError,
                .invalidObjectName
            )
        }
    }

    func testProgressIsBoundedAndHandlesUnknownTotal() {
        XCTAssertEqual(
            SupabaseResumableVideoUploadProgress.fraction(
                bytesUploaded: 3,
                totalBytes: 10
            ),
            0.3,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            SupabaseResumableVideoUploadProgress.fraction(
                bytesUploaded: 12,
                totalBytes: 10
            ),
            1
        )
        XCTAssertEqual(
            SupabaseResumableVideoUploadProgress.fraction(
                bytesUploaded: 1,
                totalBytes: 0
            ),
            0
        )
    }

    func testFailureMessageExplainsThatResumableUploadCanBeRetried() {
        let error = SupabaseResumableVideoUploadError.uploadFailed(
            details: "The request timed out."
        )

        XCTAssertTrue(
            error.localizedDescription.lowercased().contains("возобновляемая загрузка")
        )
        XCTAssertTrue(error.localizedDescription.contains("The request timed out."))
    }

    private func makeDescriptor() throws -> SupabaseTUSUploadDescriptor {
        try SupabaseTUSUploadDescriptor(
            baseURL: baseURL,
            anonKey: "anon-key",
            bucketName: "videos",
            objectName: "courses/course-1/lesson-1.mp4",
            contentType: "video/mp4"
        )
    }
}
