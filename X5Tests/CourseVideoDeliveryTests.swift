import XCTest
@testable import X5

final class CourseVideoDeliveryTests: XCTestCase {
    private let videoID = "123e4567-e89b-42d3-a456-426614174000"

    // MARK: Lesson source

    func testBunnyLessonIsRecognisedFromPreservedFields() throws {
        let lesson = try decodeLesson("""
        {"id":"l1","title":"Bunny","videoProvider":"bunny",
         "bunnyVideoId":"123E4567-E89B-42D3-A456-426614174000",
         "videoStatus":"ready"}
        """)

        XCTAssertEqual(lesson.bunnyVideoID, videoID)
        XCTAssertEqual(lesson.videoSource, .bunny(videoID: videoID, status: .ready))
        XCTAssertTrue(lesson.hasAnyVideo)
        XCTAssertNil(lesson.playableURL, "no public URL for Bunny lessons")
    }

    func testLegacyLessonKeepsDirectURL() throws {
        let lesson = try decodeLesson("""
        {"id":"l2","title":"Old","videoUrl":"https://afwznqjpshybmqhlewmy.supabase.co/storage/v1/object/public/videos/courses/c/l2.mp4"}
        """)

        guard case .direct(let url) = lesson.videoSource else {
            return XCTFail("legacy mp4 must stay direct")
        }
        XCTAssertEqual(url.pathExtension, "mp4")
        XCTAssertNil(lesson.bunnyVideoID)
    }

    func testBunnyWinsOverLegacyURLDuringMigrationWindow() throws {
        let lesson = try decodeLesson("""
        {"id":"l3","title":"Both","videoUrl":"https://cdn.example.com/old.mp4",
         "videoProvider":"bunny","bunnyVideoId":"\(videoID)"}
        """)
        XCTAssertEqual(lesson.videoSource, .bunny(videoID: videoID, status: .unknown))
    }

    func testMalformedBunnyFieldsAreIgnored() throws {
        let wrongProvider = try decodeLesson("""
        {"id":"l4","title":"x","videoProvider":"other","bunnyVideoId":"\(videoID)"}
        """)
        let badID = try decodeLesson("""
        {"id":"l5","title":"x","videoProvider":"bunny","bunnyVideoId":"../etc"}
        """)
        XCTAssertNil(wrongProvider.bunnyVideoID)
        XCTAssertNil(badID.bunnyVideoID)
        XCTAssertEqual(badID.videoSource, .missing)
    }

    // MARK: Draft

    func testBunnyUploadStoresOnlyGUIDAndDropsPublicURL() {
        var draft = CourseLessonDraft(
            id: "l1",
            title: "Lesson",
            order: 1,
            price: "0",
            videoUrl: "https://cdn.example.com/old.mp4",
            youtubeUrl: "",
            thumbnailUrl: "",
            isFreePreview: false,
            sellSeparately: false,
            pendingVideoFileURL: URL(fileURLWithPath: "/tmp/new.mov"),
            pendingVideoFileName: "new.mov",
            preservedFields: ["description": .string("keep")]
        )

        draft.markVideoUploadSucceeded(.bunny(videoID: videoID.uppercased()))
        let payload = draft.payload(order: 1)

        XCTAssertNil(payload["videoUrl"])
        XCTAssertEqual(payload["videoProvider"] as? String, "bunny")
        XCTAssertEqual(payload["bunnyVideoId"] as? String, videoID)
        XCTAssertEqual(payload["videoStatus"] as? String, "processing")
        XCTAssertEqual(payload["description"] as? String, "keep")
        XCTAssertNil(draft.pendingVideoFileURL)
        XCTAssertTrue(draft.hasVideo)
        XCTAssertEqual(draft.bunnyVideoID, videoID)
    }

