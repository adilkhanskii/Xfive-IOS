import XCTest
@testable import X5

final class CourseDraftTests: XCTestCase {
    func testApplyingEditorChangesPreservesUnknownLessonFieldsIdentityAndOrder() {
        let original = CourseLessonDraft(
            id: "lesson-lossless",
            title: "Original lesson",
            order: 7,
            price: "25",
            videoUrl: "https://cdn.example.com/original.mp4",
            youtubeUrl: "",
            thumbnailUrl: "https://cdn.example.com/original.jpg",
            isFreePreview: false,
            sellSeparately: false,
            preservedFields: [
                "description": .string("Keep this description"),
                "storagePath": .string("courses/course-lossless/video.mp4")
            ]
        )
        let pendingVideo = URL(fileURLWithPath: "/tmp/replacement.mp4")
        let pendingThumbnail = Data([0x01, 0x02, 0x03])

        let edited = original.applyingEditorChanges(
            title: "Edited lesson",
            price: "50",
            videoUrl: "https://cdn.example.com/edited.mp4",
            youtubeUrl: "https://youtu.be/example",
            thumbnailUrl: "https://cdn.example.com/edited.jpg",
            isFreePreview: true,
            sellSeparately: true,
            pendingVideoFileURL: pendingVideo,
            pendingVideoFileName: "replacement.mp4",
            pendingThumbnailData: pendingThumbnail
        )

        XCTAssertEqual(edited.id, original.id)
        XCTAssertEqual(edited.order, original.order)
        XCTAssertEqual(edited.preservedFields, original.preservedFields)
        XCTAssertEqual(edited.title, "Edited lesson")
        XCTAssertEqual(edited.price, "50")
        XCTAssertEqual(edited.videoUrl, "https://cdn.example.com/edited.mp4")
        XCTAssertEqual(edited.youtubeUrl, "https://youtu.be/example")
        XCTAssertEqual(edited.thumbnailUrl, "https://cdn.example.com/edited.jpg")
        XCTAssertTrue(edited.isFreePreview)
        XCTAssertTrue(edited.sellSeparately)
        XCTAssertEqual(edited.pendingVideoFileURL, pendingVideo)
        XCTAssertEqual(edited.pendingVideoFileName, "replacement.mp4")
        XCTAssertEqual(edited.pendingThumbnailData, pendingThumbnail)

        let payload = edited.payload(order: edited.order)
        XCTAssertEqual(payload["description"] as? String, "Keep this description")
        XCTAssertEqual(payload["storagePath"] as? String, "courses/course-lossless/video.mp4")
        XCTAssertNil(payload["duration"])
    }

    func testLegacyDurationDecodesButDraftPayloadDropsIt() {
        let lesson = makeLesson(id: "legacy-duration", order: 1, videoURL: nil)

        XCTAssertEqual(lesson.duration, "10:00")
        XCTAssertNil(CourseLessonDraft(lesson: lesson).payload(order: 1)["duration"])
    }

