import Foundation
import TUSKit

// Bunny Stream lesson upload (original file, resumable TUS). Enabled at
// runtime by public.app_feature_flags key "bunny_course_video_upload"
// (see CourseVideoFeatureFlags); the server enforces the same flag. The
// Bunny API key never reaches the app: create-course-video-upload returns a
// short-lived TUS signature only. Playback goes through
// course-video-playback (entitlement-checked, token-signed HLS).

enum BunnyStreamUploadKey {
    /// Stable per (course, lesson, file) so a retry after a crash or network
    /// loss resumes the same Bunny video instead of creating a new one.
    static func scoped(
        courseID: String,
        lessonID: String,
        uploadIdentity: String
    ) -> String {
        let identity =
            "lesson_video|\(courseID.lowercased())|\(lessonID)|\(uploadIdentity)"
        let hash = identity.utf8.reduce(
            UInt64(14_695_981_039_346_656_037)
        ) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
        return "lv_" + String(format: "%016llx", hash)
    }
}

enum BunnyStreamVideoUploadError: Error, Equatable, LocalizedError {
    case invalidFile
    case missingAccessToken
    case notAuthorized
    case serviceUnavailable
    case invalidTicket
    case uploadFailed
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .invalidFile:
            return "Не удалось прочитать выбранное видео."
        case .missingAccessToken:
            return "Сессия истекла. Войдите снова и повторите загрузку."
        case .notAuthorized:
            return "У этого аккаунта нет доступа к загрузке уроков."
        case .serviceUnavailable:
            return "Видео-хранилище временно недоступно. Попробуйте позже."
        case .invalidTicket:
            return "Сервер вернул неверные параметры загрузки видео."
        case .uploadFailed:
            return "Загрузка видео не завершилась. Можно повторить без повторного выбора файла."
        case .rateLimited:
            return "Слишком много загрузок подряд. Подождите минуту и повторите."
        }
    }
}

struct BunnyStreamUploadTicket: Decodable, Equatable {
    let tusEndpoint: URL
    let videoID: String
    let libraryID: String
    let authorizationSignature: String
    let authorizationExpire: Int

    enum CodingKeys: String, CodingKey {
        case tusEndpoint = "tus_endpoint"
        case videoID = "video_id"
        case libraryID = "library_id"
        case authorizationSignature = "authorization_signature"
        case authorizationExpire = "authorization_expire"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let endpoint = try container.decode(URL.self, forKey: .tusEndpoint)
        let rawVideoID = try container.decode(String.self, forKey: .videoID)
        let rawLibraryID = try container.decode(String.self, forKey: .libraryID)
        let signature = try container.decode(
            String.self,
            forKey: .authorizationSignature
        )
        let expire = try container.decode(
            Int.self,
            forKey: .authorizationExpire
        )

        let normalizedVideoID = rawVideoID.lowercased()
        let decimal = CharacterSet(charactersIn: "0123456789")
        let hexadecimal = CharacterSet(
            charactersIn: "0123456789abcdefABCDEF"
        )
        guard endpoint.scheme?.lowercased() == "https",
              endpoint.host?.lowercased() == "video.bunnycdn.com",
              endpoint.path == "/tusupload",
              endpoint.query == nil,
              endpoint.fragment == nil,
              UUID(uuidString: normalizedVideoID) != nil,
              !rawLibraryID.isEmpty,
              rawLibraryID.unicodeScalars.allSatisfy({
                  decimal.contains($0)
              }),
              signature.count == 64,
              signature.unicodeScalars.allSatisfy({
                  hexadecimal.contains($0)
              }),
              expire > 0
        else {
            throw BunnyStreamVideoUploadError.invalidTicket
        }

        tusEndpoint = endpoint
        videoID = normalizedVideoID
        libraryID = rawLibraryID
        authorizationSignature = signature.lowercased()
        authorizationExpire = expire
    }

    var transientHeaders: [String: String] {
        [
            "AuthorizationSignature": authorizationSignature,
            "AuthorizationExpire": String(authorizationExpire),
            "LibraryId": libraryID,
            "VideoId": videoID,
        ]
    }

    func expires(within seconds: TimeInterval, now: Date = Date()) -> Bool {
        TimeInterval(authorizationExpire) <= now.timeIntervalSince1970 + seconds
    }
}

