import Foundation
import XCTest
@testable import X5

final class VideoGenerationServiceTests: XCTestCase {
    func testSubmitRequestUsesAuthenticatedEdgeFunctionContract() async throws {
        let recorder = VideoGenerationRequestRecorder()
        let service = makeService(recorder: recorder) { request in
            (
                Self.response(for: request, statusCode: 202),
                Data(
                    """
                    {
                      "job": {
                        "id": "11111111-1111-4111-8111-111111111111",
                        "status": "queued",
                        "progress": 0,
                        "credits_reserved": 650,
                        "refunded": false,
                        "result_url": null,
                        "result_url_expires_at": null,
                        "error_code": null,
                        "created_at": "2026-07-25T12:00:00Z",
                        "updated_at": "2026-07-25T12:00:00Z"
                      },
                      "replayed": false
                    }
                    """.utf8
                )
            )
        }

        let result = try await service.submit(
            prompt: "A cinematic coffee advertisement",
            aspectRatio: "9:16",
            durationSeconds: 5,
            model: .seedance20Fast,
            resolution: .hd,
            generateAudio: true,
            idempotencyKey: "22222222-2222-4222-8222-222222222222",
            accessToken: "access-token"
        )

        XCTAssertEqual(result.job.status, .queued)
        XCTAssertEqual(result.job.creditsReserved, 650)
        let request = try XCTUnwrap(recorder.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/functions/v1/generate-video")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer access-token"
        )
        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(
            payload["idempotency_key"] as? String,
            "22222222-2222-4222-8222-222222222222"
        )
        XCTAssertEqual(payload["duration_seconds"] as? Int, 5)
        XCTAssertEqual(payload["aspect_ratio"] as? String, "9:16")
        XCTAssertEqual(payload["model"] as? String, "seedance-2.0-fast")
        XCTAssertEqual(payload["resolution"] as? String, "720p")
        XCTAssertEqual(payload["generate_audio"] as? Bool, true)
        XCTAssertNil(payload["start_image"])
    }

    func testSubmitIncludesOptionalJPEGStartImage() async throws {
        let recorder = VideoGenerationRequestRecorder()
        let service = makeService(recorder: recorder) { request in
            (
                Self.response(for: request, statusCode: 202),
                Self.queuedJobResponse
            )
        }
        let image = try VideoGenerationStartImage(
            mimeType: "image/jpeg",
            data: Data([0xFF, 0xD8, 0xFF, 0xD9])
        )

        _ = try await service.submit(
            prompt: "Animate the product photograph",
            aspectRatio: "16:9",
            durationSeconds: 5,
            idempotencyKey: "22222222-2222-4222-8222-222222222222",
            startImage: image,
            accessToken: "access-token"
        )

        let request = try XCTUnwrap(recorder.lastRequest)
        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let startImage = try XCTUnwrap(payload["start_image"] as? [String: Any])
        XCTAssertEqual(startImage["mime_type"] as? String, "image/jpeg")
        XCTAssertEqual(
            startImage["data_base64"] as? String,
            Data([0xFF, 0xD8, 0xFF, 0xD9]).base64EncodedString()
        )
    }

    func testSubmitRejectsSquareAspectRatioLocally() async {
        let recorder = VideoGenerationRequestRecorder()
        let service = makeService(recorder: recorder) { _ in
            XCTFail("Unsupported aspect ratio must not reach the network")
            throw URLError(.badServerResponse)
        }

        do {
            _ = try await service.submit(
                prompt: "A square product reveal",
                aspectRatio: "1:1",
                durationSeconds: 5,
                idempotencyKey: "22222222-2222-4222-8222-222222222222",
                accessToken: "access-token"
            )
            XCTFail("Expected invalidAspectRatio")
        } catch {
            XCTAssertEqual(
                error as? VideoGenerationServiceError,
                .invalidAspectRatio
            )
        }
        XCTAssertNil(recorder.lastRequest)
    }

