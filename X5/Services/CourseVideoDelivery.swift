import Foundation

// MARK: - Lesson video source

/// Where a lesson's video lives. Bunny lessons carry only a GUID in the
/// course JSON (`videoProvider: "bunny"`, `bunnyVideoId`); a short-lived
/// signed HLS URL is requested from `course-video-playback` at play time.
/// Older lessons keep a direct `videoUrl` (Supabase mp4/mov, HLS, YouTube).
enum CourseLessonVideoSource: Equatable {
    case bunny(videoID: String, status: CourseLessonBunnyStatus)
    case direct(URL)
    case missing
}

enum CourseLessonBunnyStatus: String, Equatable {
    case processing
    case ready
    case failed
    case unknown
}

enum CourseLessonBunnyFields {
    static let provider = "videoProvider"
    static let videoID = "bunnyVideoId"
    static let status = "videoStatus"
    static let providerValue = "bunny"

    static func videoID(in fields: [String: CourseJSONValue]) -> String? {
        guard case .string(let provider)? = fields[Self.provider],
              provider == providerValue,
              case .string(let raw)? = fields[videoID]
        else {
            return nil
        }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return UUID(uuidString: normalized) == nil ? nil : normalized
    }

    static func status(in fields: [String: CourseJSONValue]) -> CourseLessonBunnyStatus {
        guard case .string(let raw)? = fields[status] else { return .unknown }
        return CourseLessonBunnyStatus(rawValue: raw) ?? .unknown
    }
}

extension CourseLesson {
    var bunnyVideoID: String? {
        CourseLessonBunnyFields.videoID(in: preservedFields)
    }

    var videoSource: CourseLessonVideoSource {
        if let bunnyVideoID {
            return .bunny(
                videoID: bunnyVideoID,
                status: CourseLessonBunnyFields.status(in: preservedFields)
            )
        }
        if let playableURL { return .direct(playableURL) }
        return .missing
    }

    /// True when the lesson has any video the player can try to open.
    var hasAnyVideo: Bool {
        videoSource != .missing
    }
}

// MARK: - Runtime flag

/// Reads `public.app_feature_flags` (anon-readable). Any failure means
/// "disabled", so the old Supabase path stays the default.
enum CourseVideoFeatureFlags {
    static let bunnyUploadKey = "bunny_course_video_upload"

    static func isBunnyUploadEnabled(
        baseURL: URL,
        anonKey: String,
        session: URLSession = .shared
    ) async -> Bool {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("rest/v1/app_feature_flags"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "select", value: "enabled"),
            URLQueryItem(name: "key", value: "eq.\(bunnyUploadKey)"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let url = components?.url else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            return false
        }
        return parseEnabled(data)
    }

    static func parseEnabled(_ data: Data) -> Bool {
        struct Row: Decodable { let enabled: Bool? }
        guard let rows = try? JSONDecoder().decode([Row].self, from: data) else {
            return false
        }
        return rows.first?.enabled == true
    }
}

// MARK: - Upload result

/// What the editor stores after a lesson upload.
enum CourseLessonVideoUploadResult: Equatable {
    /// Legacy path: public Supabase Storage URL saved as `videoUrl`.
    case storageURL(String)
    /// Bunny Stream GUID saved as `bunnyVideoId` (no public URL).
    case bunny(videoID: String)
}

// MARK: - Signed playback

enum CourseVideoPlaybackResult: Equatable {
    case ready(url: URL, expiresAt: Date)
    case processing
    case notEntitled
    case notAuthenticated
    case failed
    case unavailable
}

struct CourseVideoPlaybackClient {
    let baseURL: URL
    let anonKey: String
    var session: URLSession = .shared

    func fetch(
        courseID: String,
        lessonID: String,
        accessToken: String?
    ) async -> CourseVideoPlaybackResult {
        var request = URLRequest(
            url: baseURL.appendingPathComponent(
                "functions/v1/course-video-playback"
            )
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        let bearer = accessToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        request.setValue(
            "Bearer \((bearer?.isEmpty == false ? bearer : nil) ?? anonKey)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "course_id": courseID.lowercased(),
            "lesson_id": lessonID,
        ])

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else {
            return .unavailable
        }
        return Self.parse(statusCode: http.statusCode, data: data)
    }

    static func parse(statusCode: Int, data: Data) -> CourseVideoPlaybackResult {
        switch statusCode {
        case 200:
            struct Body: Decodable {
                let hlsURL: String
                let expiresAt: Double

                enum CodingKeys: String, CodingKey {
                    case hlsURL = "hls_url"
                    case expiresAt = "expires_at"
                }
            }
            guard let body = try? JSONDecoder().decode(Body.self, from: data),
                  let url = URL(string: body.hlsURL),
                  url.scheme?.lowercased() == "https",
                  url.host?.lowercased().hasSuffix(".b-cdn.net") == true,
                  url.path.hasSuffix("/playlist.m3u8")
            else {
                return .unavailable
            }
            return .ready(
                url: url,
                expiresAt: Date(timeIntervalSince1970: body.expiresAt)
            )
        case 202:
            return .processing
        case 401:
            return .notAuthenticated
        case 403:
            return .notEntitled
        case 422:
            return .failed
        default:
            return .unavailable
        }
    }
}