/// Server answer: either a TUS ticket, or "bytes already arrived" for a
/// replayed upload key whose video is already processing / ready at Bunny.
enum BunnyStreamTicketResponse: Equatable {
    case upload(BunnyStreamUploadTicket)
    case alreadyUploaded(videoID: String)

    var videoID: String {
        switch self {
        case .upload(let ticket): return ticket.videoID
        case .alreadyUploaded(let videoID): return videoID
        }
    }

    static func decode(_ data: Data) throws -> BunnyStreamTicketResponse {
        struct Probe: Decodable {
            let videoID: String
            let uploadRequired: Bool?

            enum CodingKeys: String, CodingKey {
                case videoID = "video_id"
                case uploadRequired = "upload_required"
            }
        }
        let probe = try JSONDecoder().decode(Probe.self, from: data)
        if probe.uploadRequired == false {
            let videoID = probe.videoID.lowercased()
            guard UUID(uuidString: videoID) != nil else {
                throw BunnyStreamVideoUploadError.invalidTicket
            }
            return .alreadyUploaded(videoID: videoID)
        }
        return .upload(
            try JSONDecoder().decode(BunnyStreamUploadTicket.self, from: data)
        )
    }
}

private struct BunnyStreamTicketRequest: Encodable {
    let courseID: String
    let lessonID: String
    let uploadKey: String
    let title: String
    let fileName: String
    let contentType: String
    let sourceBytes: Int64

    enum CodingKeys: String, CodingKey {
        case courseID = "course_id"
        case lessonID = "lesson_id"
        case uploadKey = "upload_key"
        case title
        case fileName = "file_name"
        case contentType = "content_type"
        case sourceBytes = "source_bytes"
    }
}

enum BunnyStreamTicketRetryPolicy {
    static let maxInProgressRetries = 3
    private static let defaultDelaySeconds: UInt64 = 3
    private static let maximumDelaySeconds: UInt64 = 5

    static func delaySeconds(retryAfter: String?) -> UInt64 {
        guard let retryAfter,
              let parsed = Double(
                retryAfter.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
              ),
              parsed.isFinite
        else {
            return defaultDelaySeconds
        }
        let bounded = min(
            Double(maximumDelaySeconds),
            max(1, parsed.rounded(.up))
        )
        return UInt64(bounded)
    }
}

final class BunnyStreamUploadTicketClient {
    typealias Sleeper = (UInt64) async throws -> Void

    private let baseURL: URL
    private let anonKey: String
    private let session: URLSession
    private let sleeper: Sleeper

    init(
        baseURL: URL,
        anonKey: String,
        session: URLSession = .shared,
        sleeper: @escaping Sleeper = { seconds in
            try await Task.sleep(
                nanoseconds: seconds * 1_000_000_000
            )
        }
    ) {
        self.baseURL = baseURL
        self.anonKey = anonKey
        self.session = session
        self.sleeper = sleeper
    }

    func createTicket(
        courseID: String,
        lessonID: String,
        uploadKey: String,
        title: String,
        fileName: String,
        contentType: String,
        sourceBytes: Int64,
        accessToken: String
    ) async throws -> BunnyStreamTicketResponse {
        let token = accessToken.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !token.isEmpty else {
            throw BunnyStreamVideoUploadError.missingAccessToken
        }

        let url = baseURL.appendingPathComponent(
            "functions/v1/create-course-video-upload"
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue(
            "Bearer \(token)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = try JSONEncoder().encode(
            BunnyStreamTicketRequest(
                courseID: courseID.lowercased(),
                lessonID: lessonID,
                uploadKey: uploadKey,
                title: title,
                fileName: fileName,
                contentType: contentType,
                sourceBytes: sourceBytes
            )
        )

        for attempt in 0...BunnyStreamTicketRetryPolicy.maxInProgressRetries {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw BunnyStreamVideoUploadError.serviceUnavailable
            }
            guard let http = response as? HTTPURLResponse else {
                throw BunnyStreamVideoUploadError.serviceUnavailable
            }
            switch http.statusCode {
            case 200..<300:
                do {
                    return try BunnyStreamTicketResponse.decode(data)
                } catch {
                    throw BunnyStreamVideoUploadError.invalidTicket
                }
            case 401:
                throw BunnyStreamVideoUploadError.missingAccessToken
            case 403:
                throw BunnyStreamVideoUploadError.notAuthorized
            case 429:
                throw BunnyStreamVideoUploadError.rateLimited
            case 425
                where attempt <
                    BunnyStreamTicketRetryPolicy.maxInProgressRetries:
                try await sleeper(
                    BunnyStreamTicketRetryPolicy.delaySeconds(
                        retryAfter: http.value(
                            forHTTPHeaderField: "Retry-After"
                        )
                    )
                )
            case 500...599:
                throw BunnyStreamVideoUploadError.serviceUnavailable
            default:
                throw BunnyStreamVideoUploadError.uploadFailed
            }
        }
        throw BunnyStreamVideoUploadError.uploadFailed
    }
}

