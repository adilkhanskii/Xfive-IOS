import Foundation
import TUSKit

enum SupabaseResumableVideoUploadError: Error, Equatable, LocalizedError {
    case invalidEndpoint
    case invalidBucketName
    case invalidObjectName
    case missingAccessToken
    case fileTooLarge
    case uploadFailed(details: String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Не удалось подготовить адрес возобновляемой загрузки."
        case .invalidBucketName:
            return "Указано неверное хранилище видео."
        case .invalidObjectName:
            return "Указан небезопасный путь видео."
        case .missingAccessToken:
            return "Сессия истекла. Войдите снова и повторите загрузку."
        case .fileTooLarge:
            return "Видео превышает лимит хранилища 50 МБ. Выберите более короткое видео."
        case .uploadFailed(let details):
            return "Возобновляемая загрузка видео не завершилась. Можно повторить без повторного выбора файла. \(details)"
        }
    }

    static func fromUploadFailure(details: String) -> Self {
        let normalized = details.lowercased()
        if normalized.contains("413")
            || normalized.contains("entitytoolarge")
            || normalized.contains("entity too large") {
            return .fileTooLarge
        }
        return .uploadFailed(details: details)
    }

    var shouldDiscardResumableState: Bool {
        self == .fileTooLarge
    }
}

struct SupabaseResumableVideoUploadProgress {
    static func fraction(bytesUploaded: Int, totalBytes: Int) -> Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(bytesUploaded) / Double(totalBytes), 0), 1)
    }
}

struct SupabaseTUSUploadDescriptor {
    static let requiredChunkSize = 6 * 1024 * 1024

    let endpoint: URL
    let chunkSize: Int
    let context: [String: String]
    let persistentHeaders: [String: String]
    let publicURL: URL

    init(
        baseURL: URL,
        anonKey: String,
        bucketName: String,
        objectName: String,
        contentType: String
    ) throws {
        guard bucketName.range(
            of: #"^[A-Za-z0-9_-]+$"#,
            options: .regularExpression
        ) != nil else {
            throw SupabaseResumableVideoUploadError.invalidBucketName
        }

        let pathParts = objectName.split(separator: "/", omittingEmptySubsequences: false)
        guard !objectName.isEmpty,
              !objectName.hasPrefix("/"),
              !objectName.contains("\\"),
              !pathParts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else {
            throw SupabaseResumableVideoUploadError.invalidObjectName
        }

        guard var endpointComponents = URLComponents(
            url: baseURL,
            resolvingAgainstBaseURL: false
        ), let host = endpointComponents.host else {
            throw SupabaseResumableVideoUploadError.invalidEndpoint
        }
        if host.hasSuffix(".supabase.co") && !host.hasSuffix(".storage.supabase.co") {
            endpointComponents.host = host.replacingOccurrences(
                of: ".supabase.co",
                with: ".storage.supabase.co"
            )
        }
        endpointComponents.path = "/storage/v1/upload/resumable"
        endpointComponents.query = nil
        endpointComponents.fragment = nil
        guard let endpoint = endpointComponents.url else {
            throw SupabaseResumableVideoUploadError.invalidEndpoint
        }

        var publicComponents = URLComponents(
            url: baseURL,
            resolvingAgainstBaseURL: false
        )
        publicComponents?.path = "/storage/v1/object/public/\(bucketName)/\(objectName)"
        publicComponents?.query = nil
        publicComponents?.fragment = nil
        guard let publicURL = publicComponents?.url else {
            throw SupabaseResumableVideoUploadError.invalidEndpoint
        }

        self.endpoint = endpoint
        chunkSize = Self.requiredChunkSize
        context = [
            "bucketName": bucketName,
            "objectName": objectName,
            "contentType": contentType,
            "cacheControl": "3600"
        ]
        persistentHeaders = [
            "apikey": anonKey,
            "x-upsert": "true"
        ]
        self.publicURL = publicURL
    }
}

enum SupabaseTUSAuthorization {
    static func normalizedToken(_ accessToken: String) throws -> String {
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw SupabaseResumableVideoUploadError.missingAccessToken
        }
        return token
    }

    static func headers(
        persistentHeaders: [String: String],
        accessToken: String
    ) throws -> [String: String] {
        let token = try normalizedToken(accessToken)
        var headers = persistentHeaders
        headers["Authorization"] = "Bearer \(token)"
        return headers
    }
}

enum SupabaseTUSSessionConfiguration {
    static func make() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.waitsForConnectivity = true
        return configuration
    }
}