    func testDecodedUnknownNestedFieldsSurviveEditingKnownFields() throws {
        let serverJSON = #"""
        {
          "id": "course-lossless",
          "title": "Original course",
          "categories": [
            {
              "id": "module-lossless",
              "title": "Original module",
              "order": 1,
              "layout": "featured",
              "days": [
                {
                  "id": "day-lossless",
                  "title": "Original day",
                  "order": 1,
                  "homework": {
                    "id": "homework-1",
                    "description": "Send a report",
                    "attachments": ["brief.pdf"]
                  },
                  "releaseAt": null,
                  "lessons": [
                    {
                      "id": "lesson-lossless",
                      "title": "Original lesson",
                      "order": 1,
                      "price": 0,
                      "description": "This must not disappear",
                      "storagePath": "courses/course-lossless/video.mp4",
                      "transcript": {
                        "language": "ru",
                        "segments": [{"start": 0, "text": "Intro"}]
                      }
                    }
                  ]
                }
              ]
            }
          ]
        }
        """#
        let course = try JSONDecoder().decode(Course.self, from: Data(serverJSON.utf8))
        var draft = CourseDraft(course: course)

        draft.categories[0].title = "Edited module"
        draft.categories[0].days[0].lessons[0].title = "Edited lesson"

        let payload = draft.categoriesPayload
        let category = try XCTUnwrap(payload.first)
        XCTAssertEqual(category["title"] as? String, "Edited module")
        XCTAssertEqual(category["layout"] as? String, "featured")

        let day = try XCTUnwrap((category["days"] as? [[String: Any]])?.first)
        let homework = try XCTUnwrap(day["homework"] as? [String: Any])
        XCTAssertEqual(homework["description"] as? String, "Send a report")
        XCTAssertEqual(homework["attachments"] as? [String], ["brief.pdf"])
        XCTAssertTrue(day["releaseAt"] is NSNull)

        let lesson = try XCTUnwrap((day["lessons"] as? [[String: Any]])?.first)
        XCTAssertEqual(lesson["title"] as? String, "Edited lesson")
        XCTAssertEqual(lesson["description"] as? String, "This must not disappear")
        XCTAssertEqual(lesson["storagePath"] as? String, "courses/course-lossless/video.mp4")
        let transcript = try XCTUnwrap(lesson["transcript"] as? [String: Any])
        XCTAssertEqual(transcript["language"] as? String, "ru")

        // The resulting payload is still valid JSON and can be decoded again
        // without dropping the fields the current app does not understand.
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let decodedAgain = try JSONDecoder().decode([CourseCategory].self, from: payloadData)
        XCTAssertEqual(decodedAgain[0].preservedFields["layout"], .string("featured"))
        XCTAssertEqual(
            decodedAgain[0].days[0].lessons[0].preservedFields["storagePath"],
            .string("courses/course-lossless/video.mp4")
        )
    }

    func testRoundTripPreservesModulesStableIDsSiblingLessonsAndVideoURL() throws {
        let original = makeCourse()

        let payload = CourseDraft(course: original).categoriesPayload

        XCTAssertEqual(payload.count, 2)
        XCTAssertEqual(payload[0]["id"] as? String, "module-1")
        XCTAssertEqual(payload[1]["id"] as? String, "module-2")

        let firstModuleDays = try XCTUnwrap(payload[0]["days"] as? [[String: Any]])
        XCTAssertEqual(firstModuleDays.first?["id"] as? String, "day-1")

        let siblingLessons = try XCTUnwrap(firstModuleDays.first?["lessons"] as? [[String: Any]])
        XCTAssertEqual(siblingLessons.map { $0["id"] as? String }, ["lesson-1", "lesson-2"])
        XCTAssertEqual(siblingLessons[0]["videoUrl"] as? String, "https://cdn.example.com/lesson-1.mp4")
        XCTAssertEqual(siblingLessons[1]["videoUrl"] as? String, "https://cdn.example.com/lesson-2.mp4")

        let secondModuleDays = try XCTUnwrap(payload[1]["days"] as? [[String: Any]])
        let secondModuleLessons = try XCTUnwrap(secondModuleDays.first?["lessons"] as? [[String: Any]])
        XCTAssertEqual(secondModuleDays.first?["id"] as? String, "day-2")
        XCTAssertEqual(secondModuleLessons.first?["id"] as? String, "lesson-3")
    }

    func testStagedReplacementKeepsSavedVideoUntilUploadSucceeds() {
        var draft = CourseLessonDraft(lesson: makeLesson(
            id: "lesson-1",
            order: 1,
            videoURL: "https://cdn.example.com/original.mp4"
        ))
        let replacement = URL(fileURLWithPath: "/tmp/replacement.mp4")

        draft.stageVideoReplacement(fileURL: replacement, fileName: "replacement.mp4")

        XCTAssertEqual(draft.savedVideoURL, "https://cdn.example.com/original.mp4")
        XCTAssertEqual(draft.pendingVideoFileURL, replacement)
        XCTAssertEqual(draft.payload(order: 1)["videoUrl"] as? String, "https://cdn.example.com/original.mp4")

        draft.markVideoUploadSucceeded(publicURL: "https://cdn.example.com/replacement.mp4")

        XCTAssertEqual(draft.savedVideoURL, "https://cdn.example.com/replacement.mp4")
        XCTAssertNil(draft.pendingVideoFileURL)
        XCTAssertNil(draft.pendingVideoFileName)
        XCTAssertEqual(draft.payload(order: 1)["videoUrl"] as? String, "https://cdn.example.com/replacement.mp4")
    }

    func testSaveIdentityReusesCreatedCourseIDForRetry() {
        var identity = CourseSaveIdentity(existingCourseID: nil)

        XCTAssertTrue(identity.requiresCourseCreation)
        identity.recordCreatedCourse(id: "created-course-id")

        XCTAssertFalse(identity.requiresCourseCreation)
        XCTAssertEqual(identity.persistedCourseID, "created-course-id")

        identity.recordCreatedCourse(id: "duplicate-course-id")
        XCTAssertEqual(identity.persistedCourseID, "created-course-id")
    }

    private func makeCourse() -> Course {
        Course(
            id: "course-1",
            title: "Targeting",
            description: nil,
            marketingHook: nil,
            coverUrl: nil,
            authorName: "DOPAMINE",
            price: 50_000,
            isFree: false,
            isPublic: true,
            courseLanguage: "ru",
            averageRating: nil,
            studentsCount: nil,
            sortOrder: 1,
            categoriesRaw: [
                CourseCategory(
                    id: "module-1",
                    title: "Module 1",
                    order: 1,
                    icon: "folder",
                    days: [CourseDay(
                        id: "day-1",
                        title: "Day 1",
                        order: 1,
                        lessons: [
                            makeLesson(id: "lesson-1", order: 1, videoURL: "https://cdn.example.com/lesson-1.mp4"),
                            makeLesson(id: "lesson-2", order: 2, videoURL: "https://cdn.example.com/lesson-2.mp4")
                        ]
                    )]
                ),
                CourseCategory(
                    id: "module-2",
                    title: "Module 2",
                    order: 2,
                    icon: nil,
                    days: [CourseDay(
                        id: "day-2",
                        title: "Day 2",
                        order: 1,
                        lessons: [makeLesson(id: "lesson-3", order: 1, videoURL: nil)]
                    )]
                )
            ]
        )
    }

    /// Regression 2026-10-07: the editor writes the course structure BEFORE the slow
    /// video upload. A new module whose lesson still has a pending video file must
    /// therefore appear in the payload (without a video URL), not be dropped.
    func testPayloadKeepsNewModuleWhoseLessonVideoIsStillPending() {
        let pending = CourseLessonDraft(
            id: "lesson-new",
            title: "New lesson",
            order: 1,
            price: "0",
            videoUrl: "",
            youtubeUrl: "",
            thumbnailUrl: "",
            isFreePreview: false,
            sellSeparately: false,
            pendingVideoFileURL: URL(fileURLWithPath: "/tmp/new-lesson.mov"),
            pendingVideoFileName: "new-lesson.mov"
        )
        let draft = CourseDraft(categories: [
            CourseCategoryDraft(
                id: "cat-new",
                title: "New module",
                order: 1,
                days: [CourseDayDraft(id: "day-new", title: "Day 1", order: 1, lessons: [pending])]
            )
        ])

        let payload = draft.categoriesPayload

        XCTAssertEqual(payload.count, 1)
        XCTAssertEqual(payload.first?["id"] as? String, "cat-new")
        let days = payload.first?["days"] as? [[String: Any]]
        let lessons = days?.first?["lessons"] as? [[String: Any]]
        XCTAssertEqual(lessons?.count, 1)
        XCTAssertEqual(lessons?.first?["id"] as? String, "lesson-new")
        XCTAssertNil(lessons?.first?["videoUrl"])
    }

    private func makeLesson(id: String, order: Int, videoURL: String?) -> CourseLesson {
        CourseLesson(
            id: id,
            title: "Lesson \(order)",
            duration: "10:00",
            order: order,
            price: 0,
            videoUrl: videoURL,
            youtubeUrl: nil,
            thumbnailUrl: nil,
            isFreePreview: false,
            sellSeparately: false
        )
    }
}
