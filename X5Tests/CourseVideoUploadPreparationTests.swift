import AVFoundation
import CoreGraphics
import CoreVideo
import XCTest
@testable import X5

final class CourseVideoUploadPreparationTests: XCTestCase {
    func testLargeVideosArePreparedBeforeTheyReachSupabase() {
        XCTAssertFalse(
            CourseVideoUploadPolicy.requiresTranscoding(
                fileSizeBytes: CourseVideoUploadPolicy.directUploadLimitBytes
            )
        )
        XCTAssertTrue(
            CourseVideoUploadPolicy.requiresTranscoding(
                fileSizeBytes: CourseVideoUploadPolicy.directUploadLimitBytes + 1
            )
        )
    }

    func testEncodingPlanFitsLandscapeVideoInsideUploadBudget() throws {
        let plan = try CourseVideoUploadPolicy.makeEncodingPlan(
            durationSeconds: 120,
            presentationWidth: 3_840,
            presentationHeight: 2_160
        )

        XCTAssertEqual(plan.width, 1_280)
        XCTAssertEqual(plan.height, 720)
        XCTAssertEqual(plan.audioBitRate, 96_000)
        XCTAssertGreaterThanOrEqual(plan.videoBitRate, 700_000)

        let estimatedBytes = Double(plan.videoBitRate + plan.audioBitRate)
            * 120
            / 8
        XCTAssertLessThan(
            estimatedBytes,
            Double(CourseVideoUploadPolicy.transcodeTargetBytes)
        )
    }

    func testPublishedCourseUploadRequiresAtLeast720pSource() {
        XCTAssertTrue(
            CourseVideoUploadPolicy.acceptsSourceResolution(
                width: 1_280,
                height: 720
            )
        )
        XCTAssertTrue(
            CourseVideoUploadPolicy.acceptsSourceResolution(
                width: 1_080,
                height: 1_920
            )
        )
        XCTAssertFalse(
            CourseVideoUploadPolicy.acceptsSourceResolution(
                width: 480,
                height: 300
            )
        )
    }

    func testLongVideoIsRejectedInsteadOfBeingCompressedBelowHDQuality() {
        XCTAssertThrowsError(
            try CourseVideoUploadPolicy.makeEncodingPlan(
                durationSeconds: 15 * 60,
                presentationWidth: 1_920,
                presentationHeight: 1_080
            )
        ) { error in
            XCTAssertEqual(
                error as? CourseVideoUploadPreparationError,
                .videoTooLong
            )
        }
    }

    func testEncodingPlanKeepsPortraitOrientationAndDoesNotUpscaleSmallVideo() throws {
        let portrait = try CourseVideoUploadPolicy.makeEncodingPlan(
            durationSeconds: 120,
            presentationWidth: 1_080,
            presentationHeight: 1_920
        )
        XCTAssertEqual(portrait.width, 720)
        XCTAssertEqual(portrait.height, 1_280)

        let small = try CourseVideoUploadPolicy.makeEncodingPlan(
            durationSeconds: 120,
            presentationWidth: 640,
            presentationHeight: 360
        )
        XCTAssertEqual(small.width, 640)
        XCTAssertEqual(small.height, 360)
    }

    func testPreparedOutputMustKeepFullDurationAndStayBelowDirectLimit() {
        XCTAssertTrue(
            CourseVideoUploadPolicy.isAcceptablePreparedOutput(
                fileSizeBytes: CourseVideoUploadPolicy.directUploadLimitBytes,
                sourceDurationSeconds: 600,
                outputDurationSeconds: 599.5
            )
        )
        XCTAssertFalse(
            CourseVideoUploadPolicy.isAcceptablePreparedOutput(
                fileSizeBytes: CourseVideoUploadPolicy.directUploadLimitBytes + 1,
                sourceDurationSeconds: 600,
                outputDurationSeconds: 600
            )
        )
        XCTAssertFalse(
            CourseVideoUploadPolicy.isAcceptablePreparedOutput(
                fileSizeBytes: CourseVideoUploadPolicy.transcodeTargetBytes,
                sourceDurationSeconds: 600,
                outputDurationSeconds: 420
            )
        )
    }