    func testStartImageRejectsMoreThanEightMiBLocally() {
        XCTAssertThrowsError(
            try VideoGenerationStartImage(
                mimeType: "image/jpeg",
                data: Data(repeating: 0, count: (8 * 1024 * 1024) + 1)
            )
        ) { error in
            XCTAssertEqual(
                error as? VideoGenerationServiceError,
                .startImageTooLarge
            )
        }
    }

    func testInputFingerprintIsStableAndIncludesStartImage() throws {
        let image = try VideoGenerationStartImage(
            mimeType: "image/jpeg",
            data: Data([1, 2, 3])
        )

        let first = VideoGenerationInputFingerprint.make(
            prompt: "  Animate this photo  ",
            aspectRatio: "9:16",
            durationSeconds: 5,
            model: .seedance15Pro,
            resolution: .hd,
            generateAudio: true,
            startImage: image
        )
        let same = VideoGenerationInputFingerprint.make(
            prompt: "Animate this photo",
            aspectRatio: "9:16",
            durationSeconds: 5,
            model: .seedance15Pro,
            resolution: .hd,
            generateAudio: true,
            startImage: image
        )
        let textOnly = VideoGenerationInputFingerprint.make(
            prompt: "Animate this photo",
            aspectRatio: "9:16",
            durationSeconds: 5,
            model: .seedance15Pro,
            resolution: .hd,
            generateAudio: true,
            startImage: nil
        )
        let muted = VideoGenerationInputFingerprint.make(
            prompt: "Animate this photo",
            aspectRatio: "9:16",
            durationSeconds: 5,
            model: .seedance15Pro,
            resolution: .hd,
            generateAudio: false,
            startImage: image
        )
        let fullHD = VideoGenerationInputFingerprint.make(
            prompt: "Animate this photo",
            aspectRatio: "9:16",
            durationSeconds: 5,
            model: .seedance15Pro,
            resolution: .fullHD,
            generateAudio: true,
            startImage: image
        )
        let automatic = VideoGenerationInputFingerprint.make(
            prompt: "Animate this photo",
            aspectRatio: "9:16",
            durationSeconds: 5,
            model: .automatic,
            resolution: .hd,
            generateAudio: true,
            startImage: image
        )

        XCTAssertEqual(first, same)
        XCTAssertNotEqual(first, textOnly)
        XCTAssertNotEqual(first, muted)
        XCTAssertNotEqual(first, fullHD)
        XCTAssertNotEqual(first, automatic)
        XCTAssertEqual(first.count, 64)
    }

    func testLocalStoreKeepsAtMostEightMostRecentUniqueJobs() {
        let defaults = makeIsolatedDefaults()
        let store = VideoGenerationLocalStore(
            defaults: defaults,
            keyPrefix: "tests.recent"
        )
        let ids = (0..<10).map {
            String(format: "00000000-0000-4000-8000-%012d", $0)
        }
        let accountID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

        ids.forEach { store.remember(jobID: $0, userID: accountID) }
        store.remember(jobID: ids[5], userID: accountID)

        let recentJobIDs = store.recentJobIDs(userID: accountID)
        XCTAssertEqual(recentJobIDs.count, 8)
        XCTAssertEqual(recentJobIDs.first, ids[5])
        XCTAssertEqual(Set(recentJobIDs).count, 8)
        XCTAssertFalse(recentJobIDs.contains(ids[0]))
        XCTAssertFalse(recentJobIDs.contains(ids[1]))
    }

