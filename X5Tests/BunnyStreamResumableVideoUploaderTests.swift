import Foundation
import XCTest
@testable import X5

// Bunny Stream upload client. The path is enabled at runtime by
// app_feature_flags.bunny_course_video_upload; these tests cover the client
// contract with create-course-video-upload.
final class BunnyStreamResumableVideoUploaderTests: XCTestCase {
    func testUploadKeyIsStableButScopedToCourseLessonAndFile() {
        let first = BunnyStreamUploadKey.scoped(
            courseID: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
            lessonID: "lesson_1",
            uploadIdentity: "0123456789abcdef"
        )
        let retry = BunnyStreamUploadKey.scoped(
            courseID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            lessonID: "lesson_1",
            uploadIdentity: "0123456789abcdef"
        )
        let otherLesson = BunnyStreamUploadKey.scoped(
            courseID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            lessonID: "lesson_2",
            uploadIdentity: "0123456789abcdef"
        )
        let otherFile = BunnyStreamUploadKey.scoped(
            courseID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            lessonID: "lesson_1",
            uploadIdentity: "fedcba9876543210"
        )

        XCTAssertEqual(first, retry)
        XCTAssertEqual(first.count, 19)
        XCTAssertTrue(first.hasPrefix("lv_"))
        XCTAssertNotNil(
            first.range(of: "^[A-Za-z0-9_-]{16,128}$", options: .regularExpression),
            "server accepts only [A-Za-z0-9_-]{16,128}"
        )
        XCTAssertNotEqual(first, otherLesson)
        XCTAssertNotEqual(first, otherFile)
    }

    func testTicketDecodesOnlyTheOfficialBunnyTUSEndpoint() throws {
        let ticket = try JSONDecoder().decode(
            BunnyStreamUploadTicket.self,
            from: Data(validTicketJSON.utf8)
        )

        XCTAssertEqual(
            ticket.tusEndpoint.absoluteString,
            "https://video.bunnycdn.com/tusupload"
        )
        XCTAssertEqual(
            ticket.transientHeaders,
            [
                "AuthorizationSignature":
                    String(repeating: "a", count: 64),
                "AuthorizationExpire": "1900021600",
                "LibraryId": "321",
                "VideoId": "123e4567-e89b-42d3-a456-426614174000",
            ]
        )
    }