    func testCompositionTransformPreservesAllFourStandardOrientations() throws {
        struct Scenario {
            let name: String
            let preferredTransform: CGAffineTransform
            let targetSize: CGSize
            let expectedCorners: [CGPoint]
        }

        let sourceSize = CGSize(width: 1_920, height: 1_080)
        let sourceCorners = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 1_920, y: 0),
            CGPoint(x: 1_920, y: 1_080),
            CGPoint(x: 0, y: 1_080)
        ]
        let scenarios = [
            Scenario(
                name: "identity",
                preferredTransform: .identity,
                targetSize: CGSize(width: 1_280, height: 720),
                expectedCorners: [
                    CGPoint(x: 0, y: 0),
                    CGPoint(x: 1_280, y: 0),
                    CGPoint(x: 1_280, y: 720),
                    CGPoint(x: 0, y: 720)
                ]
            ),
            Scenario(
                name: "clockwise-90",
                preferredTransform: CGAffineTransform(
                    a: 0,
                    b: 1,
                    c: -1,
                    d: 0,
                    tx: 1_080,
                    ty: 0
                ),
                targetSize: CGSize(width: 720, height: 1_280),
                expectedCorners: [
                    CGPoint(x: 720, y: 0),
                    CGPoint(x: 720, y: 1_280),
                    CGPoint(x: 0, y: 1_280),
                    CGPoint(x: 0, y: 0)
                ]
            ),
            Scenario(
                name: "upside-down-180",
                preferredTransform: CGAffineTransform(
                    a: -1,
                    b: 0,
                    c: 0,
                    d: -1,
                    tx: 1_920,
                    ty: 1_080
                ),
                targetSize: CGSize(width: 1_280, height: 720),
                expectedCorners: [
                    CGPoint(x: 1_280, y: 720),
                    CGPoint(x: 0, y: 720),
                    CGPoint(x: 0, y: 0),
                    CGPoint(x: 1_280, y: 0)
                ]
            ),
            Scenario(
                name: "counterclockwise-90",
                preferredTransform: CGAffineTransform(
                    a: 0,
                    b: -1,
                    c: 1,
                    d: 0,
                    tx: 0,
                    ty: 1_920
                ),
                targetSize: CGSize(width: 720, height: 1_280),
                expectedCorners: [
                    CGPoint(x: 0, y: 1_280),
                    CGPoint(x: 0, y: 0),
                    CGPoint(x: 720, y: 0),
                    CGPoint(x: 720, y: 1_280)
                ]
            )
        ]

        for scenario in scenarios {
            let transform = try CourseVideoCompositionTransform.make(
                sourceSize: sourceSize,
                preferredTransform: scenario.preferredTransform,
                targetSize: scenario.targetSize
            )
            let presentationRect = CGRect(
                origin: .zero,
                size: sourceSize
            ).applying(transform)
            XCTAssertEqual(
                presentationRect.minX,
                0,
                accuracy: 0.01,
                scenario.name
            )
            XCTAssertEqual(
                presentationRect.minY,
                0,
                accuracy: 0.01,
                scenario.name
            )
            XCTAssertEqual(
                presentationRect.width,
                scenario.targetSize.width,
                accuracy: 0.01,
                scenario.name
            )
            XCTAssertEqual(
                presentationRect.height,
                scenario.targetSize.height,
                accuracy: 0.01,
                scenario.name
            )

            for (sourceCorner, expectedCorner) in zip(
                sourceCorners,
                scenario.expectedCorners
            ) {
                let actualCorner = sourceCorner.applying(transform)
                XCTAssertEqual(
                    actualCorner.x,
                    expectedCorner.x,
                    accuracy: 0.01,
                    scenario.name
                )
                XCTAssertEqual(
                    actualCorner.y,
                    expectedCorner.y,
                    accuracy: 0.01,
                    scenario.name
                )
            }
        }
    }

    func testCompositionTransformAspectFitsAndCentersWithoutCropping() throws {
        let sourceSize = CGSize(width: 1_920, height: 1_080)
        let transform = try CourseVideoCompositionTransform.make(
            sourceSize: sourceSize,
            preferredTransform: .identity,
            targetSize: CGSize(width: 1_280, height: 1_280)
        )
        let presentationRect = CGRect(
            origin: .zero,
            size: sourceSize
        ).applying(transform)

        XCTAssertEqual(presentationRect.minX, 0, accuracy: 0.01)
        XCTAssertEqual(presentationRect.minY, 280, accuracy: 0.01)
        XCTAssertEqual(presentationRect.width, 1_280, accuracy: 0.01)
        XCTAssertEqual(presentationRect.height, 720, accuracy: 0.01)
    }

    func testServer413MapsToLocalizedSizeErrorWithoutRawLibraryText() {
        let error = SupabaseResumableVideoUploadError.fromUploadFailure(
            details: "Could not create file on server: response status 413"
        )

        XCTAssertEqual(error, .fileTooLarge)
        XCTAssertFalse(error.localizedDescription.contains("Could not create file"))
        XCTAssertTrue(error.localizedDescription.contains("50"))
        XCTAssertTrue(error.shouldDiscardResumableState)
        XCTAssertFalse(
            SupabaseResumableVideoUploadError
                .uploadFailed(details: "The network connection was lost")
                .shouldDiscardResumableState
        )
    }

    func testLargeLandscapeAndPortraitVideosArePreparedWithFullVideo() async throws {
        try await assertLargeVideoPreparation(
            name: "landscape",
            transform: .identity,
            expectedWidth: 1_280,
            expectedHeight: 720
        )
        try await assertLargeVideoPreparation(
            name: "portrait",
            transform: CGAffineTransform(
                a: 0,
                b: 1,
                c: -1,
                d: 0,
                tx: 1_080,
                ty: 0
            ),
            expectedWidth: 720,
            expectedHeight: 1_280
        )
    }

    func testOneGigabyteSparseVideoUsesNativeFallbackWithoutReselection() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "x5-sparse-one-gigabyte-\(UUID().uuidString).mp4"
            )
        try await makeVideoFixture(at: fixture, transform: .identity)
        try appendSparseFreeAtom(
            to: fixture,
            finalSize: 1_024 * 1_024 * 1_024 + 4_096
        )
        defer {
            try? FileManager.default.removeItem(at: fixture)
            try? FileManager.default.removeItem(
                at: CourseVideoStaging.preparedUploadURL(for: fixture)
            )
        }

        let logicalSize = try XCTUnwrap(
            fixture.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )
        XCTAssertGreaterThanOrEqual(
            Int64(logicalSize),
            1_024 * 1_024 * 1_024
        )

        var primarySourceURLs: [URL] = []
        let preparer = CourseVideoUploadPreparer(
            primaryExporter: { request, _ in
                primarySourceURLs.append(request.sourceURL)
                throw NSError(
                    domain: "NextLevelPrimary",
                    code: -11_800
                )
            }
        )

        let prepared = try await preparer.prepare(fileURL: fixture)

        XCTAssertEqual(primarySourceURLs, [fixture])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path))
        XCTAssertNotEqual(
            prepared.standardizedFileURL,
            fixture.standardizedFileURL
        )
        try await assertPreparedVideoIsH264AndUploadable(
            prepared,
            sourceURL: fixture
        )
    }

    func testSixMinuteVideoIsPreparedInFullBelowUploadLimit() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "x5-six-minute-course-video-\(UUID().uuidString).mp4"
            )
        try await makeVideoFixture(
            at: fixture,
            transform: .identity,
            width: 640,
            height: 360,
            frameCount: 360,
            timescale: 1
        )
        try appendSparseFreeAtom(
            to: fixture,
            finalSize: CourseVideoUploadPolicy.directUploadLimitBytes + 4_096
        )
        defer {
            try? FileManager.default.removeItem(at: fixture)
            try? FileManager.default.removeItem(
                at: CourseVideoStaging.preparedUploadURL(for: fixture)
            )
        }

        let sourceAsset = AVURLAsset(url: fixture)
        let sourceDuration = try await sourceAsset.load(.duration).seconds
        XCTAssertEqual(sourceDuration, 360, accuracy: 0.05)

        let prepared = try await CourseVideoUploadPreparer().prepare(
            fileURL: fixture
        )

        try await assertPreparedVideoIsH264AndUploadable(
            prepared,
            sourceURL: fixture
        )
        let preparedDuration = try await AVURLAsset(url: prepared)
            .load(.duration)
            .seconds
        XCTAssertEqual(preparedDuration, 360, accuracy: 0.5)
    }

    func testRealClientCourseVideoUsesProductionUploadPreparationWithoutTruncation() async throws {
        let fixtureName = "x5-client-course-lesson.mp4"
        let fixture = try XCTUnwrap(
            FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first
        ).appendingPathComponent(fixtureName)
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            throw XCTSkip(
                "Install \(fixtureName) in the simulator app Documents directory "
                    + "to run the real-client-video acceptance test"
            )
        }

        let expectedSizeBytes = 17_656_264
        let expectedDurationSeconds = 371.1667
        let sourceSize = try XCTUnwrap(
            fixture.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )
        XCTAssertEqual(sourceSize, expectedSizeBytes)
        XCTAssertLessThanOrEqual(
            Int64(sourceSize),
            CourseVideoUploadPolicy.directUploadLimitBytes
        )
        XCTAssertEqual(fixture.pathExtension.lowercased(), "mp4")
        let majorBrand = try mp4MajorBrand(at: fixture)

        let sourceAsset = AVURLAsset(url: fixture)
        let sourceIsPlayable = try await sourceAsset.load(.isPlayable)
        XCTAssertTrue(sourceIsPlayable)
        let sourceDuration = try await sourceAsset.load(.duration).seconds
        XCTAssertEqual(
            sourceDuration,
            expectedDurationSeconds,
            accuracy: 0.05
        )
        let sourceVideoCodecs = try await codecTypes(
            in: sourceAsset,
            mediaType: .video
        )
        XCTAssertTrue(sourceVideoCodecs.contains(kCMVideoCodecType_H264))
        let sourceAudioCodecs = try await codecTypes(
            in: sourceAsset,
            mediaType: .audio
        )
        XCTAssertTrue(sourceAudioCodecs.contains(kAudioFormatMPEG4AAC))

        let prepared = try await CourseVideoUploadPreparer().prepare(
            fileURL: fixture
        )

        // Every Supabase-path upload is re-encoded to H.264/AAC .mp4 with
        // faststart, even below 47 MB; the source file stays untouched.
        XCTAssertNotEqual(
            prepared.standardizedFileURL,
            fixture.standardizedFileURL
        )
        defer { CourseVideoStaging.removeIfManaged(prepared) }
        XCTAssertEqual(prepared.pathExtension.lowercased(), "mp4")
        let preparedSize = try XCTUnwrap(
            prepared.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )
        XCTAssertLessThanOrEqual(
            Int64(preparedSize),
            CourseVideoUploadPolicy.directUploadLimitBytes
        )

        let preparedAsset = AVURLAsset(url: prepared)
        let preparedIsPlayable = try await preparedAsset.load(.isPlayable)
        XCTAssertTrue(preparedIsPlayable)
        let preparedDuration = try await preparedAsset.load(.duration).seconds
        XCTAssertEqual(
            preparedDuration,
            sourceDuration,
            accuracy: max(1, sourceDuration * 0.01)
        )
        XCTAssertTrue(
            CourseVideoUploadPolicy.isAcceptablePreparedOutput(
                fileSizeBytes: Int64(preparedSize),
                sourceDurationSeconds: sourceDuration,
                outputDurationSeconds: preparedDuration
            )
        )
        let preparedVideoCodecs = try await codecTypes(
            in: preparedAsset,
            mediaType: .video
        )
        let preparedAudioCodecs = try await codecTypes(
            in: preparedAsset,
            mediaType: .audio
        )
        XCTAssertEqual(preparedVideoCodecs, [kCMVideoCodecType_H264])
        XCTAssertTrue(
            preparedAudioCodecs.isEmpty
                || preparedAudioCodecs == [kAudioFormatMPEG4AAC]
        )

        let report = [
            "source_bytes=\(sourceSize)",
            "source_duration_seconds=\(sourceDuration)",
            "prepared_bytes=\(preparedSize)",
            "prepared_duration_seconds=\(preparedDuration)",
            "container=mp4 (major_brand=\(majorBrand))",
            "video_codecs=\(sourceVideoCodecs.map(fourCCString).joined(separator: ","))",
            "audio_codecs=\(sourceAudioCodecs.map(fourCCString).joined(separator: ","))",
            "production_path=transcoded_h264_faststart",
            "prepared_url_is_source=false"
        ].joined(separator: "\n")
        let attachment = XCTAttachment(string: report)
        attachment.name = "Real client course video verification"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testNativeFallbackNormalizesHEVCToH264WhenAvailable() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "x5-hevc-fallback-\(UUID().uuidString).mp4"
            )
        do {
            try await makeVideoFixture(
                at: fixture,
                transform: .identity,
                codec: .hevc
            )
        } catch {
            try? FileManager.default.removeItem(at: fixture)
            throw XCTSkip(
                "HEVC fixture encoding is unavailable on this runner: \(error)"
            )
        }
        try appendSparseFreeAtom(
            to: fixture,
            finalSize: CourseVideoUploadPolicy.directUploadLimitBytes + 4_096
        )
        defer {
            try? FileManager.default.removeItem(at: fixture)
            try? FileManager.default.removeItem(
                at: CourseVideoStaging.preparedUploadURL(for: fixture)
            )
        }

        let preparer = CourseVideoUploadPreparer(
            primaryExporter: { _, _ in
                throw NSError(
                    domain: "NextLevelUnsupportedCodec",
                    code: -11_821
                )
            }
        )
        let prepared = try await preparer.prepare(fileURL: fixture)

        try await assertPreparedVideoIsH264AndUploadable(
            prepared,
            sourceURL: fixture
        )
    }

    func testBothExporterFailuresSurfaceSanitizedDiagnosticsAndKeepSource() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "x5-export-diagnostics-\(UUID().uuidString).mp4"
            )
        try await makeVideoFixture(at: fixture, transform: .identity)
        try appendSparseFreeAtom(
            to: fixture,
            finalSize: CourseVideoUploadPolicy.directUploadLimitBytes + 4_096
        )
        defer {
            try? FileManager.default.removeItem(at: fixture)
            try? FileManager.default.removeItem(
                at: CourseVideoStaging.preparedUploadURL(for: fixture)
            )
        }

        let privatePath = "/private/var/mobile/secret/video.mov"
        let preparer = CourseVideoUploadPreparer(
            primaryExporter: { _, _ in
                throw NSError(
                    domain: "NextLevelSessionExporter",
                    code: -11_800,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Reader failed at \(privatePath)"
                    ]
                )
            },
            fallbackExporter: { _, _ in
                throw NSError(
                    domain: AVFoundationErrorDomain,
                    code: -11_821,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Native export failed at \(privatePath)"
                    ]
                )
            }
        )

        do {
            _ = try await preparer.prepare(fileURL: fixture)
            XCTFail("Both exporter failures must be surfaced")
        } catch let error as CourseVideoUploadPreparationError {
            guard case let .exportFailed(primary, fallback) = error else {
                return XCTFail("Unexpected preparation error: \(error)")
            }
            XCTAssertEqual(primary.strategy, .nextLevel)
            XCTAssertEqual(fallback.strategy, .avFoundation)
            XCTAssertEqual(primary.underlyingCode, -11_800)
            XCTAssertEqual(fallback.underlyingCode, -11_821)
            XCTAssertTrue(error.localizedDescription.contains("nextlevel"))
            XCTAssertTrue(error.localizedDescription.contains("avfoundation"))
            XCTAssertFalse(error.localizedDescription.contains(privatePath))
            XCTAssertFalse(error.localizedDescription.contains(fixture.path))
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path))
    }

    private func assertLargeVideoPreparation(
        name: String,
        transform: CGAffineTransform,
        expectedWidth: CGFloat,
        expectedHeight: CGFloat
    ) async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "x5-large-\(name)-video-\(UUID().uuidString).mp4"
            )
        try await makeVideoFixture(at: fixture, transform: transform)
        try appendFreeAtom(
            to: fixture,
            finalSize: CourseVideoUploadPolicy.directUploadLimitBytes + 1_000_000
        )
        defer { try? FileManager.default.removeItem(at: fixture) }

        let staged = try CourseVideoStaging.stage(
            sourceURL: fixture,
            lessonID: "integration-\(name)"
        )
        defer { CourseVideoStaging.removeIfManaged(staged) }

        let sourceAsset = AVURLAsset(url: staged)
        let sourceTime = try await sourceAsset.load(.duration)
        let sourceDuration = sourceTime.seconds
        let sourceSignature = try await presentationSignature(
            of: sourceAsset
        )
        assertSignatureHasVisiblePattern(
            sourceSignature,
            context: "\(name) source"
        )
        let preparer = CourseVideoUploadPreparer()
        let firstPrepared = try await preparer.prepare(fileURL: staged)
        let firstModified = try firstPrepared.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate

        XCTAssertNotEqual(
            firstPrepared.standardizedFileURL,
            staged.standardizedFileURL
        )
        let outputAsset = AVURLAsset(url: firstPrepared)
        let outputTracks = try await outputAsset.loadTracks(
            withMediaType: .video
        )
        XCTAssertFalse(outputTracks.isEmpty)
        let outputTrack = try XCTUnwrap(outputTracks.first)
        let naturalSize = try await outputTrack.load(.naturalSize)
        let preferredTransform = try await outputTrack.load(
            .preferredTransform
        )
        let presentationRect = CGRect(
            origin: .zero,
            size: naturalSize
        ).applying(preferredTransform)
        XCTAssertEqual(
            abs(presentationRect.width),
            expectedWidth,
            accuracy: 2
        )
        XCTAssertEqual(
            abs(presentationRect.height),
            expectedHeight,
            accuracy: 2
        )
        let outputTime = try await outputAsset.load(.duration)
        let outputDuration = outputTime.seconds
        XCTAssertEqual(outputDuration, sourceDuration, accuracy: 0.05)
        let outputSignature = try await presentationSignature(
            of: outputAsset
        )
        assertPresentationSignaturesMatch(
            sourceSignature,
            outputSignature,
            context: name
        )
        let outputSize = try XCTUnwrap(
            firstPrepared.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )
        XCTAssertTrue(
            CourseVideoUploadPolicy.isAcceptablePreparedOutput(
                fileSizeBytes: Int64(outputSize),
                sourceDurationSeconds: sourceDuration,
                outputDurationSeconds: outputDuration
            )
        )

        let secondPrepared = try await preparer.prepare(fileURL: staged)
        let secondModified = try secondPrepared.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate
        XCTAssertEqual(firstPrepared, secondPrepared)
        XCTAssertEqual(firstModified, secondModified)

        CourseVideoStaging.removeIfManaged(staged)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: firstPrepared.path)
        )
    }

    private func makeVideoFixture(
        at url: URL,
        transform: CGAffineTransform,
        codec: AVVideoCodecType = .h264,
        width: Int = 1_920,
        height: Int = 1_080,
        frameCount: Int = 10,
        timescale: Int32 = 30
    ) async throws {
        guard width > 0,
              height > 0,
              frameCount > 0,
              timescale > 0 else {
            throw fixtureError("Invalid fixture dimensions or duration")
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height
            ]
        )
        input.expectsMediaDataInRealTime = false
        input.transform = transform
        guard writer.canAdd(input) else {
            throw fixtureError("Cannot add video input")
        }
        writer.add(input)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        guard writer.startWriting() else {
            throw writer.error ?? fixtureError("Cannot start fixture writer")
        }
        writer.startSession(atSourceTime: .zero)

        let pool = try XCTUnwrap(adaptor.pixelBufferPool)
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(
            nil,
            pool,
            &pixelBuffer
        ) == kCVReturnSuccess,
              let pixelBuffer else {
            throw fixtureError("Cannot allocate fixture pixel buffer")
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            for y in 0..<height {
                let row = bytes.advanced(by: y * bytesPerRow)
                for x in 0..<width {
                    let pixel = row.advanced(by: x * 4)
                    let color: (blue: UInt8, green: UInt8, red: UInt8)
                    switch (x < width / 2, y < height / 2) {
                    case (true, true):
                        color = (30, 30, 230)
                    case (false, true):
                        color = (30, 220, 30)
                    case (true, false):
                        color = (220, 30, 30)
                    case (false, false):
                        color = (30, 220, 220)
                    }
                    pixel[0] = color.blue
                    pixel[1] = color.green
                    pixel[2] = color.red
                    pixel[3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        for frame in 0..<frameCount {
            var waitCount = 0
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
                waitCount += 1
                guard waitCount < 15_000 else {
                    throw fixtureError("Fixture writer timed out")
                }
            }
            guard adaptor.append(
                pixelBuffer,
                withPresentationTime: CMTime(
                    value: Int64(frame),
                    timescale: timescale
                )
            ) else {
                throw writer.error ?? fixtureError("Cannot append fixture frame")
            }
        }
        input.markAsFinished()

        let finishError = fixtureError("Cannot finish fixture writer")
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            writer.finishWriting {
                if writer.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(
                        throwing: writer.error
                            ?? finishError
                    )
                }
            }
        }
    }

    private func presentationSignature(
        of asset: AVAsset
    ) async throws -> [UInt8] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: .zero).image
        return try rgbaThumbnail(of: image, width: 4, height: 4)
    }

    private func rgbaThumbnail(
        of image: CGImage,
        width: Int,
        height: Int
    ) throws -> [UInt8] {
        var pixels = [UInt8](
            repeating: 0,
            count: width * height * 4
        )
        let rendered = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo:
                    CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: width, height: height)
            )
            return true
        }
        guard rendered else {
            throw fixtureError("Cannot render video frame signature")
        }
        return pixels
    }

    private func assertSignatureHasVisiblePattern(
        _ signature: [UInt8],
        context: String
    ) {
        let colorChannels = signature.enumerated().compactMap {
            index, value in
            index % 4 == 3 ? nil : value
        }
        XCTAssertGreaterThan(
            Int(colorChannels.max() ?? 0)
                - Int(colorChannels.min() ?? 0),
            100,
            "\(context) fixture is blank or monochrome"
        )
    }

    private func assertPresentationSignaturesMatch(
        _ expected: [UInt8],
        _ actual: [UInt8],
        context: String
    ) {
        XCTAssertEqual(
            actual.count,
            expected.count,
            "\(context) signature dimensions differ"
        )
        guard actual.count == expected.count else { return }

        var totalDifference = 0
        var comparedChannelCount = 0
        var maximumDifference = 0
        for index in expected.indices where index % 4 != 3 {
            let difference = abs(
                Int(expected[index]) - Int(actual[index])
            )
            totalDifference += difference
            comparedChannelCount += 1
            maximumDifference = max(maximumDifference, difference)
        }
        let meanDifference = Double(totalDifference)
            / Double(max(comparedChannelCount, 1))

        XCTAssertLessThan(
            meanDifference,
            35,
            "\(context) output was cropped, blank, mirrored, or rotated"
        )
        XCTAssertLessThan(
            maximumDifference,
            100,
            "\(context) output lost part of the source frame"
        )
    }

    private func appendFreeAtom(to url: URL, finalSize: Int64) throws {
        try appendSparseFreeAtom(to: url, finalSize: finalSize)
    }

    private func appendSparseFreeAtom(
        to url: URL,
        finalSize: Int64
    ) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let currentSize = Int64(try handle.seekToEnd())
        let atomSize = finalSize - currentSize
        guard atomSize >= 8, atomSize <= Int64(UInt32.max) else {
            throw fixtureError("Invalid padding atom size")
        }

        var bigEndianSize = UInt32(atomSize).bigEndian
        try withUnsafeBytes(of: &bigEndianSize) {
            try handle.write(contentsOf: Data($0))
        }
        try handle.write(contentsOf: Data("free".utf8))
        try handle.truncate(atOffset: UInt64(finalSize))
    }

    private func assertPreparedVideoIsH264AndUploadable(
        _ preparedURL: URL,
        sourceURL: URL
    ) async throws {
        let sourceAsset = AVURLAsset(url: sourceURL)
        let sourceDuration = try await sourceAsset.load(.duration)
        let preparedAsset = AVURLAsset(url: preparedURL)
        let preparedDuration = try await preparedAsset.load(.duration)
        let videoTracks = try await preparedAsset.loadTracks(
            withMediaType: .video
        )
        let videoTrack = try XCTUnwrap(
            videoTracks.first
        )
        let formatDescriptions = try await videoTrack.load(
            .formatDescriptions
        )
        let codecTypes = formatDescriptions.map {
            CMFormatDescriptionGetMediaSubType($0)
        }
        XCTAssertTrue(codecTypes.contains(kCMVideoCodecType_H264))

        let preparedSize = try XCTUnwrap(
            preparedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )
        XCTAssertTrue(
            CourseVideoUploadPolicy.isAcceptablePreparedOutput(
                fileSizeBytes: Int64(preparedSize),
                sourceDurationSeconds: sourceDuration.seconds,
                outputDurationSeconds: preparedDuration.seconds
            )
        )
    }

    private func codecTypes(
        in asset: AVAsset,
        mediaType: AVMediaType
    ) async throws -> [FourCharCode] {
        let tracks = try await asset.loadTracks(withMediaType: mediaType)
        var result: [FourCharCode] = []
        for track in tracks {
            let descriptions = try await track.load(.formatDescriptions)
            result.append(
                contentsOf: descriptions.map {
                    CMFormatDescriptionGetMediaSubType($0)
                }
            )
        }
        return result
    }

    private func mp4MajorBrand(at url: URL) throws -> String {
        let header = try Data(contentsOf: url, options: .mappedIfSafe)
            .prefix(12)
        guard header.count == 12,
              String(data: Data(header[4..<8]), encoding: .ascii) == "ftyp",
              let brand = String(
                  data: Data(header[8..<12]),
                  encoding: .ascii
              )
        else {
            throw fixtureError("Client video is not an ISO BMFF/MP4 file")
        }
        return brand
    }

    private func fourCCString(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii)
            ?? String(format: "0x%08x", value)
    }

    private func fixtureError(_ message: String) -> NSError {
        NSError(
            domain: "CourseVideoUploadPreparationTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