/// Thin async adapter around the pinned TUSKit fork. Authentication is
/// regenerated for every request and remains transient; TUSKit persists only
/// the anon key, x-upsert flag and non-secret metadata needed for resuming.
final class SupabaseResumableVideoUploader {
    typealias ProgressHandler = (Double) -> Void
    typealias AccessTokenProvider = () async -> String?

    private let baseURL: URL
    private let anonKey: String
    private let lock = NSLock()
    private var activeSessions: [UUID: UploadSession] = [:]

    init(baseURL: URL, anonKey: String) {
        self.baseURL = baseURL
        self.anonKey = anonKey
    }

    func upload(
        fileURL: URL,
        bucketName: String,
        objectName: String,
        contentType: String,
        accessToken: String,
        accessTokenProvider: AccessTokenProvider? = nil,
        progress: @escaping ProgressHandler
    ) async throws -> URL {
        if let fileSize = try? fileURL.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize,
           CourseVideoUploadPolicy.requiresTranscoding(
               fileSizeBytes: Int64(fileSize)
           ) {
            throw SupabaseResumableVideoUploadError.fileTooLarge
        }

        let initialToken = try SupabaseTUSAuthorization.normalizedToken(accessToken)
        let resolvedTokenProvider = accessTokenProvider ?? { initialToken }
        let descriptor = try SupabaseTUSUploadDescriptor(
            baseURL: baseURL,
            anonKey: anonKey,
            bucketName: bucketName,
            objectName: objectName,
            contentType: contentType
        )

        let sessionKey = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            do {
                let session = try UploadSession(
                    descriptor: descriptor,
                    initialAccessToken: initialToken,
                    accessTokenProvider: resolvedTokenProvider,
                    progress: progress
                ) { [weak self] result in
                    self?.removeSession(sessionKey)
                    continuation.resume(with: result)
                }
                retainSession(session, key: sessionKey)
                try session.start(fileURL: fileURL)
            } catch {
                removeSession(sessionKey)
                continuation.resume(throwing: error)
            }
        }
    }

    private func retainSession(_ session: UploadSession, key: UUID) {
        lock.lock()
        activeSessions[key] = session
        lock.unlock()
    }

    private func removeSession(_ key: UUID) {
        lock.lock()
        activeSessions.removeValue(forKey: key)
        lock.unlock()
    }
}

private final class UploadSession: NSObject, TUSClientDelegate {
    private let descriptor: SupabaseTUSUploadDescriptor
    private let progressHandler: SupabaseResumableVideoUploader.ProgressHandler
    private let completion: (Result<URL, Error>) -> Void
    private let client: TUSClient
    private var isFinished = false
    private var didManualResume = false
    private var didRestartStalledResume = false
    private var activeUploadID: UUID?
    private var sourceFileURL: URL?
    private var resumeHadActivity = false
    private var resumeWatchdog: DispatchWorkItem?
    private var lastFileError: TUSClientError?

    init(
        descriptor: SupabaseTUSUploadDescriptor,
        initialAccessToken: String,
        accessTokenProvider: @escaping SupabaseResumableVideoUploader.AccessTokenProvider,
        progress: @escaping SupabaseResumableVideoUploader.ProgressHandler,
        completion: @escaping (Result<URL, Error>) -> Void
    ) throws {
        self.descriptor = descriptor
        progressHandler = progress
        self.completion = completion

        let configuration = SupabaseTUSSessionConfiguration.make()
        let session = URLSession(configuration: configuration)
        let storageDirectory = Self.storageDirectory(for: descriptor.context)
        let fallbackToken = try SupabaseTUSAuthorization.normalizedToken(
            initialAccessToken
        )

        client = try TUSClient(
            server: descriptor.endpoint,
            storageDirectory: storageDirectory,
            session: session,
            chunkSize: descriptor.chunkSize,
            supportedExtensions: [.creation],
            reportingQueue: .main,
            generateHeaders: { _, persistentHeaders, completeHeaders in
                Task {
                    let candidate = await accessTokenProvider()
                    let token = (try? SupabaseTUSAuthorization.normalizedToken(
                        candidate ?? ""
                    )) ?? fallbackToken
                    let headers = (try? SupabaseTUSAuthorization.headers(
                        persistentHeaders: persistentHeaders,
                        accessToken: token
                    )) ?? persistentHeaders
                    completeHeaders(headers)
                }
            },
            persistGeneratedHeaders: false
        )
        super.init()
        client.delegate = self
    }

    func start(fileURL: URL) throws {
        sourceFileURL = fileURL
        let storedUploads = client.start()
        if let stored = storedUploads.first(where: {
            $0.1?["objectName"] == descriptor.context["objectName"]
        }) {
            activeUploadID = stored.0
            scheduleResumeWatchdog(for: stored.0)
            return
        }
        try beginFreshUpload(fileURL: fileURL)
    }