    func testLocalStoreScopesRecentJobsByAccount() {
        let defaults = makeIsolatedDefaults()
        let store = VideoGenerationLocalStore(
            defaults: defaults,
            keyPrefix: "tests.account-recent"
        )
        let accountA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let accountB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let jobA = "11111111-1111-4111-8111-111111111111"
        let jobB = "22222222-2222-4222-8222-222222222222"

        store.remember(jobID: jobA, userID: accountA)
        store.remember(jobID: jobB, userID: accountB)

        XCTAssertEqual(store.recentJobIDs(userID: accountA), [jobA])
        XCTAssertEqual(store.recentJobIDs(userID: accountB), [jobB])

        store.remove(jobID: jobA, userID: accountA)

        XCTAssertTrue(store.recentJobIDs(userID: accountA).isEmpty)
        XCTAssertEqual(store.recentJobIDs(userID: accountB), [jobB])
    }

    func testPendingIdempotencyKeyIsReusedOnlyForSameFingerprint() {
        let defaults = makeIsolatedDefaults()
        let store = VideoGenerationLocalStore(
            defaults: defaults,
            keyPrefix: "tests.pending"
        )
        let accountID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

        let first = store.pendingIdempotencyKey(
            for: "fingerprint-a",
            userID: accountID
        )
        let reloadedStore = VideoGenerationLocalStore(
            defaults: defaults,
            keyPrefix: "tests.pending"
        )
        let replay = reloadedStore.pendingIdempotencyKey(
            for: "fingerprint-a",
            userID: accountID
        )
        let changedInput = store.pendingIdempotencyKey(
            for: "fingerprint-b",
            userID: accountID
        )

        XCTAssertEqual(first, replay)
        XCTAssertNotEqual(first, changedInput)

        store.clearPending(acceptedKey: changedInput, userID: accountID)
        let explicitRetry = store.pendingIdempotencyKey(
            for: "fingerprint-b",
            userID: accountID,
            forceNew: true
        )
        XCTAssertNotEqual(changedInput, explicitRetry)
    }

    func testPendingIdempotencyLedgerKeepsEarlierFingerprintAfterAnotherSubmission() {
        let defaults = makeIsolatedDefaults()
        let store = VideoGenerationLocalStore(
            defaults: defaults,
            keyPrefix: "tests.pending-ledger"
        )
        let accountID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

        let keyA = store.pendingIdempotencyKey(
            for: "fingerprint-a",
            userID: accountID
        )
        let keyB = store.pendingIdempotencyKey(
            for: "fingerprint-b",
            userID: accountID
        )

        XCTAssertNotEqual(keyA, keyB)
        XCTAssertEqual(
            store.pendingIdempotencyKey(
                for: "fingerprint-a",
                userID: accountID
            ),
            keyA
        )

        store.clearPending(acceptedKey: keyB, userID: accountID)

        XCTAssertEqual(
            store.pendingIdempotencyKey(
                for: "fingerprint-a",
                userID: accountID
            ),
            keyA
        )
    }

    func testPendingIdempotencyLedgerIsBoundedAndEvictsOldestFingerprint() {
        let defaults = makeIsolatedDefaults()
        let store = VideoGenerationLocalStore(
            defaults: defaults,
            keyPrefix: "tests.pending-bounded"
        )
        let accountID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let oldest = store.pendingIdempotencyKey(
            for: "fingerprint-0",
            userID: accountID
        )

        for index in 1...VideoGenerationLocalStore.maximumPendingSubmissionCount {
            _ = store.pendingIdempotencyKey(
                for: "fingerprint-\(index)",
                userID: accountID
            )
        }

        XCTAssertNotEqual(
            store.pendingIdempotencyKey(
                for: "fingerprint-0",
                userID: accountID
            ),
            oldest
        )
    }

