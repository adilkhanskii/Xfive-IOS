import XCTest
@testable import X5

final class CourseVideoStagingTests: XCTestCase {
    func testStagesLargeVideoOffTheSourcePathAndCleansManagedCopy() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("x5-source-\(UUID().uuidString).mp4")
        let contents = Data("video-fixture".utf8)
        try contents.write(to: source, options: .atomic)
        defer { try? FileManager.default.removeItem(at: source) }

        let staged = try CourseVideoStaging.stage(sourceURL: source, lessonID: "lesson/one")
        defer { CourseVideoStaging.removeIfManaged(staged) }

        XCTAssertNotEqual(staged.standardizedFileURL, source.standardizedFileURL)
        XCTAssertTrue(CourseVideoStaging.isManaged(staged))
        XCTAssertEqual(try Data(contentsOf: staged), contents)

        CourseVideoStaging.removeIfManaged(staged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    func testCleanupNeverDeletesAnUnmanagedSourceFile() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("x5-unmanaged-\(UUID().uuidString).mp4")
        try Data("keep".utf8).write(to: source, options: .atomic)
        defer { try? FileManager.default.removeItem(at: source) }

        CourseVideoStaging.removeIfManaged(source)

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testCleanupAlsoRemovesCachedPreparedUpload() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("x5-preparation-source-\(UUID().uuidString).mov")
        try Data("source".utf8).write(to: source, options: .atomic)
        defer { try? FileManager.default.removeItem(at: source) }

        let staged = try CourseVideoStaging.stage(
            sourceURL: source,
            lessonID: "prepared-cleanup"
        )
        let prepared = CourseVideoStaging.preparedUploadURL(for: staged)
        try Data("prepared".utf8).write(to: prepared, options: .atomic)

        CourseVideoStaging.removeIfManaged(staged)

        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.path))
    }
}