    private func beginFreshUpload(fileURL: URL) throws {
        resumeWatchdog?.cancel()
        resumeWatchdog = nil
        resumeHadActivity = false
        activeUploadID = try client.uploadFileAt(
            filePath: fileURL,
            customHeaders: descriptor.persistentHeaders,
            context: descriptor.context
        )
    }

    func didStartUpload(id: UUID, context: [String: String]?, client: TUSClient) {
        guard id == activeUploadID else { return }
        markResumeActivity()
        progressHandler(0)
    }

    func didFinishUpload(
        id: UUID,
        url: URL,
        context: [String: String]?,
        client: TUSClient
    ) {
        guard id == activeUploadID else { return }
        markResumeActivity()
        progressHandler(1)
        finish(.success(descriptor.publicURL))
    }

    func uploadFailed(
        id: UUID,
        error: Error,
        context: [String: String]?,
        client: TUSClient
    ) {
        guard id == activeUploadID else { return }
        let uploadError = SupabaseResumableVideoUploadError.fromUploadFailure(
            details: error.localizedDescription
        )
        if uploadError.shouldDiscardResumableState {
            // A 413 cannot succeed on resume. Delete TUSKit's private copy and
            // metadata immediately so every rejected video does not strand
            // another ~47 MB under Application Support.
            _ = try? client.cancelAndDelete(id: id)
            finish(.failure(uploadError))
            return
        }
        if !didManualResume {
            didManualResume = true
            if (try? client.resume(id: id)) == true {
                scheduleResumeWatchdog(for: id)
                return
            }
        }
        finish(.failure(uploadError))
    }

    func fileError(error: TUSClientError, client: TUSClient) {
        // TUSKit can emit a cache-cleanup fileError immediately before its
        // didFinish callback. Treat network failure/synchronous throws and the
        // watchdog as terminal signals instead of reporting a false failure.
        lastFileError = error
    }

    func fileError(id: UUID?, error: TUSClientError, client: TUSClient) {
        guard id == nil || id == activeUploadID else { return }
        lastFileError = error
    }

    func totalProgress(bytesUploaded: Int, totalBytes: Int, client: TUSClient) {}

    func progressFor(
        id: UUID,
        context: [String: String]?,
        bytesUploaded: Int,
        totalBytes: Int,
        client: TUSClient
    ) {
        guard id == activeUploadID else { return }
        markResumeActivity()
        progressHandler(
            SupabaseResumableVideoUploadProgress.fraction(
                bytesUploaded: bytesUploaded,
                totalBytes: totalBytes
            )
        )
    }

    private func markResumeActivity() {
        resumeHadActivity = true
        resumeWatchdog?.cancel()
        resumeWatchdog = nil
    }

    private func scheduleResumeWatchdog(for id: UUID) {
        resumeWatchdog?.cancel()
        resumeHadActivity = false
        let watchdog = DispatchWorkItem { [weak self] in
            self?.restartStalledResume(id: id)
        }
        resumeWatchdog = watchdog
        // A single request may legitimately run for 300 seconds and TUSKit
        // performs two retries. Leave enough time for the complete retry
        // window before treating stored resume metadata as stale.
        DispatchQueue.main.asyncAfter(deadline: .now() + 960, execute: watchdog)
    }

    private func restartStalledResume(id: UUID) {
        guard !isFinished,
              !resumeHadActivity,
              id == activeUploadID,
              let sourceFileURL
        else { return }

        guard !didRestartStalledResume else {
            let details = lastFileError?.localizedDescription
                ?? "Не удалось продолжить сохранённую загрузку."
            finish(.failure(
                SupabaseResumableVideoUploadError.fromUploadFailure(
                    details: details
                )
            ))
            return
        }

        didRestartStalledResume = true
        do {
            _ = try client.cancelAndDelete(id: id)
            progressHandler(0)
            try beginFreshUpload(fileURL: sourceFileURL)
        } catch {
            finish(.failure(
                SupabaseResumableVideoUploadError.fromUploadFailure(
                    details: error.localizedDescription
                )
            ))
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard !isFinished else { return }
        isFinished = true
        resumeWatchdog?.cancel()
        resumeWatchdog = nil
        completion(result)
    }

    private static func storageDirectory(for context: [String: String]) -> URL {
        let identity = "\(context["bucketName"] ?? "videos")/\(context["objectName"] ?? "upload")"
        let hash = identity.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
        return FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("x5-tus", isDirectory: true)
        .appendingPathComponent(String(hash, radix: 16), isDirectory: true)
    }
}