    func testLocalStoreScopesPendingIdempotencyByAccount() {
        let defaults = makeIsolatedDefaults()
        let store = VideoGenerationLocalStore(
            defaults: defaults,
            keyPrefix: "tests.account-pending"
        )
        let accountA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let accountB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

        let keyA = store.pendingIdempotencyKey(
            for: "same-fingerprint",
            userID: accountA
        )
        let keyB = store.pendingIdempotencyKey(
            for: "same-fingerprint",
            userID: accountB
        )

        XCTAssertNotEqual(keyA, keyB)
        XCTAssertEqual(
            store.pendingIdempotencyKey(
                for: "same-fingerprint",
                userID: accountA
            ),
            keyA
        )

        store.clearPending(acceptedKey: keyB, userID: accountB)

        XCTAssertEqual(
            store.pendingIdempotencyKey(
                for: "same-fingerprint",
                userID: accountA
            ),
            keyA
        )
        XCTAssertNotEqual(
            store.pendingIdempotencyKey(
                for: "same-fingerprint",
                userID: accountB
            ),
            keyB
        )
    }

    func testRefundedFailureMapsToDistinctDisplayState() {
        let job = VideoGenerationJob(
            id: "11111111-1111-4111-8111-111111111111",
            status: .failed,
            progress: 0.4,
            creditsReserved: 650,
            refunded: true,
            resultURL: nil,
            resultURLExpiresAt: nil,
            assetID: nil,
            errorCode: "provider_failed",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(VideoGenerationDisplayState(job: job), .refunded)
    }

    func testUnknownServerMessageIsNotShownToUser() {
        let error = VideoGenerationServiceError.server(
            statusCode: 500,
            code: "internal_failure",
            message: "postgres password=secret\nstack trace"
        )

        XCTAssertFalse(error.localizedDescription.contains("password"))
        XCTAssertFalse(error.localizedDescription.contains("stack trace"))
    }

    func testBareHTTPAuthAndNotFoundStatusesDoNotDeletePersistedJob() {
        for statusCode in [401, 403, 404] {
            XCTAssertFalse(
                VideoGenerationServiceError.server(
                    statusCode: statusCode,
                    code: statusCode == 404 ? nil : "unauthorized",
                    message: "safe"
                )
                .makesJobUnavailable
            )
        }
    }

    func testOnlyExplicitSafeOwnershipCodesDeletePersistedJob() {
        for code in [
            "job_not_found",
            "job_access_denied",
            "job_not_owned",
            "not_owner",
            "ownership_mismatch"
        ] {
            XCTAssertTrue(
                VideoGenerationServiceError.server(
                    statusCode: 400,
                    code: code,
                    message: "safe"
                )
                .makesJobUnavailable
            )
        }
        XCTAssertFalse(VideoGenerationServiceError.transport.makesJobUnavailable)
    }

    func testAuthenticationFailuresRequestRefreshWithoutMakingJobUnavailable() {
        for statusCode in [401, 403] {
            let error = VideoGenerationServiceError.server(
                statusCode: statusCode,
                code: "unauthorized",
                message: "safe"
            )

            XCTAssertTrue(error.requiresAuthenticationRefresh)
            XCTAssertFalse(error.makesJobUnavailable)
        }
        XCTAssertFalse(
            VideoGenerationServiceError.server(
                statusCode: 500,
                code: "internal_failure",
                message: "safe"
            )
            .requiresAuthenticationRefresh
        )
    }

    func testPollingBackoffIsBoundedAndResetsAfterSuccess() {
        XCTAssertEqual(VideoGenerationPollingRetryPolicy.delaySeconds(attempt: 0), 4)
        XCTAssertEqual(VideoGenerationPollingRetryPolicy.delaySeconds(attempt: 1), 8)
        XCTAssertEqual(VideoGenerationPollingRetryPolicy.delaySeconds(attempt: 2), 16)
        XCTAssertEqual(VideoGenerationPollingRetryPolicy.delaySeconds(attempt: 20), 30)
        XCTAssertEqual(VideoGenerationPollingRetryPolicy.delaySeconds(attempt: -1), 4)
    }

    func testCancelledURLRequestPropagatesCancellation() async {
        let recorder = VideoGenerationRequestRecorder()
        let service = makeService(recorder: recorder) { _ in
            throw URLError(.cancelled)
        }

        do {
            _ = try await service.status(
                jobID: "11111111-1111-4111-8111-111111111111",
                accessToken: "access-token"
            )
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected: cancellation must not be rewritten as a transport error.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testStatusRequestUsesOwnedJobQuery() async throws {
        let recorder = VideoGenerationRequestRecorder()
        let service = makeService(recorder: recorder) { request in
            (
                Self.response(for: request, statusCode: 200),
                Data(
                    """
                    {
                      "job": {
                        "id": "11111111-1111-4111-8111-111111111111",
                        "status": "completed",
                        "progress": 1,
                        "credits_reserved": 650,
                        "refunded": false,
                        "result_url": "https://signed.example/video.mp4",
                        "result_url_expires_at": "2026-07-25T13:00:00Z",
                        "error_code": null,
                        "created_at": "2026-07-25T12:00:00Z",
                        "updated_at": "2026-07-25T12:05:00Z"
                      }
                    }
                    """.utf8
                )
            )
        }

        let result = try await service.status(
            jobID: "11111111-1111-4111-8111-111111111111",
            accessToken: "access-token"
        )

        XCTAssertEqual(result.job.status, .completed)
        XCTAssertEqual(
            result.job.resultURL,
            URL(string: "https://signed.example/video.mp4")
        )
        let components = try XCTUnwrap(
            URLComponents(url: XCTUnwrap(recorder.lastRequest?.url), resolvingAgainstBaseURL: false)
        )
        XCTAssertEqual(
            components.queryItems?.first(where: { $0.name == "job_id" })?.value,
            "11111111-1111-4111-8111-111111111111"
        )
    }

    func testProviderDetailsAreNotRequiredByNativeContract() {
        let keys = Set(VideoGenerationJob.CodingKeys.allCases.map(\.rawValue))
        XCTAssertFalse(keys.contains("provider_request_id"))
        XCTAssertFalse(keys.contains("provider_secret"))
    }

    func testSupabaseFractionalTimestampsDecode() async throws {
        let recorder = VideoGenerationRequestRecorder()
        let service = makeService(recorder: recorder) { request in
            (
                Self.response(for: request, statusCode: 200),
                Data(
                    """
                    {
                      "job": {
                        "id": "11111111-1111-4111-8111-111111111111",
                        "status": "queued",
                        "progress": 0,
                        "credits_reserved": 650,
                        "refunded": false,
                        "result_url": null,
                        "result_url_expires_at": null,
                        "error_code": null,
                        "created_at": "2026-07-25T12:00:00.123456+00:00",
                        "updated_at": "2026-07-25T12:00:00.987654+00:00"
                      }
                    }
                    """.utf8
                )
            )
        }

        let result = try await service.status(
            jobID: "11111111-1111-4111-8111-111111111111",
            accessToken: "access-token"
        )

        XCTAssertEqual(result.job.status, .queued)
    }

    func testCompletedMP4IsDownloadedToControlledLocalFile() async throws {
        let mp4 = Data([0, 0, 0, 12]) + Data("ftypisom".utf8)
        let setup = makeResultFileService { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "video/mp4",
                    "Content-Length": "\(mp4.count)"
                ]
            )!
            return (response, mp4)
        }
        let jobID = "11111111-1111-4111-8111-111111111111"
        let resultURL = URL(
            string: "https://\(setup.host)/storage/v1/object/sign/video-generation-results/user/\(jobID).mp4?token=temporary"
        )!

        let localURL = try await setup.service.prepare(
            resultURL: resultURL,
            jobID: jobID
        )

        XCTAssertEqual(localURL.deletingLastPathComponent(), setup.directory)
        let localName = localURL.deletingPathExtension().lastPathComponent
        let identifiers = String(localName.dropFirst("x5-video-".count))
            .components(separatedBy: "--")
        XCTAssertEqual(identifiers.count, 2)
        XCTAssertTrue(identifiers.allSatisfy { UUID(uuidString: $0) != nil })
        XCTAssertEqual(try Data(contentsOf: localURL), mp4)
        setup.service.cleanup(localURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
    }

    func testRepeatedResultPreparationUsesIndependentLocalFiles() async throws {
        let mp4 = Data([0, 0, 0, 12]) + Data("ftypisom".utf8)
        let setup = makeResultFileService { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "video/mp4",
                    "Content-Length": "\(mp4.count)"
                ]
            )!
            return (response, mp4)
        }
        let jobID = "11111111-1111-4111-8111-111111111111"
        let resultURL = URL(
            string: "https://\(setup.host)/storage/v1/object/sign/video-generation-results/user/\(jobID).mp4?token=temporary"
        )!

        let firstURL = try await setup.service.prepare(
            resultURL: resultURL,
            jobID: jobID
        )
        let secondURL = try await setup.service.prepare(
            resultURL: resultURL,
            jobID: jobID
        )

        XCTAssertNotEqual(firstURL, secondURL)
        XCTAssertEqual(try Data(contentsOf: firstURL), mp4)
        XCTAssertEqual(try Data(contentsOf: secondURL), mp4)
        setup.service.cleanup(firstURL)
        setup.service.cleanup(secondURL)
    }

