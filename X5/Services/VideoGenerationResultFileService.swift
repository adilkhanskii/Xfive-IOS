import Foundation

enum VideoGenerationResultFileError: LocalizedError, Equatable {
    case invalidSignedURL
    case transport
    case invalidResponse
    case fileTooLarge
    case invalidVideo

    var errorDescription: String? {
        switch self {
        case .invalidSignedURL, .invalidResponse, .invalidVideo:
            return "Не удалось подготовить готовое видео. Обновите результат и попробуйте ещё раз."
        case .transport:
            return "Не удалось скачать готовое видео. Проверьте интернет и попробуйте ещё раз."
        case .fileTooLarge:
            return "Готовое видео слишком большое для сохранения на устройстве."
        }
    }
}

final class VideoGenerationResultFileService {
    static let maximumVideoBytes = 50 * 1024 * 1024

    private let session: URLSession
    private let expectedHost: String
    private let fileManager: FileManager
    private let directoryURL: URL

    init(
        session: URLSession = .shared,
        baseURL: URL = X5Config.supabaseBaseURL,
        fileManager: FileManager = .default,
        directoryURL: URL? = nil
    ) {
        self.session = session
        self.expectedHost = (baseURL.host ?? "").lowercased()
        self.fileManager = fileManager
        self.directoryURL = directoryURL
            ?? fileManager.temporaryDirectory
                .appendingPathComponent("x5-video-results", isDirectory: true)
    }

    func prepare(resultURL: URL, jobID: String) async throws -> URL {
        guard UUID(uuidString: jobID) != nil else {
            throw VideoGenerationResultFileError.invalidSignedURL
        }
        guard Self.isTrustedSignedResultURL(
            resultURL,
            expectedHost: expectedHost
        ) else {
            throw VideoGenerationResultFileError.invalidSignedURL
        }

        let temporaryURL: URL
        let response: URLResponse
        do {
            (temporaryURL, response) = try await session.download(from: resultURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw VideoGenerationResultFileError.transport
        }
        try Task.checkCancellation()
        defer { try? fileManager.removeItem(at: temporaryURL) }

        guard
            let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode)
        else {
            throw VideoGenerationResultFileError.invalidResponse
        }
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "")
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard contentType == "video/mp4" else {
            throw VideoGenerationResultFileError.invalidVideo
        }
        if let declaredLength = Self.contentLength(http),
           declaredLength > Self.maximumVideoBytes {
            throw VideoGenerationResultFileError.fileTooLarge
        }

        let values = try temporaryURL.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize, fileSize >= 12 else {
            throw VideoGenerationResultFileError.invalidVideo
        }
        guard fileSize <= Self.maximumVideoBytes else {
            throw VideoGenerationResultFileError.fileTooLarge
        }
        guard try Self.hasMP4Signature(at: temporaryURL) else {
            throw VideoGenerationResultFileError.invalidVideo
        }

        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let preparationID = UUID().uuidString.lowercased()
        let destination = directoryURL.appendingPathComponent(
            "x5-video-\(jobID.lowercased())--\(preparationID).mp4",
            isDirectory: false
        )
        do {
            try fileManager.moveItem(at: temporaryURL, to: destination)
        } catch {
            throw VideoGenerationResultFileError.invalidResponse
        }
        return destination
    }

    func cleanup(_ fileURL: URL?) {
        guard
            let fileURL,
            isControlledResultFile(fileURL)
        else {
            return
        }
        try? fileManager.removeItem(at: fileURL)
    }

    static func isTrustedSignedResultURL(
        _ url: URL,
        expectedHost: String
    ) -> Bool {
        guard
            url.scheme?.lowercased() == "https",
            url.host?.lowercased() == expectedHost.lowercased(),
            url.user == nil,
            url.password == nil,
            url.port == nil || url.port == 443,
            url.path.hasPrefix(
                "/storage/v1/object/sign/video-generation-results/"
            )
        else {
            return false
        }
        return true
    }

    private func isControlledResultFile(_ fileURL: URL) -> Bool {
        let cleanFile = fileURL.standardizedFileURL
        let cleanDirectory = directoryURL.standardizedFileURL
        guard cleanFile.deletingLastPathComponent() == cleanDirectory else {
            return false
        }
        let name = cleanFile.lastPathComponent.lowercased()
        guard name.hasPrefix("x5-video-"), name.hasSuffix(".mp4") else {
            return false
        }
        let identifiers = String(name.dropFirst("x5-video-".count).dropLast(4))
            .components(separatedBy: "--")
        guard identifiers.count == 2 else { return false }
        return identifiers.allSatisfy { UUID(uuidString: $0) != nil }
    }

    private static func contentLength(_ response: HTTPURLResponse) -> Int? {
        guard let raw = response.value(forHTTPHeaderField: "Content-Length") else {
            return nil
        }
        return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func hasMP4Signature(at url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 12) ?? Data()
        guard header.count >= 8 else { return false }
        return Array(header[4..<8]) == Array("ftyp".utf8)
    }
}