struct BunnyStreamUploadStateStore {
    private let defaults: UserDefaults
    private let prefix = "x5.bunny-course-upload."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func videoID(for uploadIdentity: String) -> String? {
        guard let value = defaults.string(
            forKey: key(for: uploadIdentity)
        )?.lowercased(),
              UUID(uuidString: value) != nil
        else {
            return nil
        }
        return value
    }

    func save(videoID: String, for uploadIdentity: String) {
        guard UUID(uuidString: videoID) != nil else { return }
        defaults.set(videoID.lowercased(), forKey: key(for: uploadIdentity))
    }

    func clear(for uploadIdentity: String) {
        defaults.removeObject(forKey: key(for: uploadIdentity))
    }

    private func key(for uploadIdentity: String) -> String {
        let hash = uploadIdentity.utf8.reduce(
            UInt64(14_695_981_039_346_656_037)
        ) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
        return prefix + String(hash, radix: 16)
    }
}

struct BunnyStreamTUSUploadDescriptor {
    static let requiredChunkSize = 6 * 1024 * 1024

    let endpoint: URL
    let chunkSize: Int
    let context: [String: String]
    let persistentHeaders: [String: String]
    let uploadIdentity: String
    let videoID: String

    init(
        ticket: BunnyStreamUploadTicket,
        uploadIdentity: String,
        title: String,
        fileName: String,
        contentType: String
    ) throws {
        let normalizedIdentity = uploadIdentity.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let normalizedTitle = title.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let normalizedFileName = fileName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let normalizedContentType = contentType.lowercased()
        guard !normalizedIdentity.isEmpty,
              !normalizedTitle.isEmpty,
              !normalizedFileName.isEmpty,
              normalizedContentType.hasPrefix("video/")
        else {
            throw BunnyStreamVideoUploadError.invalidFile
        }

        endpoint = ticket.tusEndpoint
        chunkSize = Self.requiredChunkSize
        context = [
            "filetype": normalizedContentType,
            "title": normalizedTitle,
            "filename": normalizedFileName,
            "videoId": ticket.videoID,
        ]
        persistentHeaders = [:]
        self.uploadIdentity = normalizedIdentity
        videoID = ticket.videoID
    }
}

enum BunnyStreamTUSSessionConfiguration {
    static func make() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.waitsForConnectivity = true
        return configuration
    }
}

final class BunnyStreamResumableVideoUploader {
    typealias ProgressHandler = (Double) -> Void
    typealias AccessTokenProvider = () async -> String?

    private let ticketClient: BunnyStreamUploadTicketClient
    private let stateStore: BunnyStreamUploadStateStore
    private let lock = NSLock()
    private var activeSessions: [UUID: BunnyStreamUploadSession] = [:]

    init(
        baseURL: URL,
        anonKey: String,
        stateStore: BunnyStreamUploadStateStore =
            BunnyStreamUploadStateStore()
    ) {
        ticketClient = BunnyStreamUploadTicketClient(
            baseURL: baseURL,
            anonKey: anonKey
        )
        self.stateStore = stateStore
    }