    func testResultDownloadRejectsUntrustedHostAndObjectPathBeforeNetwork() async {
        let setup = makeResultFileService { _ in
            XCTFail("Untrusted URL must not reach the network")
            throw URLError(.badURL)
        }
        let jobID = "11111111-1111-4111-8111-111111111111"
        for url in [
            URL(string: "https://attacker.example/video.mp4")!,
            URL(string: "https://\(setup.host)/storage/v1/object/public/video-generation-results/video.mp4")!
        ] {
            do {
                _ = try await setup.service.prepare(resultURL: url, jobID: jobID)
                XCTFail("Expected invalid signed URL")
            } catch {
                XCTAssertEqual(
                    error as? VideoGenerationResultFileError,
                    .invalidSignedURL
                )
            }
        }
    }

    func testResultDownloadRejectsWrongMIMEAndDeclaredOversize() async {
        let mp4 = Data([0, 0, 0, 12]) + Data("ftypisom".utf8)
        for (contentType, length, expectedError) in [
            ("text/html", "\(mp4.count)", VideoGenerationResultFileError.invalidVideo),
            (
                "video/mp4",
                "\(VideoGenerationResultFileService.maximumVideoBytes + 1)",
                VideoGenerationResultFileError.fileTooLarge
            )
        ] {
            let setup = makeResultFileService { request in
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": contentType,
                        "Content-Length": length
                    ]
                )!
                return (response, mp4)
            }
            let url = URL(
                string: "https://\(setup.host)/storage/v1/object/sign/video-generation-results/user/result.mp4?token=temporary"
            )!
            do {
                _ = try await setup.service.prepare(
                    resultURL: url,
                    jobID: "11111111-1111-4111-8111-111111111111"
                )
                XCTFail("Expected result validation failure")
            } catch {
                XCTAssertEqual(error as? VideoGenerationResultFileError, expectedError)
            }
        }
    }

    func testResultCleanupCannotDeleteOutsideControlledDirectory() throws {
        let setup = makeResultFileService { _ in
            throw URLError(.badURL)
        }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
            "x5-video-11111111-1111-4111-8111-111111111111.mp4"
        )
        try Data("keep".utf8).write(to: outside, options: .atomic)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }

        setup.service.cleanup(outside)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testResultCleanupRequiresJobAndPreparationUUIDs() throws {
        let setup = makeResultFileService { _ in
            throw URLError(.badURL)
        }
        try FileManager.default.createDirectory(
            at: setup.directory,
            withIntermediateDirectories: true
        )
        let invalid = setup.directory.appendingPathComponent(
            "x5-video-11111111-1111-4111-8111-111111111111.mp4"
        )
        let valid = setup.directory.appendingPathComponent(
            "x5-video-11111111-1111-4111-8111-111111111111--22222222-2222-4222-8222-222222222222.mp4"
        )
        try Data("keep".utf8).write(to: invalid, options: .atomic)
        try Data("remove".utf8).write(to: valid, options: .atomic)

        setup.service.cleanup(invalid)
        setup.service.cleanup(valid)

        XCTAssertTrue(FileManager.default.fileExists(atPath: invalid.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: valid.path))
    }

    private func makeService(
        recorder: VideoGenerationRequestRecorder,
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> VideoGenerationService {
        let host = "video-generation-\(UUID().uuidString.lowercased()).example.supabase.co"
        VideoGenerationURLProtocol.register(handler: { request in
            recorder.record(request)
            return try handler(request)
        }, forHost: host)
        addTeardownBlock {
            VideoGenerationURLProtocol.unregister(host: host)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VideoGenerationURLProtocol.self]
        return VideoGenerationService(
            session: URLSession(configuration: configuration),
            baseURL: URL(string: "https://\(host)")!,
            anonKey: "anon-key"
        )
    }

    private func makeResultFileService(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> (
        service: VideoGenerationResultFileService,
        host: String,
        directory: URL
    ) {
        let host = "video-result-\(UUID().uuidString.lowercased()).example.supabase.co"
        VideoGenerationURLProtocol.register(handler: handler, forHost: host)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "VideoGenerationResultFileServiceTests-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock {
            VideoGenerationURLProtocol.unregister(host: host)
            try? FileManager.default.removeItem(at: directory)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VideoGenerationURLProtocol.self]
        return (
            VideoGenerationResultFileService(
                session: URLSession(configuration: configuration),
                baseURL: URL(string: "https://\(host)")!,
                directoryURL: directory
            ),
            host,
            directory
        )
    }

    private static func response(
        for request: URLRequest,
        statusCode: Int
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "VideoGenerationServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    private static let queuedJobResponse = Data(
        """
        {
          "job": {
            "id": "11111111-1111-4111-8111-111111111111",
            "status": "queued",
            "progress": 0,
            "credits_reserved": 650,
            "refunded": false,
            "result_url": null,
            "result_url_expires_at": null,
            "error_code": null,
            "created_at": "2026-07-25T12:00:00Z",
            "updated_at": "2026-07-25T12:00:00Z"
          },
          "replayed": false
        }
        """.utf8
    )
}