    func testTicketRejectsAnAttackerControlledTUSEndpoint() {
        let json = validTicketJSON.replacingOccurrences(
            of: "https://video.bunnycdn.com/tusupload",
            with: "https://attacker.invalid/tusupload"
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                BunnyStreamUploadTicket.self,
                from: Data(json.utf8)
            )
        )
    }

    func testResponseDecodesUploadOrAlreadyUploaded() throws {
        let upload = try BunnyStreamTicketResponse.decode(
            Data(validTicketJSON.utf8)
        )
        XCTAssertEqual(upload.videoID, "123e4567-e89b-42d3-a456-426614174000")
        guard case .upload = upload else {
            return XCTFail("expected a TUS ticket")
        }

        let done = try BunnyStreamTicketResponse.decode(Data("""
        {"video_id":"123E4567-E89B-42D3-A456-426614174000","library_id":"321",
         "status":"ready","upload_required":false}
        """.utf8))
        XCTAssertEqual(
            done,
            .alreadyUploaded(videoID: "123e4567-e89b-42d3-a456-426614174000")
        )
    }

    func testInProgressRetryPolicyIsBounded() {
        XCTAssertEqual(
            BunnyStreamTicketRetryPolicy.delaySeconds(
                retryAfter: nil
            ),
            3
        )
        XCTAssertEqual(
            BunnyStreamTicketRetryPolicy.delaySeconds(
                retryAfter: "0"
            ),
            1
        )
        XCTAssertEqual(
            BunnyStreamTicketRetryPolicy.delaySeconds(
                retryAfter: "60"
            ),
            5
        )
        XCTAssertEqual(
            BunnyStreamTicketRetryPolicy.maxInProgressRetries,
            3
        )
    }

    func testTicketClientPollsA425SlotWithoutCreatingAnotherRequestKey()
        async throws
    {
        let recorder = BunnyTicketRequestRecorder()
        BunnyTicketURLProtocol.handler = { request in
            let attempt = recorder.record(request)
            if attempt == 1 {
                return Self.response(
                    for: request,
                    statusCode: 425,
                    headers: ["Retry-After": "3"],
                    body: #"{"error":"upload_slot_in_progress"}"#
                )
            }
            return Self.response(
                for: request,
                statusCode: 200,
                body: self.validTicketJSON
            )
        }
        defer { BunnyTicketURLProtocol.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BunnyTicketURLProtocol.self]
        let client = BunnyStreamUploadTicketClient(
            baseURL: URL(string: "https://example.supabase.co")!,
            anonKey: "anon-key",
            session: URLSession(configuration: configuration),
            sleeper: { seconds in
                recorder.record(delay: seconds)
            }
        )

        let response = try await client.createTicket(
            courseID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            lessonID: "lesson_1",
            uploadKey: "lv_0123456789abcdef",
            title: "Lesson 1",
            fileName: "lesson.mov",
            contentType: "video/quicktime",
            sourceBytes: 1_073_741_824,
            accessToken: "access-token"
        )

        XCTAssertEqual(response.videoID, "123e4567-e89b-42d3-a456-426614174000")
        XCTAssertEqual(recorder.requestCount, 2)
        XCTAssertEqual(recorder.delays, [3])
        XCTAssertEqual(
            Set(recorder.requestBodies).count,
            1,
            "425 polling must replay the same owner-scoped idempotency key"
        )
    }

    func testBunnyDescriptorUsesSixMiBChunksAndNeverPersistsServerAPIKey() throws {
        let ticket = try JSONDecoder().decode(
            BunnyStreamUploadTicket.self,
            from: Data(validTicketJSON.utf8)
        )
        let descriptor = try BunnyStreamTUSUploadDescriptor(
            ticket: ticket,
            uploadIdentity: "course-1-lesson-1-file-hash",
            title: "Lesson 1",
            fileName: "lesson.mov",
            contentType: "video/quicktime"
        )

        XCTAssertEqual(descriptor.chunkSize, 6 * 1024 * 1024)
        XCTAssertEqual(
            descriptor.context,
            [
                "filetype": "video/quicktime",
                "title": "Lesson 1",
                "filename": "lesson.mov",
                "videoId": "123e4567-e89b-42d3-a456-426614174000",
            ]
        )
        XCTAssertNil(descriptor.context["AccessKey"])
        XCTAssertNil(descriptor.persistentHeaders["AccessKey"])
        XCTAssertNil(descriptor.persistentHeaders["BUNNY_STREAM_API_KEY"])
        XCTAssertTrue(descriptor.persistentHeaders.isEmpty)
    }

    func testStateStoreKeepsOnlyVideoIDForAResumableRetry() {
        let suite = "BunnyStreamResumableVideoUploaderTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BunnyStreamUploadStateStore(defaults: defaults)
        let identity = "course-1-lesson-1-file-hash"
        let videoID = "123e4567-e89b-42d3-a456-426614174000"

        store.save(videoID: videoID, for: identity)

        XCTAssertEqual(store.videoID(for: identity), videoID)
        XCTAssertFalse(
            defaults.dictionaryRepresentation().values.contains {
                String(describing: $0).contains("AuthorizationSignature")
            }
        )
        store.clear(for: identity)
        XCTAssertNil(store.videoID(for: identity))
    }

    private var validTicketJSON: String {
        """
        {
          "tus_endpoint": "https://video.bunnycdn.com/tusupload",
          "video_id": "123e4567-e89b-42d3-a456-426614174000",
          "library_id": "321",
          "authorization_signature": "\(String(repeating: "a", count: 64))",
          "authorization_expire": 1900021600,
          "upload_required": true
        }
        """
    }

    private static func response(
        for request: URLRequest,
        statusCode: Int,
        headers: [String: String] = [:],
        body: String
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headers.merging(
                ["Content-Type": "application/json"]
            ) { current, _ in current }
        )!
        return (response, Data(body.utf8))
    }
}

private final class BunnyTicketRequestRecorder {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var recordedDelays: [UInt64] = []

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    var requestBodies: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return requests.compactMap(\.httpBody)
    }

    var delays: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return recordedDelays
    }

    @discardableResult
    func record(_ request: URLRequest) -> Int {
        // Внутри URLProtocol тело POST приходит как httpBodyStream, а не
        // httpBody — без этого requestBodies всегда пустой и тест 425 падал.
        let materialized = (try? request.materializingHTTPBodyForTesting())
            ?? request
        lock.lock()
        defer { lock.unlock() }
        requests.append(materialized)
        return requests.count
    }

    func record(delay: UInt64) {
        lock.lock()
        recordedDelays.append(delay)
        lock.unlock()
    }
}

private final class BunnyTicketURLProtocol: URLProtocol {
    static var handler:
        ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