    /// Uploads the original file and returns the Bunny video GUID. The
    /// lesson stores that GUID (videoProvider = "bunny"); it is not a
    /// playable URL by itself.
    func upload(
        sourceFileURL: URL,
        uploadIdentity: String,
        courseID: String,
        lessonID: String,
        title: String,
        contentType: String,
        accessToken: String,
        accessTokenProvider: AccessTokenProvider? = nil,
        progress: @escaping ProgressHandler
    ) async throws -> String {
        guard let sourceBytes = try sourceFileURL.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize,
              sourceBytes > 0
        else {
            throw BunnyStreamVideoUploadError.invalidFile
        }
        let initialToken = try Self.normalizedAccessToken(accessToken)
        let resolvedTokenProvider = accessTokenProvider ?? { initialToken }
        let fileName = sourceFileURL.lastPathComponent.isEmpty
            ? "course-video.mp4"
            : sourceFileURL.lastPathComponent
        let scopedUploadKey = BunnyStreamUploadKey.scoped(
            courseID: courseID,
            lessonID: lessonID,
            uploadIdentity: uploadIdentity
        )

        let responseProvider: () async throws -> BunnyStreamTicketResponse = {
            [ticketClient] in
            let candidate = await resolvedTokenProvider()
            let token = (try? Self.normalizedAccessToken(candidate ?? ""))
                ?? initialToken
            return try await ticketClient.createTicket(
                courseID: courseID,
                lessonID: lessonID,
                uploadKey: scopedUploadKey,
                title: title,
                fileName: fileName,
                contentType: contentType,
                sourceBytes: Int64(sourceBytes),
                accessToken: token
            )
        }
        let ticketProvider: () async throws -> BunnyStreamUploadTicket = {
            switch try await responseProvider() {
            case .upload(let ticket):
                return ticket
            case .alreadyUploaded:
                // Bunny already has every byte; the running TUS session will
                // finish on its own HEAD/PATCH round trip.
                throw BunnyStreamVideoUploadError.uploadFailed
            }
        }

        let ticket: BunnyStreamUploadTicket
        switch try await responseProvider() {
        case .alreadyUploaded(let videoID):
            stateStore.clear(for: scopedUploadKey)
            progress(1)
            return videoID
        case .upload(let fresh):
            ticket = fresh
        }
        stateStore.save(videoID: ticket.videoID, for: scopedUploadKey)
        let descriptor = try BunnyStreamTUSUploadDescriptor(
            ticket: ticket,
            uploadIdentity: scopedUploadKey,
            title: title,
            fileName: fileName,
            contentType: contentType
        )
        let vault = BunnyStreamTicketVault(
            initialTicket: ticket,
            refresh: {
                try await ticketProvider()
            }
        )

        let sessionKey = UUID()
        let videoID = ticket.videoID
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            do {
                let session = try BunnyStreamUploadSession(
                    descriptor: descriptor,
                    ticketVault: vault,
                    progress: progress
                ) { [weak self] result in
                    if case .success = result {
                        self?.stateStore.clear(for: scopedUploadKey)
                    }
                    self?.removeSession(sessionKey)
                    continuation.resume(with: result)
                }
                retainSession(session, key: sessionKey)
                try session.start(sourceFileURL: sourceFileURL)
            } catch {
                removeSession(sessionKey)
                continuation.resume(throwing: error)
            }
        }
        return videoID
    }

    private static func normalizedAccessToken(
        _ value: String
    ) throws -> String {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw BunnyStreamVideoUploadError.missingAccessToken
        }
        return token
    }

    private func retainSession(
        _ session: BunnyStreamUploadSession,
        key: UUID
    ) {
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

private actor BunnyStreamTicketVault {
    private var ticket: BunnyStreamUploadTicket
    private let refresh: () async throws -> BunnyStreamUploadTicket

    init(
        initialTicket: BunnyStreamUploadTicket,
        refresh: @escaping () async throws -> BunnyStreamUploadTicket
    ) {
        ticket = initialTicket
        self.refresh = refresh
    }

    func headers(forceRefresh: Bool = false) async throws -> [String: String] {
        if forceRefresh || ticket.expires(within: 15 * 60) {
            let refreshed = try await refresh()
            guard refreshed.videoID == ticket.videoID else {
                throw BunnyStreamVideoUploadError.invalidTicket
            }
            ticket = refreshed
        }
        return ticket.transientHeaders
    }
}

private final class BunnyStreamUploadSession:
    NSObject,
    TUSClientDelegate
{
    private let descriptor: BunnyStreamTUSUploadDescriptor
    private let ticketVault: BunnyStreamTicketVault
    private let progressHandler:
        BunnyStreamResumableVideoUploader.ProgressHandler
    private let completion: (Result<Void, Error>) -> Void
    private let client: TUSClient
    private var activeUploadID: UUID?
    private var sourceFileURL: URL?
    private var isFinished = false
    private var didManualResume = false
    private var didRestartStalledResume = false
    private var resumeHadActivity = false
    private var resumeWatchdog: DispatchWorkItem?

    init(
        descriptor: BunnyStreamTUSUploadDescriptor,
        ticketVault: BunnyStreamTicketVault,
        progress: @escaping
            BunnyStreamResumableVideoUploader.ProgressHandler,
        completion: @escaping (Result<Void, Error>) -> Void
    ) throws {
        self.descriptor = descriptor
        self.ticketVault = ticketVault
        progressHandler = progress
        self.completion = completion

        let configuration = BunnyStreamTUSSessionConfiguration.make()
        client = try TUSClient(
            server: descriptor.endpoint,
            storageDirectory: Self.storageDirectory(
                for: descriptor.uploadIdentity
            ),
            session: URLSession(configuration: configuration),
            chunkSize: descriptor.chunkSize,
            supportedExtensions: [.creation],
            reportingQueue: .main,
            generateHeaders: {
                [ticketVault] _, persistentHeaders, completeHeaders in
                Task {
                    let ticketHeaders =
                        (try? await ticketVault.headers()) ?? [:]
                    completeHeaders(
                        persistentHeaders.merging(ticketHeaders) {
                            _, refreshed in refreshed
                        }
                    )
                }
            },
            persistGeneratedHeaders: false
        )
        super.init()
        client.delegate = self
    }

    func start(sourceFileURL: URL) throws {
        self.sourceFileURL = sourceFileURL
        let storedUploads = client.start()
        if let stored = storedUploads.first(where: {
            $0.1?["videoId"] == descriptor.videoID
        }) {
            activeUploadID = stored.0
            scheduleResumeWatchdog(for: stored.0)
            return
        }
        for stored in storedUploads {
            _ = try? client.cancelAndDelete(id: stored.0)
        }
        try beginFreshUpload(sourceFileURL: sourceFileURL)
    }

    private func beginFreshUpload(sourceFileURL: URL) throws {
        resumeWatchdog?.cancel()
        resumeWatchdog = nil
        resumeHadActivity = false
        activeUploadID = try client.uploadFileAt(
            filePath: sourceFileURL,
            customHeaders: descriptor.persistentHeaders,
            context: descriptor.context
        )
    }

    func didStartUpload(
        id: UUID,
        context: [String: String]?,
        client: TUSClient
    ) {
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
        finish(.success(()))
    }

    func uploadFailed(
        id: UUID,
        error: Error,
        context: [String: String]?,
        client: TUSClient
    ) {
        guard id == activeUploadID else { return }
        guard !didManualResume else {
            finish(.failure(BunnyStreamVideoUploadError.uploadFailed))
            return
        }
        didManualResume = true
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await ticketVault.headers(forceRefresh: true)
                DispatchQueue.main.async { [weak self] in
                    self?.resumeAfterRefreshingTicket(id: id)
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.finish(
                        .failure(
                            error as? BunnyStreamVideoUploadError
                                ?? .serviceUnavailable
                        )
                    )
                }
            }
        }
    }

    private func resumeAfterRefreshingTicket(id: UUID) {
        guard !isFinished, id == activeUploadID else { return }
        if (try? client.resume(id: id)) == true {
            scheduleResumeWatchdog(for: id)
        } else {
            finish(.failure(BunnyStreamVideoUploadError.uploadFailed))
        }
    }

    func fileError(error: TUSClientError, client: TUSClient) {}

    func fileError(
        id: UUID?,
        error: TUSClientError,
        client: TUSClient
    ) {}

    func totalProgress(
        bytesUploaded: Int,
        totalBytes: Int,
        client: TUSClient
    ) {}

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
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 960,
            execute: watchdog
        )
    }

    private func restartStalledResume(id: UUID) {
        guard !isFinished,
              !resumeHadActivity,
              id == activeUploadID,
              let sourceFileURL
        else {
            return
        }

        guard !didRestartStalledResume else {
            finish(.failure(BunnyStreamVideoUploadError.uploadFailed))
            return
        }
        didRestartStalledResume = true
        do {
            _ = try client.cancelAndDelete(id: id)
            progressHandler(0)
            try beginFreshUpload(sourceFileURL: sourceFileURL)
        } catch {
            finish(.failure(BunnyStreamVideoUploadError.uploadFailed))
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard !isFinished else { return }
        isFinished = true
        resumeWatchdog?.cancel()
        resumeWatchdog = nil
        completion(result)
    }

    private static func storageDirectory(
        for uploadIdentity: String
    ) -> URL {
        let hash = uploadIdentity.utf8.reduce(
            UInt64(14_695_981_039_346_656_037)
        ) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
        return FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("x5-bunny-tus", isDirectory: true)
        .appendingPathComponent(String(hash, radix: 16), isDirectory: true)
    }
}