private final class VideoGenerationRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var request: URLRequest?

    var lastRequest: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return request
    }

    func record(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        self.request = request
    }
}

private typealias VideoGenerationRequestHandler =
    (URLRequest) throws -> (HTTPURLResponse, Data)

private final class VideoGenerationURLProtocolHandlerRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [String: VideoGenerationRequestHandler] = [:]

    func register(
        _ handler: @escaping VideoGenerationRequestHandler,
        forHost host: String
    ) {
        lock.lock()
        defer { lock.unlock() }
        handlers[host] = handler
    }

    func handler(forHost host: String) -> VideoGenerationRequestHandler? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[host]
    }

    func unregister(host: String) {
        lock.lock()
        defer { lock.unlock() }
        handlers.removeValue(forKey: host)
    }
}

private final class VideoGenerationURLProtocol: URLProtocol {
    private static let handlerRegistry =
        VideoGenerationURLProtocolHandlerRegistry()

    static func register(
        handler: @escaping VideoGenerationRequestHandler,
        forHost host: String
    ) {
        handlerRegistry.register(handler, forHost: host)
    }

    static func unregister(host: String) {
        handlerRegistry.unregister(host: host)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard
            let host = request.url?.host,
            let handler = Self.handlerRegistry.handler(forHost: host)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let capturedRequest = try request.materializingHTTPBodyForTesting()
            let (response, data) = try handler(capturedRequest)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
