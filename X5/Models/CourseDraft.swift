import Foundation

/// JSON values that are not yet modeled by the iOS app.
///
/// Keeping them alongside the typed course fields lets the editor change the
/// fields it understands without deleting data produced by the web editor or
/// by a newer app version.
enum CourseJSONValue: Codable, Hashable {
    case string(String)
    case integer(Int)
    case number(Double)
    case bool(Bool)
    case object([String: CourseJSONValue])
    case array([CourseJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: CourseJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([CourseJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported course JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case let .string(value):
            hasher.combine(0)
            hasher.combine(value)
        case let .integer(value):
            hasher.combine(1)
            hasher.combine(value)
        case let .number(value):
            hasher.combine(2)
            hasher.combine(value)
        case let .bool(value):
            hasher.combine(3)
            hasher.combine(value)
        case let .object(value):
            hasher.combine(4)
            for key in value.keys.sorted() {
                hasher.combine(key)
                hasher.combine(value[key])
            }
        case let .array(value):
            hasher.combine(5)
            hasher.combine(value)
        case .null:
            hasher.combine(6)
        }
    }

    var foundationValue: Any {
        switch self {
        case let .string(value): return value
        case let .integer(value): return value
        case let .number(value): return value
        case let .bool(value): return value
        case let .object(value): return value.mapValues(\.foundationValue)
        case let .array(value): return value.map(\.foundationValue)
        case .null: return NSNull()
        }
    }
}

private extension Dictionary where Key == String, Value == CourseJSONValue {
    var courseFoundationPayload: [String: Any] {
        mapValues(\.foundationValue)
    }
}

/// A lossless, editable representation of the nested `courses.categories` JSON.
///
/// Drafts keep server IDs stable and keep uploaded media URLs separate from local
/// replacement files. Selecting a replacement therefore cannot erase the media
/// that is currently saved on the server.
struct CourseDraft: Equatable {
    var categories: [CourseCategoryDraft]

    init(course: Course) {
        categories = course.categories.map { CourseCategoryDraft(category: $0) }
    }

    init(categories: [CourseCategoryDraft]) {
        self.categories = categories
    }

    var categoriesPayload: [[String: Any]] {
        categories
            .sorted { $0.order < $1.order }
            .enumerated()
            .map { offset, category in
                category.payload(order: offset + 1)
            }
    }
}

struct CourseCategoryDraft: Identifiable, Equatable {
    var id: String
    var title: String
    var order: Int
    var icon: String?
    var days: [CourseDayDraft]
    var preservedFields: [String: CourseJSONValue]

    init(
        id: String,
        title: String,
        order: Int,
        icon: String? = nil,
        days: [CourseDayDraft],
        preservedFields: [String: CourseJSONValue] = [:]
    ) {
        self.id = id
        self.title = title
        self.order = order
        self.icon = icon
        self.days = days
        self.preservedFields = preservedFields
    }

    init(category: CourseCategory) {
        id = category.id
        title = category.title
        order = category.order ?? 0
        icon = category.icon
        days = category.days.map { CourseDayDraft(day: $0) }
        preservedFields = category.preservedFields
    }

    var orderedDays: [CourseDayDraft] {
        days.sorted { $0.order < $1.order }
    }

    static func defaultContent() -> CourseCategoryDraft {
        CourseCategoryDraft(
            id: "cat_\(UUID().uuidString)",
            title: "Основной раздел",
            order: 1,
            icon: "folder",
            days: [defaultDay(order: 1)]
        )
    }

    static func defaultDay(order: Int) -> CourseDayDraft {
        CourseDayDraft(
            id: "day_\(UUID().uuidString)",
            title: "День \(order)",
            order: order,
            lessons: []
        )
    }

    func payload(order: Int) -> [String: Any] {
        var result = preservedFields.courseFoundationPayload
        result["id"] = id
        result["title"] = title
        result["order"] = order
        result["days"] = orderedDays.enumerated().map { offset, day in
            day.payload(order: offset + 1)
        }
        if let icon = icon?.courseDraftTrimmed, !icon.isEmpty {
            result["icon"] = icon
        } else {
            result.removeValue(forKey: "icon")
        }
        return result
    }
}

struct CourseDayDraft: Identifiable, Equatable {
    var id: String
    var title: String
    var order: Int
    var lessons: [CourseLessonDraft]
    var preservedFields: [String: CourseJSONValue]

    init(
        id: String,
        title: String,
        order: Int,
        lessons: [CourseLessonDraft],
        preservedFields: [String: CourseJSONValue] = [:]
    ) {
        self.id = id
        self.title = title
        self.order = order
        self.lessons = lessons
        self.preservedFields = preservedFields
    }

    init(day: CourseDay) {
        id = day.id
        title = day.title
        order = day.order ?? 0
        lessons = day.lessons.map { CourseLessonDraft(lesson: $0) }
        preservedFields = day.preservedFields
    }

    var orderedLessons: [CourseLessonDraft] {
        lessons.sorted { $0.order < $1.order }
    }

    func payload(order: Int) -> [String: Any] {
        var result = preservedFields.courseFoundationPayload
        result["id"] = id
        result["title"] = title
        result["order"] = order
        result["lessons"] = orderedLessons.enumerated().map { offset, lesson in
            lesson.payload(order: offset + 1)
        }
        return result
    }
}

struct CourseLessonDraft: Identifiable, Equatable {
    var id: String
    var title: String
    var order: Int
    var price: String
    var savedVideoURL: String
    var youtubeURL: String
    var savedThumbnailURL: String
    var isFreePreview: Bool
    var sellSeparately: Bool
    var pendingVideoFileURL: URL?
    var pendingVideoFileName: String?
    var pendingThumbnailData: Data?
    var preservedFields: [String: CourseJSONValue]

    /// Editing aliases keep URL text fields ergonomic while the saved/pending
    /// distinction remains explicit in the underlying draft model.
    var videoUrl: String {
        get { savedVideoURL }
        set { savedVideoURL = newValue }
    }

    var youtubeUrl: String {
        get { youtubeURL }
        set { youtubeURL = newValue }
    }

    var thumbnailUrl: String {
        get { savedThumbnailURL }
        set { savedThumbnailURL = newValue }
    }

    init(
        id: String,
        title: String,
        order: Int,
        price: String,
        savedVideoURL: String,
        youtubeURL: String,
        savedThumbnailURL: String,
        isFreePreview: Bool,
        sellSeparately: Bool,
        pendingVideoFileURL: URL? = nil,
        pendingVideoFileName: String? = nil,
        pendingThumbnailData: Data? = nil,
        preservedFields: [String: CourseJSONValue] = [:]
    ) {
        self.id = id
        self.title = title
        self.order = order
        self.price = price
        self.savedVideoURL = savedVideoURL
        self.youtubeURL = youtubeURL
        self.savedThumbnailURL = savedThumbnailURL
        self.isFreePreview = isFreePreview
        self.sellSeparately = sellSeparately
        self.pendingVideoFileURL = pendingVideoFileURL
        self.pendingVideoFileName = pendingVideoFileName
        self.pendingThumbnailData = pendingThumbnailData
        self.preservedFields = preservedFields
    }

    init(
        id: String,
        title: String,
        order: Int,
        price: String,
        videoUrl: String,
        youtubeUrl: String,
        thumbnailUrl: String,
        isFreePreview: Bool,
        sellSeparately: Bool,
        pendingVideoFileURL: URL? = nil,
        pendingVideoFileName: String? = nil,
        pendingThumbnailData: Data? = nil,
        preservedFields: [String: CourseJSONValue] = [:]
    ) {
        self.init(
            id: id,
            title: title,
            order: order,
            price: price,
            savedVideoURL: videoUrl,
            youtubeURL: youtubeUrl,
            savedThumbnailURL: thumbnailUrl,
            isFreePreview: isFreePreview,
            sellSeparately: sellSeparately,
            pendingVideoFileURL: pendingVideoFileURL,
            pendingVideoFileName: pendingVideoFileName,
            pendingThumbnailData: pendingThumbnailData,
            preservedFields: preservedFields
        )
    }

    init(lesson: CourseLesson) {
        id = lesson.id
        title = lesson.title
        order = lesson.order ?? 0
        price = String(lesson.price ?? 0)
        savedVideoURL = lesson.videoUrl ?? ""
        youtubeURL = lesson.youtubeUrl ?? ""
        savedThumbnailURL = lesson.thumbnailUrl ?? ""
        isFreePreview = lesson.isFreePreview ?? false
        sellSeparately = lesson.sellSeparately ?? false
        pendingVideoFileURL = nil
        pendingVideoFileName = nil
        pendingThumbnailData = nil
        preservedFields = lesson.preservedFields
    }

    func applyingEditorChanges(
        title: String,
        price: String,
        videoUrl: String,
        youtubeUrl: String,
        thumbnailUrl: String,
        isFreePreview: Bool,
        sellSeparately: Bool,
        pendingVideoFileURL: URL?,
        pendingVideoFileName: String?,
        pendingThumbnailData: Data?
    ) -> CourseLessonDraft {
        var updated = self
        updated.title = title
        updated.price = price
        if !videoUrl.courseDraftTrimmed.isEmpty,
           videoUrl.courseDraftTrimmed != savedVideoURL.courseDraftTrimmed {
            // A manually entered URL replaces a Bunny video.
            updated.clearBunnyVideo()
        }
        updated.videoUrl = videoUrl
        updated.youtubeUrl = youtubeUrl
        updated.thumbnailUrl = thumbnailUrl
        updated.isFreePreview = isFreePreview
        updated.sellSeparately = sellSeparately
        updated.pendingVideoFileURL = pendingVideoFileURL
        updated.pendingVideoFileName = pendingVideoFileName
        updated.pendingThumbnailData = pendingThumbnailData
        return updated
    }

    static func new(order: Int) -> CourseLessonDraft {
        CourseLessonDraft(
            id: "lesson_\(UUID().uuidString)",
            title: "",
            order: order,
            price: "0",
            savedVideoURL: "",
            youtubeURL: "",
            savedThumbnailURL: "",
            isFreePreview: false,
            sellSeparately: false
        )
    }

    var hasVideo: Bool {
        pendingVideoFileURL != nil
            || bunnyVideoID != nil
            || !savedVideoURL.courseDraftTrimmed.isEmpty
            || !youtubeURL.courseDraftTrimmed.isEmpty
    }

    /// Bunny Stream GUID stored in the lesson JSON, if the video lives there.
    var bunnyVideoID: String? {
        CourseLessonBunnyFields.videoID(in: preservedFields)
    }

    var videoLabel: String {
        if let pendingVideoFileName = pendingVideoFileName?.courseDraftTrimmed,
           !pendingVideoFileName.isEmpty {
            return pendingVideoFileName
        }
        if bunnyVideoID != nil {
            switch CourseLessonBunnyFields.status(in: preservedFields) {
            case .ready: return "Видео (HLS 1080p)"
            case .failed: return "Ошибка обработки видео — загрузите заново"
            case .processing, .unknown: return "Видео обрабатывается"
            }
        }
        if !savedVideoURL.courseDraftTrimmed.isEmpty { return "Video URL" }
        if !youtubeURL.courseDraftTrimmed.isEmpty { return "YouTube" }
        return "Видео не задано"
    }

    mutating func stageVideoReplacement(fileURL: URL, fileName: String) {
        pendingVideoFileURL = fileURL
        pendingVideoFileName = fileName
    }

    mutating func markVideoUploadSucceeded(publicURL: String) {
        clearBunnyVideo()
        savedVideoURL = publicURL.courseDraftTrimmed
        pendingVideoFileURL = nil
        pendingVideoFileName = nil
    }

    /// Bunny upload finished: the lesson keeps only the GUID. The public
    /// `videoUrl` is removed so paid lessons never expose a permanent URL.
    mutating func markBunnyVideoUploadSucceeded(videoID: String) {
        preservedFields[CourseLessonBunnyFields.provider] =
            .string(CourseLessonBunnyFields.providerValue)
        preservedFields[CourseLessonBunnyFields.videoID] =
            .string(videoID.lowercased())
        preservedFields[CourseLessonBunnyFields.status] =
            .string(CourseLessonBunnyStatus.processing.rawValue)
        savedVideoURL = ""
        pendingVideoFileURL = nil
        pendingVideoFileName = nil
    }

    mutating func markVideoUploadSucceeded(_ result: CourseLessonVideoUploadResult) {
        switch result {
        case .storageURL(let url):
            markVideoUploadSucceeded(publicURL: url)
        case .bunny(let videoID):
            markBunnyVideoUploadSucceeded(videoID: videoID)
        }
    }

    mutating func clearBunnyVideo() {
        preservedFields.removeValue(forKey: CourseLessonBunnyFields.provider)
        preservedFields.removeValue(forKey: CourseLessonBunnyFields.videoID)
        preservedFields.removeValue(forKey: CourseLessonBunnyFields.status)
    }

    mutating func stageThumbnailReplacement(jpegData: Data) {
        pendingThumbnailData = jpegData
    }

    mutating func markThumbnailUploadSucceeded(publicURL: String) {
        savedThumbnailURL = publicURL.courseDraftTrimmed
        pendingThumbnailData = nil
    }

    func payload(order: Int) -> [String: Any] {
        var result = preservedFields.courseFoundationPayload
        result["id"] = id
        result["title"] = title
        result["order"] = order
        result["price"] = Int(price) ?? 0
        result["isFreePreview"] = isFreePreview
        result["sellSeparately"] = sellSeparately
        // Legacy payloads can still be decoded by CourseLesson, but manual
        // duration is no longer part of the editor or any new save.
        result.removeValue(forKey: "duration")
        if !savedVideoURL.courseDraftTrimmed.isEmpty {
            result["videoUrl"] = savedVideoURL.courseDraftTrimmed
        } else {
            result.removeValue(forKey: "videoUrl")
        }
        if !youtubeURL.courseDraftTrimmed.isEmpty {
            result["youtubeUrl"] = youtubeURL.courseDraftTrimmed
        } else {
            result.removeValue(forKey: "youtubeUrl")
        }
        if !savedThumbnailURL.courseDraftTrimmed.isEmpty {
            result["thumbnailUrl"] = savedThumbnailURL.courseDraftTrimmed
        } else {
            result.removeValue(forKey: "thumbnailUrl")
        }
        return result
    }
}

/// Keeps a newly created hidden course row attached to the editor session so a
/// failed media upload or metadata PATCH can be retried without creating a
/// duplicate row.
struct CourseSaveIdentity: Equatable {
    private(set) var persistedCourseID: String?

    init(existingCourseID: String?) {
        persistedCourseID = existingCourseID
    }

    var requiresCourseCreation: Bool {
        persistedCourseID == nil
    }

    mutating func recordCreatedCourse(id: String) {
        guard persistedCourseID == nil else { return }
        persistedCourseID = id
    }
}

private extension String {
    var courseDraftTrimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
