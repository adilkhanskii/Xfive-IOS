from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class IOSCourseClientUISourceTests(unittest.TestCase):
    def test_native_video_picker_keeps_collection_navigation_inside_picker(self):
        picker = (
            ROOT / "X5" / "Views" / "Helpers" / "GalleryVideoPicker.swift"
        ).read_text(encoding="utf-8")
        editor = (ROOT / "X5" / "Views" / "CourseEditorView.swift").read_text(
            encoding="utf-8"
        )

        self.assertIn("PHPickerViewController", picker)
        self.assertIn("PHPickerConfiguration(photoLibrary: .shared())", picker)
        self.assertIn("configuration.filter = .videos", picker)
        self.assertIn("didFinishPicking results", picker)
        self.assertIn("CourseVideoStaging.stage(", picker)
        self.assertIn("temporary URL for the lifetime", picker)
        self.assertIn("GalleryVideoPicker(", editor)
        self.assertNotIn("PhotosPicker(selection: $videoItem, matching: .videos)", editor)

    def test_lesson_cover_gallery_is_presented_from_one_place(self):
        # Сборка 246: в одной строке Form стояли два PhotosPicker обложки урока,
        # тап по строке открывал оба → галерея «вылетала» и открывалась снова.
        editor = (ROOT / "X5" / "Views" / "CourseEditorView.swift").read_text(
            encoding="utf-8"
        )

        self.assertNotIn("PhotosPicker(selection: $thumbnailItem", editor)
        self.assertEqual(
            editor.count(
                ".photosPicker(isPresented: $showingThumbnailPicker, selection: $thumbnailItem"
            ),
            1,
        )
        # Обложка курса — тот же приём: без PhotosPicker внутри строки Form.
        self.assertNotIn("PhotosPicker(selection: $coverItem", editor)
        self.assertEqual(
            editor.count(".photosPicker(isPresented: $showingCoverPicker, selection: $coverItem"),
            1,
        )

    def test_module_row_tap_cannot_delete_module(self):
        # Гарантийный баг «модули удаляются» (сборка 246): весь модуль — одна
        # строка Form, и кнопки со стилем по умолчанию срабатывали ВСЕ от одного
        # тапа: «Добавить урок» + «Добавить день» + «Удалить модуль».
        editor = (ROOT / "X5" / "Views" / "CourseEditorView.swift").read_text(
            encoding="utf-8"
        )
        start = editor.index("private var lessonsSection: some View")
        end = editor.index("private func populate()", start)
        section = editor[start:end]

        for label in (
            'Label("Добавить урок"',
            'Label("Добавить день / блок"',
            'Label("Удалить модуль"',
        ):
            at = section.index(label)
            tail = section[at:]
            next_button = tail.find("Button", 1)
            style = tail.find(".buttonStyle(.borderless)")
            self.assertNotEqual(style, -1, label)
            if next_button != -1:
                self.assertLess(style, next_button, f"{label} без .borderless")

        # Кнопка в строке только ставит вопрос; удаляет — подтверждение.
        delete_at = section.index('Label("Удалить модуль"')
        delete_button = section[section.rindex("Button(role: .destructive)", 0, delete_at):delete_at]
        self.assertIn("pendingCategoryDeleteId = categories[categoryIndex].id", delete_button)
        self.assertNotIn("deleteCategory(", delete_button)
        self.assertIn('"Удалить модуль?"', editor)
        self.assertIn("deleteCategory(index)", editor)

    def test_viewer_lesson_cover_does_not_steal_module_header_taps(self):
        # Сборка 246: обложка 16:9 (scaledToFill) невидимо вылезала за рамку на
        # кнопку модуля, и тап «свернуть модуль» открывал урок.
        courses = (ROOT / "X5" / "Views" / "CoursesView.swift").read_text(
            encoding="utf-8"
        )
        start = courses.index("private var coverCard: some View")
        end = courses.index("private var coverPlaceholder: some View", start)
        card = courses[start:end]
        self.assertIn(".allowsHitTesting(false)", card)
        self.assertIn(".contentShape(RoundedRectangle(cornerRadius: 9", card)

    def test_picked_course_covers_are_downscaled_once(self):
        # «Жестко тупит»: полное фото с камеры декодировалось в body на каждую
        # перерисовку. Теперь обложка ужимается один раз сразу после выбора.
        editor = (ROOT / "X5" / "Views" / "CourseEditorView.swift").read_text(
            encoding="utf-8"
        )
        self.assertNotIn("UIImage(data: data)", editor.split("struct LessonEditorSheet")[0])
        self.assertNotIn("let img = UIImage(data:", editor)
        # 09.10: обложка курса и урока грузятся общим PickedPhotoLoader, который
        # сам ужимает фото через CourseCoverImage.prepare.
        loader = (ROOT / "X5" / "Views" / "Helpers" / "PickedPhotoLoader.swift").read_text(
            encoding="utf-8"
        )
        self.assertGreaterEqual(editor.count("CourseCoverImage.prepare("), 1)
        self.assertGreaterEqual(editor.count("PickedPhotoLoader.loadPrepared(from: item)"), 2)
        self.assertIn("CourseCoverImage.prepare(data, maxPixelSize: maxPixelSize)", loader)

    def test_picked_photos_never_fail_silently_and_can_be_picked_again(self):
        # 09.10 (Адильхан): «выбрал фото → Загрузка... → не прикрепилось» в
        # генераторе обложек и в CourseUP. Ошибка видна, выбор сбрасывается.
        editor = (ROOT / "X5" / "Views" / "CourseEditorView.swift").read_text(
            encoding="utf-8"
        )
        generator = (ROOT / "X5" / "Views" / "Home" / "ImageGeneratorView.swift").read_text(
            encoding="utf-8"
        )
        loader = (ROOT / "X5" / "Views" / "Helpers" / "PickedPhotoLoader.swift").read_text(
            encoding="utf-8"
        )
        for source in (editor, generator):
            self.assertNotIn("try? await item.loadTransferable(type: Data.self)", source)
        self.assertIn("loadTransferable(type: PickedImageFile.self)", loader)
        self.assertIn("FileRepresentation(contentType: .image)", loader)
        self.assertIn("coverPickError = PickedPhotoLoader.errorText", editor)
        self.assertIn("if coverItem == item { coverItem = nil }", editor)
        self.assertIn("if thumbnailItem == item { thumbnailItem = nil }", editor)
        self.assertIn("photoLoadError = PickedPhotoLoader.errorText", generator)
        self.assertIn("mainPhotoItem = nil", generator)
        self.assertIn("isLoading: isLoadingMainPhoto", generator)

    def test_courseup_header_and_every_real_course_have_developer_editor_action(self):
        courses = (ROOT / "X5" / "Views" / "CoursesView.swift").read_text(
            encoding="utf-8"
        )
        roles = (ROOT / "X5" / "Services" / "Roles.swift").read_text(
            encoding="utf-8"
        )

        self.assertIn('Text("CourseUP")', courses)
        self.assertNotIn('Text("Академия")', courses)
        # The catalog now contains only server courses. The former membership
        # guard separated synthetic upcoming cards; retain developer-only edit
        # buttons/context menus on both real card paths without requiring fakes.
        self.assertIn("Array(service.courses.dropFirst()) }", courses)
        self.assertNotIn("Self.upcomingCourses", courses)
        featured = courses.split("if let course = featuredCourse {")[1].split("ForEach(Array(academyCourses")[0]
        academy = courses.split("ForEach(Array(academyCourses")[1].split(".padding(.horizontal, 16)")[0]
        for cards in (featured, academy):
            self.assertIn("if isDev {", cards)
            # 09.10: drag-to-reorder removed from the catalog (Adilkhan: laggy);
            # order changes only in the ↑↓ sheet; edit stays on the pencil.
            self.assertEqual(cards.count("editorTarget = .edit(course)"), 1)
            self.assertNotIn("dragReorder", cards)
            self.assertNotIn(".onDrag", cards)
            self.assertNotIn(".contextMenu", cards)
            self.assertIn("CourseDetailView(course: course", cards)
            self.assertNotIn("CourseInDevelopmentView", cards)
        self.assertEqual(roles.count('"f3eea23f-0aeb-405b-ab35-2c53173b7a8f"'), 1)
        self.assertEqual(roles.count('"eee55a08-18d1-46e3-a303-1411d1bb9333"'), 1)


if __name__ == "__main__":
    unittest.main()