    func testStorageUploadOrManualURLReplacesBunnyVideo() {
        var draft = CourseLessonDraft(
            id: "l1",
            title: "Lesson",
            order: 1,
            price: "0",
            videoUrl: "",
            youtubeUrl: "",
            thumbnailUrl: "",
            isFreePreview: false,
            sellSeparately: false
        )
        draft.markVideoUploadSucceeded(.bunny(videoID: videoID))
        draft.markVideoUploadSucceeded(.storageURL("https://cdn.example.com/new.mp4"))
        var payload = draft.payload(order: 1)
        XCTAssertEqual(payload["videoUrl"] as? String, "https://cdn.example.com/new.mp4")
        XCTAssertNil(payload["bunnyVideoId"])
        XCTAssertNil(payload["videoProvider"])

        draft.markVideoUploadSucceeded(.bunny(videoID: videoID))
        let edited = draft.applyingEditorChanges(
            title: "Lesson",
            price: "0",
            videoUrl: "https://cdn.example.com/manual.m3u8",
            youtubeUrl: "",
            thumbnailUrl: "",
            isFreePreview: false,
            sellSeparately: false,
            pendingVideoFileURL: nil,
            pendingVideoFileName: nil,
            pendingThumbnailData: nil
        )
        payload = edited.payload(order: 1)
        XCTAssertEqual(payload["videoUrl"] as? String, "https://cdn.example.com/manual.m3u8")
        XCTAssertNil(payload["bunnyVideoId"])
    }

    func testEditingOtherFieldsKeepsBunnyVideo() {
        var draft = CourseLessonDraft(
            id: "l1",
            title: "Lesson",
            order: 1,
            price: "0",
            videoUrl: "",
            youtubeUrl: "",
            thumbnailUrl: "",
            isFreePreview: false,
            sellSeparately: false
        )
        draft.markVideoUploadSucceeded(.bunny(videoID: videoID))
        let edited = draft.applyingEditorChanges(
            title: "Renamed",
            price: "10",
            videoUrl: "",
            youtubeUrl: "",
            thumbnailUrl: "",
            isFreePreview: true,
            sellSeparately: false,
            pendingVideoFileURL: nil,
            pendingVideoFileName: nil,
            pendingThumbnailData: nil
        )
        XCTAssertEqual(edited.bunnyVideoID, videoID)
    }

    // MARK: Flag

    func testFeatureFlagParsingFailsClosed() {
        XCTAssertTrue(CourseVideoFeatureFlags.parseEnabled(Data(#"[{"enabled":true}]"#.utf8)))
        XCTAssertFalse(CourseVideoFeatureFlags.parseEnabled(Data(#"[{"enabled":false}]"#.utf8)))
        XCTAssertFalse(CourseVideoFeatureFlags.parseEnabled(Data("[]".utf8)))
        XCTAssertFalse(CourseVideoFeatureFlags.parseEnabled(Data("oops".utf8)))
    }

    // MARK: Playback response

    func testPlaybackReadyAcceptsOnlySignedBunnyHLS() {
        let signed = "https://vz-test.b-cdn.net/bcdn_token=abc&expires=1900007200&token_path=%2F\(videoID)%2F/\(videoID)/playlist.m3u8"
        let ready = CourseVideoPlaybackClient.parse(
            statusCode: 200,
            data: Data(#"{"status":"ready","hls_url":"\#(signed)","expires_at":1900007200}"#.utf8)
        )
        guard case .ready(let url, let expiresAt) = ready else {
            return XCTFail("expected ready, got \(ready)")
        }
        XCTAssertEqual(url.pathExtension, "m3u8")
        XCTAssertEqual(expiresAt.timeIntervalSince1970, 1_900_007_200)

        let foreign = CourseVideoPlaybackClient.parse(
            statusCode: 200,
            data: Data(#"{"hls_url":"https://evil.example.com/x/playlist.m3u8","expires_at":1}"#.utf8)
        )
        XCTAssertEqual(foreign, .unavailable)
    }

    func testPlaybackStatusMapping() {
        let empty = Data("{}".utf8)
        XCTAssertEqual(CourseVideoPlaybackClient.parse(statusCode: 202, data: empty), .processing)
        XCTAssertEqual(CourseVideoPlaybackClient.parse(statusCode: 401, data: empty), .notAuthenticated)
        XCTAssertEqual(CourseVideoPlaybackClient.parse(statusCode: 403, data: empty), .notEntitled)
        XCTAssertEqual(CourseVideoPlaybackClient.parse(statusCode: 422, data: empty), .failed)
        XCTAssertEqual(CourseVideoPlaybackClient.parse(statusCode: 503, data: empty), .unavailable)
    }

    private func decodeLesson(_ json: String) throws -> CourseLesson {
        try JSONDecoder().decode(CourseLesson.self, from: Data(json.utf8))
    }
}
