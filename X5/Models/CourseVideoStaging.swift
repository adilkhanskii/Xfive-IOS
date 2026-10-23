import Foundation
import CoreTransferable
import UniformTypeIdentifiers

struct CourseGalleryVideo: Transferable {
    let fileURL: URL
    let originalFileName: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let stagedURL = try await CourseVideoStaging.stageAsync(
                sourceURL: received.file,
                lessonID: "photo-library"
            )
            let receivedName = received.file.lastPathComponent
            return CourseGalleryVideo(
                fileURL: stagedURL,
                originalFileName: receivedName.isEmpty ? stagedURL.lastPathComponent : receivedName
            )
        }
    }
}

enum CourseVideoStaging {
    private static let directoryName = "x5-course-videos"
    private static let preparedSuffix = "-upload-ready"

    static func stageAsync(sourceURL: URL, lessonID: String) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try stage(sourceURL: sourceURL, lessonID: lessonID)
        }.value
    }

    static func stage(sourceURL: URL, lessonID: String) throws -> URL {
        let fileManager = FileManager.default
        let directory = managedDirectory
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let safeLessonID = lessonID
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }
            .joined()
        let fileName = "\(safeLessonID)-\(UUID().uuidString).\(normalizedExtension(from: sourceURL))"
        let destination = directory.appendingPathComponent(fileName, isDirectory: false)

        do {
            try fileManager.copyItem(at: sourceURL, to: destination)
            return destination
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    static func isManaged(_ url: URL) -> Bool {
        let rootPath = managedDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let candidatePath = url
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        return candidatePath.hasPrefix(rootPath + "/")
    }

    static func removeIfManaged(_ url: URL?) {
        guard let url, isManaged(url) else { return }
        let preparedURL = preparedUploadURL(for: url)
        try? FileManager.default.removeItem(at: url)
        if preparedURL.standardizedFileURL != url.standardizedFileURL {
            try? FileManager.default.removeItem(at: preparedURL)
        }
    }

    static func preparedUploadURL(for sourceURL: URL) -> URL {
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        guard !stem.hasSuffix(preparedSuffix) else {
            return sourceURL
        }
        return sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                "\(stem)\(preparedSuffix).mp4",
                isDirectory: false
            )
    }

    private static var managedDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
            .standardizedFileURL
    }

    private static func normalizedExtension(from url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mov", "m4v", "mp4":
            return url.pathExtension.lowercased()
        default:
            return "mp4"
        }
    }
}
