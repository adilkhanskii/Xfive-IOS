import SwiftUI
import PhotosUI

private typealias EditableCategory = CourseCategoryDraft
private typealias EditableDay = CourseDayDraft
private typealias EditableLesson = CourseLessonDraft

private enum CourseSaveStage: Equatable {
    case idle
    case preparing
    case creatingCourse
    case uploadingCover
    case uploadingVideo(current: Int, total: Int)
    case uploadingLessonCover(current: Int, total: Int)
    case savingCourse
    case completed
    case failed(String)

    var message: String? {
        switch self {
        case .idle:
            return nil
        case .preparing:
            return "Подготовка к сохранению…"
        case .creatingCourse:
            return "Создание черновика курса…"
        case .uploadingCover:
            return "Загрузка обложки курса…"
        case let .uploadingVideo(current, total):
            return "Загрузка видео \(current) из \(total)…"
        case let .uploadingLessonCover(current, total):
            return "Загрузка обложки урока \(current) из \(total)…"
        case .savingCourse:
            return "Сохранение курса…"
        case .completed:
            return "Готово"
        case let .failed(message):
            return message
        }
    }

    var isProgress: Bool {
        switch self {
        case .preparing, .creatingCourse, .uploadingCover, .uploadingVideo,
             .uploadingLessonCover, .savingCourse:
            return true
        default:
            return false
        }
    }
}

/// Developer-only course editor. Handles course metadata, cover image, and lessons
/// stored inside `courses.categories` JSON.
struct CourseEditorView: View {
    @EnvironmentObject private var auth: Auth
    @EnvironmentObject private var currentUser: CurrentUser
    @Environment(\.dismiss) private var dismiss
    @StateObject private var service = CoursesService()

    /// Pass an existing course to edit it. Pass nil to create a new one.
    let editing: Course?
    var onChange: () -> Void

    @State private var title: String = ""
    @State private var description: String = ""
    @State private var marketingHook: String = ""
    @State private var price: String = "0"
    @State private var isPublic: Bool = false
    @State private var courseLanguage: String = "ru"
    @State private var authorName: String = ""
    @State private var selectedAuthorId: String?
    @State private var availableAuthors: [UserProfile] = []
    @State private var authorPickerPresented = false
    @State private var loadingAuthors = false
    @State private var authorLoadError: String?
    @State private var coverUrl: String?
    @State private var categories: [EditableCategory] = [.defaultContent()]

    @State private var coverItem: PhotosPickerItem?
    @State private var coverPreviewData: Data?
    // Готовая картинка для показа: раньше UIImage(data:) декодировал полное
    // фото с камеры при КАЖДОЙ перерисовке формы → редактор «жестко тупил».
    @State private var coverPreviewImage: UIImage?
    // Галерея обложки курса — один флаг и один .photosPicker на весь экран
    // (а не PhotosPicker внутри строки Form, который «моргал» и открывался заново).
    @State private var showingCoverPicker = false
    @State private var uploadingCover = false
    /// Фото из галереи читается (из iCloud бывает долго) — показываем спиннер.
    @State private var loadingCoverPreview = false
    @State private var coverPickError: String?
    /// Модуль, который ждёт подтверждения удаления (id, а не индекс: индексы
    /// сдвигаются, пока открыт диалог).
    @State private var pendingCategoryDeleteId: String?

    @State private var lessonEditor: LessonEditorTarget?
    @State private var didPopulate = false
    @State private var saving = false
    @State private var deleteConfirm = false
    @State private var errorText: String?
    @State private var saveIdentity: CourseSaveIdentity
    /// True once modules/lessons were written to the server by a checkpoint.
    /// From then on "Cancel" must not delete the course draft.
    @State private var structureCheckpointed = false
    @State private var saveStage: CourseSaveStage = .idle

    private var isCreating: Bool { saveIdentity.persistedCourseID == nil }
    private var existingId: String? { saveIdentity.persistedCourseID }

    init(editing: Course?, onChange: @escaping () -> Void) {
        self.editing = editing
        self.onChange = onChange
        _saveIdentity = State(initialValue: CourseSaveIdentity(existingCourseID: editing?.id))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    coverPicker
                    if let coverPickError {
                        Text(coverPickError)
                            .font(.footnote)
                            .foregroundColor(.red)
                    }
                }

                Section("Основное") {
                    TextField("Название курса", text: $title)
                        .textInputAutocapitalization(.sentences)
                    TextField("Подзаголовок", text: $marketingHook)
                    Button {
                        authorPickerPresented = true
                        Task { await loadCourseAuthors() }
                    } label: {
                        HStack(spacing: 12) {
                            Label("Автор курса", systemImage: "person.crop.circle")
                            Spacer()
                            Text(resolvedAuthorId == nil ? "Выбрать" : resolvedAuthorName)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    TextField("Описание", text: $description, axis: .vertical)
                        .lineLimit(3...8)
                }

                // Тумблер «Бесплатный» убрали (Адильхан 09.10: «по сути ненужная кнопка»):
                // цена 0 = курс бесплатный. Цена в кредитах — за них же покупают курс и уроки
                // (было «Цена, $», хотя списываются кредиты).
                Section {
                    HStack {
                        Text("Цена курса, кредиты")
                        Spacer()
                        TextField("0", text: $price)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }
                    Toggle("Опубликован", isOn: $isPublic)
                } header: {
                    Text("Цена и доступ")
                } footer: {
                    Text("0 — курс бесплатный. Уроки «продавать отдельно» остаются платными и в бесплатном курсе.")
                        .font(.footnote)
                }

                Section("Язык") {
                    Picker("Язык курса", selection: $courseLanguage) {
                        Text("Русский").tag("ru")
                        Text("English").tag("en")
                        Text("Қазақша").tag("kk")
                    }
                }

                // Пока идёт сохранение (видео 1–2 ГБ грузится минутами), уроки
                // и модули не трогаем: удаление/перестановка посреди загрузки
                // ломала индексы в uploadPendingLessonVideos → вылет приложения.
                lessonsSection
                    .disabled(saving)

                if !isCreating {
                    Section {
                        Button(role: .destructive) {
                            deleteConfirm = true
                        } label: {
                            Label("Удалить курс", systemImage: "trash")
                        }
                        .disabled(saving)
                    } footer: {
                        Text("Удаление необратимо.")
                    }
                }

                if let err = errorText {
                    Section { Text(err).foregroundColor(.red) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(red: 0.04, green: 0.05, blue: 0.10))
            .safeAreaInset(edge: .bottom) {
                saveStatusBanner
            }
            .navigationTitle(isCreating ? "Новый курс" : "Редактировать")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { Task { await cancelEditing() } }
                        .disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if saving { ProgressView() } else { Text("Сохранить").bold() }
                    }
                    .disabled(saving || title.x5Trimmed.isEmpty)
                }
            }
            .confirmationDialog("Удалить курс?", isPresented: $deleteConfirm, titleVisibility: .visible) {
                Button("Удалить навсегда", role: .destructive) {
                    Task { await runDelete() }
                }
                Button("Отмена", role: .cancel) {}
            }
            .sheet(item: $lessonEditor) { target in
                LessonEditorSheet(
                    lesson: target.lesson,
                    onSave: { saved in
                        upsertLesson(saved, categoryId: target.categoryId, dayId: target.dayId)
                    }
                )
            }
            .sheet(isPresented: $authorPickerPresented) {
                CourseAuthorPickerSheet(
                    authors: availableAuthors,
                    selectedAuthorId: selectedAuthorId,
                    isLoading: loadingAuthors,
                    errorText: authorLoadError,
                    onReload: {
                        Task { await loadCourseAuthors(force: true) }
                    },
                    onSelect: { author in
                        selectedAuthorId = author.id
                        authorName = author.displayName
                    }
                )
            }
            .onAppear { populate() }
            .onChange(of: currentUser.profile?.displayName) { _ in
                guard isCreating else { return }
                if selectedAuthorId == nil {
                    selectedAuthorId = currentUser.profile?.id ?? auth.userId
                }
                if authorName.x5Trimmed.isEmpty {
                    authorName = defaultAuthorName
                }
            }
            .photosPicker(isPresented: $showingCoverPicker, selection: $coverItem, matching: .images)
            .onChange(of: coverItem) { newValue in
                guard let newValue else { return }
                Task { await loadCoverPreview(newValue) }
            }
            // Удаление модуля — только после явного «Удалить». Раньше тап по
            // строке модуля мог сам нажать «Удалить модуль» (см. lessonsSection).
            .confirmationDialog(
                "Удалить модуль?",
                isPresented: Binding(
                    get: { pendingCategoryDeleteId != nil },
                    set: { if !$0 { pendingCategoryDeleteId = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Удалить модуль и его уроки", role: .destructive) {
                    if let id = pendingCategoryDeleteId,
                       let index = categories.firstIndex(where: { $0.id == id }) {
                        deleteCategory(index)
                    }
                    pendingCategoryDeleteId = nil
                }
                Button("Отмена", role: .cancel) { pendingCategoryDeleteId = nil }
            } message: {
                Text("Модуль пропадёт у учеников после сохранения курса.")
            }
            .task {
                await loadCourseAuthors()
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(saving || (editing == nil && existingId != nil))
        .onDisappear { cleanupPendingLessonVideos() }
    }

    @ViewBuilder
    private var coverPicker: some View {
        Button {
            showingCoverPicker = true
        } label: {
            ZStack {
                if let img = coverPreviewImage {
                    Image(uiImage: img).resizable().scaledToFill()
                } else if let url = coverUrl, !url.isEmpty, let u = URL(string: url) {
                    CachedAsyncImage(url: u) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        placeholder
                    }
                } else {
                    placeholder
                }
                if uploadingCover || loadingCoverPreview {
                    Color.black.opacity(0.4)
                    ProgressView().tint(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            // clipShape режет только картинку, не область тапа: scaledToFill
            // вылезает за рамку. contentShape держит тап внутри карточки.
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.borderless)
        .disabled(loadingCoverPreview)
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 30, weight: .light))
            Text("Обложка")
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundColor(.white.opacity(0.6))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.06))
    }

    private var lessonsSection: some View {
        Section {
            ForEach(orderedCategoryIndices, id: \.self) { categoryIndex in
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Название модуля", text: $categories[categoryIndex].title)
                        .font(.headline)
                        .textInputAutocapitalization(.sentences)

                    TextField("Иконка SF Symbol, например folder", text: iconBinding(for: categoryIndex))
                        .font(.caption)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    ForEach(orderedDayIndices(in: categoryIndex), id: \.self) { dayIndex in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                TextField("Название дня или блока", text: $categories[categoryIndex].days[dayIndex].title)
                                    .font(.subheadline)
                                    .textInputAutocapitalization(.sentences)

                                if categories[categoryIndex].days.count > 1 {
                                    Button(role: .destructive) {
                                        deleteDay(categoryIndex: categoryIndex, dayIndex: dayIndex)
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }

                            if categories[categoryIndex].days[dayIndex].lessons.isEmpty {
                                Text("Уроков пока нет")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }

                            ForEach(categories[categoryIndex].days[dayIndex].orderedLessons) { lesson in
                                Button {
                                    lessonEditor = LessonEditorTarget(
                                        categoryId: categories[categoryIndex].id,
                                        dayId: categories[categoryIndex].days[dayIndex].id,
                                        lesson: lesson
                                    )
                                } label: {
                                    LessonDraftRow(lesson: lesson)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        deleteLesson(lesson.id, categoryIndex: categoryIndex, dayIndex: dayIndex)
                                    } label: {
                                        Label("Удалить урок", systemImage: "trash")
                                    }
                                }
                            }

                            Button {
                                openNewLesson(
                                    categoryId: categories[categoryIndex].id,
                                    dayId: categories[categoryIndex].days[dayIndex].id
                                )
                            } label: {
                                Label("Добавить урок", systemImage: "plus.circle")
                            }
                            // Весь модуль — ОДНА строка Form. Кнопки со стилем по
                            // умолчанию в строке срабатывают ВСЕ разом от любого тапа
                            // по ней: «Добавить урок» + «Добавить день» + «Удалить
                            // модуль». Отсюда «модули удаляются» и лишние «День N».
                            // .borderless — каждая кнопка жмётся только сама.
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 6)
                        .padding(.leading, 8)
                    }

                    HStack {
                        Button {
                            addDay(categoryIndex: categoryIndex)
                        } label: {
                            Label("Добавить день / блок", systemImage: "calendar.badge.plus")
                        }
                        .buttonStyle(.borderless)

                        Spacer()

                        if categories.count > 1 {
                            Button(role: .destructive) {
                                // Сначала спрашиваем: модуль с уроками не должен
                                // пропадать от случайного тапа.
                                pendingCategoryDeleteId = categories[categoryIndex].id
                            } label: {
                                Label("Удалить модуль", systemImage: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .font(.footnote)
                }
                .padding(.vertical, 6)
            }

            Button {
                addCategory()
            } label: {
                Label("Добавить модуль", systemImage: "folder.badge.plus")
            }
        } header: {
            Text("Программа курса")
        } footer: {
            Text("Модули отображаются в заданном порядке; внутри можно добавлять дни, блоки и уроки. Видео задаётся прямой ссылкой MP4/HLS или импортом файла.")
        }
    }

    private func populate() {
        guard !didPopulate else { return }
        didPopulate = true

        guard let c = editing else {
            categories = [.defaultContent()]
            selectedAuthorId = auth.userId
            authorName = defaultAuthorName
            return
        }
        title = c.title
        description = c.description ?? ""
        marketingHook = c.marketingHook ?? ""
        price = String(c.price ?? 0)
        isPublic = c.isPublic ?? false
        courseLanguage = c.courseLanguage ?? "ru"
        selectedAuthorId = c.authorId
        if let existingAuthor = c.authorName?.x5Trimmed, !existingAuthor.isEmpty {
            authorName = existingAuthor
        } else {
            authorName = defaultAuthorName
        }
        coverUrl = c.coverUrl
        categories = c.categories.map { EditableCategory(category: $0) }
        if categories.isEmpty {
            categories = [.defaultContent()]
        }
    }

    private var defaultAuthorName: String {
        if let profile = currentUser.profile {
            let profileName = profile.displayName.x5Trimmed
            if !profileName.isEmpty {
                return profileName
            }
        }
        if let email = auth.userEmail?.x5Trimmed,
           let prefix = email.split(separator: "@").first,
           !prefix.isEmpty {
            return String(prefix).replacingOccurrences(of: ".", with: " ").capitalized
        }
        return "Xfive marketing"
    }

    @ViewBuilder
    private var saveStatusBanner: some View {
        if let message = saveStage.message {
            HStack(spacing: 12) {
                if saveStage.isProgress {
                    if case .uploadingVideo = saveStage,
                       let progress = service.videoUploadProgress {
                        ProgressView(value: progress)
                            .frame(width: 52)
                    } else {
                        ProgressView()
                    }
                } else {
                    Image(
                        systemName: saveStage == .completed
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(saveStage == .completed ? Color.green : Color.red)
                }
                Text(message)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(3)
                Spacer(minLength: 0)
                if case .uploadingVideo = saveStage,
                   let progress = service.videoUploadProgress {
                    // NaN/∞ в Int(...) = мгновенный вылет; прогресс приходит из
                    // сторонних экспортёров, поэтому подстраховка здесь.
                    Text("\(progress.isFinite ? Int((min(max(progress, 0), 1) * 100).rounded()) : 0)%")
                        .font(.caption.monospacedDigit().weight(.bold))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial)
        }
    }

    private func loadCourseAuthors(force: Bool = false) async {
        guard !loadingAuthors else { return }
        guard force || availableAuthors.isEmpty else { return }
        guard let token = await auth.freshAccessToken() else {
            authorLoadError = "Не удалось подтвердить вход. Войдите снова."
            return
        }

        loadingAuthors = true
        authorLoadError = nil
        var authors = await service.loadCourseAuthors(accessToken: token)
        loadingAuthors = false

        if let currentProfile = currentUser.profile,
           !authors.contains(where: { $0.id.caseInsensitiveCompare(currentProfile.id) == .orderedSame }) {
            authors.append(currentProfile)
        }
        availableAuthors = authors.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        if let selectedAuthorId,
           let matchingAuthor = availableAuthors.first(where: {
               $0.id.caseInsensitiveCompare(selectedAuthorId) == .orderedSame
           }) {
            authorName = matchingAuthor.displayName
        }
        if availableAuthors.isEmpty {
            authorLoadError = service.error ?? "Профили авторов не найдены."
        }
    }

    private func loadCoverPreview(_ item: PhotosPickerItem) async {
        // Раньше: try? + молчаливый return → «выбрал фото, а обложка не поменялась».
        // Теперь общий загрузчик (Data → файл, ужатие вне главного потока),
        // спиннер на карточке и текст ошибки.
        loadingCoverPreview = true
        coverPickError = nil
        do {
            let prepared = try await PickedPhotoLoader.loadPrepared(from: item)
            coverPreviewData = prepared.jpeg
            coverPreviewImage = prepared.preview
        } catch {
            coverPickError = PickedPhotoLoader.errorText
        }
        loadingCoverPreview = false
        // Сброс выбора: иначе то же фото второй раз не выбрать — onChange молчит.
        if coverItem == item { coverItem = nil }
    }

    private func save() async {
        saveStage = .preparing
        errorText = nil
        guard let resolvedAuthorId else {
            markSaveFailed("Выберите автора курса из профилей.")
            return
        }
        guard let token = await auth.freshAccessToken() else {
            markSaveFailed("Не удалось подтвердить вход. Войдите снова.")
            return
        }
        saving = true
        // Сжатие + загрузка длинного урока идут минутами. Если экран гаснет,
        // iOS усыпляет приложение посреди экспорта/TUS и может выгрузить его
        // из памяти — для автора это выглядит как «приложение закрылось».
        // идея: beginBackgroundTask + фоновая URLSession для Bunny-загрузки.
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            saving = false
            UIApplication.shared.isIdleTimerDisabled = false
        }

        var courseId = existingId

        // Create row first if new. This gives storage a stable course path.
        if courseId == nil {
            saveStage = .creatingCourse
            guard let created = await service.createCourse(
                title: title,
                authorName: resolvedAuthorName,
                authorId: resolvedAuthorId,
                accessToken: token
            ) else {
                markSaveFailed(service.error ?? "Не удалось создать курс.")
                return
            }
            saveIdentity.recordCreatedCourse(id: created.id)
            courseId = saveIdentity.persistedCourseID
        }
        guard let id = courseId else {
            markSaveFailed("Не удалось подготовить курс к сохранению.")
            return
        }

        // Checkpoint: write modules and lessons BEFORE the cover and the slow
        // video upload. Otherwise a failed or interrupted upload leaves the
        // course with `categories = []` and the new module is lost.
        saveStage = .savingCourse
        guard await persistCourseStructure(courseId: id, accessToken: token) else {
            markSaveFailed(service.error ?? "Не удалось сохранить модули курса.")
            return
        }

        if let jpeg = coverPreviewData {
            uploadingCover = true
            saveStage = .uploadingCover
            guard let uploadedCoverURL = await service.uploadCover(courseId: id, jpegData: jpeg, accessToken: token) else {
                uploadingCover = false
                markSaveFailed(service.error ?? "Не удалось загрузить обложку курса.")
                return
            }
            uploadingCover = false
            coverUrl = uploadedCoverURL
            coverPreviewData = nil
            coverPreviewImage = nil
        }

        guard await uploadPendingLessonVideos(courseId: id, accessToken: token) else {
            return
        }
        guard let postUploadToken = await auth.accessTokenForUpload() else {
            markSaveFailed("Сессия истекла во время загрузки. Войдите снова.")
            return
        }
        guard await uploadPendingLessonThumbnails(
            courseId: id,
            accessToken: postUploadToken
        ) else {
            return
        }

        let fields = courseFields(publishAsChosen: true)
        saveStage = .savingCourse
        let ok = await service.updateCourse(
            id: id,
            fields: fields,
            accessToken: postUploadToken
        )
        if !ok {
            markSaveFailed(service.error ?? "Не удалось сохранить.")
            return
        }
        saveStage = .completed
        onChange()
        try? await Task.sleep(nanoseconds: 350_000_000)
        dismiss()
    }

    private func courseFields(publishAsChosen: Bool) -> [String: Any] {
        // Callers run only after the author was validated in save().
        let resolvedAuthorId = self.resolvedAuthorId ?? ""
        let priceInt = max(Int(price.x5Trimmed) ?? 0, 0)
        return [
            "title": title,
            "description": description.x5Trimmed.isEmpty ? NSNull() : description,
            "marketing_hook": marketingHook.x5Trimmed.isEmpty ? NSNull() : marketingHook,
            "author_name": resolvedAuthorName,
            "author_id": resolvedAuthorId,
            "cover_url": coverUrl?.x5Trimmed.isEmpty == false ? (coverUrl ?? "") : NSNull(),
            "price": priceInt,
            // Бесплатность — только из цены: тумблера больше нет, два поля не спорят.
            "is_free": priceInt == 0,
            // Checkpoints never change visibility: a new course stays hidden and
            // an existing one keeps its server state until the final save.
            "is_public": publishAsChosen ? isPublic : (editing?.isPublic ?? false),
            "course_language": courseLanguage,
            "categories": categoriesPayload()
        ]
    }

    /// Intermediate save of the course structure (modules, lessons, media that
    /// is already uploaded). Lessons whose video is still pending are saved
    /// without a video URL and get it on a later checkpoint or the final save.
    private func persistCourseStructure(courseId: String, accessToken: String) async -> Bool {
        let ok = await service.updateCourse(
            id: courseId,
            fields: courseFields(publishAsChosen: false),
            accessToken: accessToken
        )
        if ok { structureCheckpointed = true }
        return ok
    }

    private func runDelete() async {
        guard let id = existingId, let token = await auth.freshAccessToken() else { return }
        saving = true
        defer { saving = false }
        let ok = await service.deleteCourse(id: id, accessToken: token)
        if ok {
            cleanupPendingLessonVideos()
            onChange()
            dismiss()
        } else {
            errorText = service.error ?? "Не удалось удалить."
        }
    }

    private func uploadPendingLessonVideos(courseId: String, accessToken: String) async -> Bool {
        // Снимок очереди ДО долгих await: загрузка 1–2 ГБ идёт минутами, а
        // `categories` за это время может поменяться. Старый код писал
        // результат по индексам, снятым до await → «Index out of range» =
        // вылет. Теперь после каждой загрузки урок ищем заново по id.
        let pending = categories
            .flatMap(\.days)
            .flatMap(\.lessons)
            .compactMap { lesson in
                lesson.pendingVideoFileURL.map { (lessonId: lesson.id, fileURL: $0) }
            }
        let total = pending.count
        var uploaded = 0

        for item in pending {
            saveStage = .uploadingVideo(current: uploaded + 1, total: total)
            guard let uploadResult = await service.uploadLessonVideo(
                courseId: courseId,
                lessonId: item.lessonId,
                fileURL: item.fileURL,
                accessToken: accessToken,
                accessTokenProvider: {
                    await auth.accessTokenForUpload()
                }
            ) else {
                markSaveFailed(
                    (service.error ?? "Не удалось загрузить видео урока.")
                        + " Модули и уроки сохранены. Исправьте видео и нажмите «Сохранить» ещё раз."
                )
                return false
            }

            CourseVideoStaging.removeIfManaged(item.fileURL)
            // Урок могли удалить или заменить ему видео, пока шла загрузка —
            // тогда результат не пишем, чтобы не затереть чужие данные.
            if let path = lessonPath(id: item.lessonId),
               categories[path.category].days[path.day].lessons[path.lesson]
                .pendingVideoFileURL == item.fileURL {
                categories[path.category].days[path.day].lessons[path.lesson]
                    .markVideoUploadSucceeded(uploadResult)
            }
            uploaded += 1
            // Keep the uploaded URL on the server even if a later video fails.
            let checkpointToken = await auth.accessTokenForUpload() ?? accessToken
            _ = await persistCourseStructure(courseId: courseId, accessToken: checkpointToken)
        }
        return true
    }

    private func uploadPendingLessonThumbnails(courseId: String, accessToken: String) async -> Bool {
        // Та же защита от устаревших индексов, что и у видео (см. выше).
        let pending = categories
            .flatMap(\.days)
            .flatMap(\.lessons)
            .compactMap { lesson in
                lesson.pendingThumbnailData.map { (lessonId: lesson.id, jpegData: $0) }
            }
        let total = pending.count
        var uploaded = 0

        for item in pending {
            saveStage = .uploadingLessonCover(current: uploaded + 1, total: total)
            guard let publicURL = await service.uploadLessonThumbnail(courseId: courseId, lessonId: item.lessonId, jpegData: item.jpegData, accessToken: accessToken) else {
                markSaveFailed(service.error ?? "Не удалось загрузить обложку урока.")
                return false
            }

            if let path = lessonPath(id: item.lessonId) {
                categories[path.category].days[path.day].lessons[path.lesson]
                    .markThumbnailUploadSucceeded(publicURL: publicURL)
            }
            uploaded += 1
        }
        return true
    }

    /// Где урок лежит сейчас (после await). nil — урок удалили.
    private func lessonPath(id lessonId: String) -> (category: Int, day: Int, lesson: Int)? {
        for categoryIndex in categories.indices {
            for dayIndex in categories[categoryIndex].days.indices {
                if let lessonIndex = categories[categoryIndex].days[dayIndex].lessons
                    .firstIndex(where: { $0.id == lessonId }) {
                    return (categoryIndex, dayIndex, lessonIndex)
                }
            }
        }
        return nil
    }

    private func markSaveFailed(_ message: String) {
        errorText = message
        saveStage = .failed(message)
    }


    private func orderedCategories() -> [EditableCategory] {
        categories.sorted { $0.order < $1.order }
    }

    private var orderedCategoryIndices: [Int] {
        categories.indices.sorted { categories[$0].order < categories[$1].order }
    }

    private func orderedDayIndices(in categoryIndex: Int) -> [Int] {
        guard categories.indices.contains(categoryIndex) else { return [] }
        return categories[categoryIndex].days.indices.sorted {
            categories[categoryIndex].days[$0].order < categories[categoryIndex].days[$1].order
        }
    }

    private func iconBinding(for categoryIndex: Int) -> Binding<String> {
        Binding(
            get: {
                guard categories.indices.contains(categoryIndex) else { return "" }
                return categories[categoryIndex].icon ?? ""
            },
            set: { value in
                guard categories.indices.contains(categoryIndex) else { return }
                categories[categoryIndex].icon = value.x5Trimmed.isEmpty ? nil : value.x5Trimmed
            }
        )
    }

    private func categoriesPayload() -> [[String: Any]] {
        CourseDraft(categories: categories).categoriesPayload
    }

    private func cancelEditing() async {
        guard editing == nil, let id = existingId else {
            cleanupPendingLessonVideos()
            dismiss()
            return
        }

        // Modules were already saved by a checkpoint: keep the hidden draft
        // instead of deleting the whole course together with them.
        if structureCheckpointed {
            cleanupPendingLessonVideos()
            onChange()
            dismiss()
            return
        }

        guard let token = await auth.freshAccessToken() else {
            errorText = "Не удалось закрыть черновик: войдите снова и удалите его."
            return
        }

        saving = true
        let deleted = await service.deleteCourse(id: id, accessToken: token)
        saving = false
        if deleted {
            cleanupPendingLessonVideos()
            dismiss()
        } else {
            errorText = service.error ?? "Не удалось удалить незавершённый черновик."
        }
    }

    private var resolvedAuthorName: String {
        let value = authorName.x5Trimmed
        return value.isEmpty ? defaultAuthorName : value
    }

    private var resolvedAuthorId: String? {
        guard let value = selectedAuthorId?.x5Trimmed,
              UUID(uuidString: value) != nil else { return nil }
        return value
    }

    private func ensureDefaultContent() {
        if categories.isEmpty {
            categories = [.defaultContent()]
        }
        for index in categories.indices where categories[index].days.isEmpty {
            categories[index].days = [EditableCategory.defaultDay(order: 1)]
        }
    }

    private func addCategory() {
        let nextOrder = (categories.map(\.order).max() ?? 0) + 1
        categories.append(
            EditableCategory(
                id: "cat_\(UUID().uuidString)",
                title: "Новый раздел",
                order: nextOrder,
                icon: "folder",
                days: [EditableCategory.defaultDay(order: 1)]
            )
        )
    }

    private func deleteCategory(_ categoryIndex: Int) {
        guard categories.indices.contains(categoryIndex), categories.count > 1 else { return }
        cleanupPendingLessonVideos(
            categories[categoryIndex].days.flatMap(\.lessons)
        )
        categories.remove(at: categoryIndex)
        normalizeCategoryOrder()
    }

    private func addDay(categoryIndex: Int) {
        guard categories.indices.contains(categoryIndex) else { return }
        let nextOrder = (categories[categoryIndex].days.map(\.order).max() ?? 0) + 1
        categories[categoryIndex].days.append(EditableCategory.defaultDay(order: nextOrder))
    }

    private func deleteDay(categoryIndex: Int, dayIndex: Int) {
        guard categories.indices.contains(categoryIndex),
              categories[categoryIndex].days.indices.contains(dayIndex),
              categories[categoryIndex].days.count > 1 else { return }
        cleanupPendingLessonVideos(categories[categoryIndex].days[dayIndex].lessons)
        categories[categoryIndex].days.remove(at: dayIndex)
        normalizeDayOrder(categoryIndex: categoryIndex)
    }

    private func deleteLesson(_ lessonId: String, categoryIndex: Int, dayIndex: Int) {
        guard categories.indices.contains(categoryIndex),
              categories[categoryIndex].days.indices.contains(dayIndex) else { return }
        if let lesson = categories[categoryIndex].days[dayIndex].lessons.first(where: { $0.id == lessonId }) {
            CourseVideoStaging.removeIfManaged(lesson.pendingVideoFileURL)
        }
        categories[categoryIndex].days[dayIndex].lessons.removeAll { $0.id == lessonId }
        normalizeLessonOrder(categoryIndex: categoryIndex, dayIndex: dayIndex)
    }

    private func cleanupPendingLessonVideos(_ lessons: [EditableLesson]? = nil) {
        let pendingLessons = lessons ?? categories
            .flatMap(\.days)
            .flatMap(\.lessons)
        for lesson in pendingLessons {
            CourseVideoStaging.removeIfManaged(lesson.pendingVideoFileURL)
        }
    }

    private func normalizeCategoryOrder() {
        for (offset, categoryIndex) in orderedCategoryIndices.enumerated() {
            categories[categoryIndex].order = offset + 1
        }
    }

    private func normalizeDayOrder(categoryIndex: Int) {
        guard categories.indices.contains(categoryIndex) else { return }
        for (offset, dayIndex) in orderedDayIndices(in: categoryIndex).enumerated() {
            categories[categoryIndex].days[dayIndex].order = offset + 1
        }
    }

    private func openFirstNewLesson() {
        ensureDefaultContent()
        guard let category = orderedCategories().first,
              let day = category.orderedDays.first else { return }
        openNewLesson(categoryId: category.id, dayId: day.id)
    }

    private func openNewLesson(categoryId: String, dayId: String) {
        let nextOrder = lessons(categoryId: categoryId, dayId: dayId).count + 1
        lessonEditor = LessonEditorTarget(categoryId: categoryId, dayId: dayId, lesson: .new(order: nextOrder))
    }

    private func lessons(categoryId: String, dayId: String) -> [EditableLesson] {
        guard let category = categories.first(where: { $0.id == categoryId }),
              let day = category.days.first(where: { $0.id == dayId }) else { return [] }
        return day.lessons
    }

    private func upsertLesson(_ lesson: EditableLesson, categoryId: String, dayId: String) {
        guard let categoryIndex = categories.firstIndex(where: { $0.id == categoryId }),
              let dayIndex = categories[categoryIndex].days.firstIndex(where: { $0.id == dayId }) else { return }

        if let lessonIndex = categories[categoryIndex].days[dayIndex].lessons.firstIndex(where: { $0.id == lesson.id }) {
            categories[categoryIndex].days[dayIndex].lessons[lessonIndex] = lesson
        } else {
            categories[categoryIndex].days[dayIndex].lessons.append(lesson)
        }
        normalizeLessonOrder(categoryIndex: categoryIndex, dayIndex: dayIndex)
    }

    private func normalizeLessonOrder(categoryIndex: Int, dayIndex: Int) {
        let sorted = categories[categoryIndex].days[dayIndex].orderedLessons.enumerated().map { index, lesson in
            var updated = lesson
            updated.order = index + 1
            return updated
        }
        categories[categoryIndex].days[dayIndex].lessons = sorted
    }
}

private struct CourseAuthorPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    let authors: [UserProfile]
    let selectedAuthorId: String?
    let isLoading: Bool
    let errorText: String?
    let onReload: () -> Void
    let onSelect: (UserProfile) -> Void

    private var filteredAuthors: [UserProfile] {
        let query = searchText.x5Trimmed
        guard !query.isEmpty else { return authors }
        return authors.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || ($0.nickname?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && authors.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Загрузка профилей…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if authors.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "person.crop.circle.badge.exclamationmark")
                            .font(.system(size: 34))
                            .foregroundStyle(.secondary)
                        Text(errorText ?? "Профили авторов не найдены.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        Button("Повторить", action: onReload)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filteredAuthors) { author in
                        Button {
                            onSelect(author)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                authorAvatar(author)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(author.displayName)
                                        .foregroundStyle(.primary)
                                    if let nickname = author.nickname?.x5Trimmed,
                                       !nickname.isEmpty {
                                        Text("@\(nickname)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if selectedAuthorId?.caseInsensitiveCompare(author.id) == .orderedSame {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .searchable(text: $searchText, prompt: "Имя или никнейм")
                    .refreshable {
                        onReload()
                    }
                }
            }
            .navigationTitle("Автор курса")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func authorAvatar(_ author: UserProfile) -> some View {
        if let raw = author.avatar?.x5Trimmed,
           let url = URL(string: raw),
           !raw.isEmpty {
            CachedAsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                avatarPlaceholder
            }
            .frame(width: 42, height: 42)
            .clipShape(Circle())
        } else {
            avatarPlaceholder
        }
    }

    private var avatarPlaceholder: some View {
        Image(systemName: "person.crop.circle.fill")
            .font(.system(size: 39))
            .foregroundStyle(.secondary)
            .frame(width: 42, height: 42)
    }
}

private struct LessonEditorTarget: Identifiable {
    let categoryId: String
    let dayId: String
    let lesson: EditableLesson

    var id: String { "\(categoryId)-\(dayId)-\(lesson.id)" }
}

private struct LessonDraftRow: View {
    let lesson: EditableLesson
    /// Мини-копия новой обложки (58×38). Делается один раз в .task, а не
    /// UIImage(data:) в body: тот декодировал фото на каждую букву в названии модуля.
    @State private var pendingThumb: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            lessonThumb

            VStack(alignment: .leading, spacing: 3) {
                Text(lesson.title.x5Trimmed.isEmpty ? "Новый урок" : lesson.title)
                    .foregroundStyle(.primary)
                HStack(spacing: 8) {
                    Text(lesson.videoLabel)
                    // Метку оставили: флаг по-прежнему открывает урок всем, автор должен это видеть.
                    if lesson.isFreePreview {
                        Text("Бесплатный урок")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .task(id: lesson.pendingThumbnailData) {
            guard let data = lesson.pendingThumbnailData else {
                pendingThumb = nil
                return
            }
            pendingThumb = await Task.detached(priority: .utility) {
                CourseCoverImage.prepare(data, maxPixelSize: 160)?.preview
            }.value
        }
    }

    @ViewBuilder
    private var lessonThumb: some View {
        ZStack {
            if lesson.pendingThumbnailData != nil, let img = pendingThumb {
                Image(uiImage: img).resizable().scaledToFill()
            } else if let url = URL(string: lesson.thumbnailUrl), !lesson.thumbnailUrl.x5Trimmed.isEmpty {
                CachedAsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    thumbPlaceholder
                }
            } else {
                thumbPlaceholder
            }

            Image(systemName: lesson.hasVideo ? "play.fill" : "play.slash")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(lesson.hasVideo ? Color.black : .white.opacity(0.7))
                .frame(width: 22, height: 22)
                .background(lesson.hasVideo ? Color.accentColor : Color.white.opacity(0.12))
                .clipShape(Circle())
        }
        .frame(width: 58, height: 38)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var thumbPlaceholder: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .overlay {
                Image(systemName: "photo")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
    }
}

private struct LessonEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let lesson: EditableLesson
    private let initialPendingVideoFileURL: URL?
    let onSave: (EditableLesson) -> Void

    @State private var title: String
    @State private var price: String
    @State private var videoUrl: String
    @State private var youtubeUrl: String
    @State private var thumbnailUrl: String
    @State private var isFreePreview: Bool
    @State private var sellSeparately: Bool
    @State private var pendingVideoFileURL: URL?
    @State private var pendingVideoFileName: String?
    @State private var pendingThumbnailData: Data?
    /// Готовая картинка новой обложки — чтобы не декодировать JPEG в body.
    @State private var pendingThumbnailImage: UIImage?
    @State private var showingVideoPicker = false
    @State private var thumbnailItem: PhotosPickerItem?
    // Один флаг на одну галерею обложки: раньше в строке Form стояли два
    // PhotosPicker, и тап по строке открывал оба → галерея «моргала» 2 раза.
    @State private var showingThumbnailPicker = false
    @State private var uploading = false
    @State private var uploadingThumbnail = false
    @State private var errorText: String?
    @State private var didCommit = false

    init(
        lesson: EditableLesson,
        onSave: @escaping (EditableLesson) -> Void
    ) {
        self.lesson = lesson
        initialPendingVideoFileURL = lesson.pendingVideoFileURL
        self.onSave = onSave
        _title = State(initialValue: lesson.title)
        _price = State(initialValue: lesson.price)
        _videoUrl = State(initialValue: lesson.videoUrl)
        _youtubeUrl = State(initialValue: lesson.youtubeUrl)
        _thumbnailUrl = State(initialValue: lesson.thumbnailUrl)
        _isFreePreview = State(initialValue: lesson.isFreePreview)
        _sellSeparately = State(initialValue: lesson.sellSeparately)
        _pendingVideoFileURL = State(initialValue: lesson.pendingVideoFileURL)
        _pendingVideoFileName = State(initialValue: lesson.pendingVideoFileName)
        _pendingThumbnailData = State(initialValue: lesson.pendingThumbnailData)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Урок") {
                    TextField("Название урока", text: $title)
                        .textInputAutocapitalization(.sentences)
                    // Переключатель «Бесплатный preview» убран (Адильхан 09.10: «нет смысла»).
                    // Флаг isFreePreview не трогаем: старые уроки сохраняются с тем же значением.
                }

                Section {
                    thumbnailPicker

                    TextField("MP4/HLS URL", text: $videoUrl, axis: .vertical)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(2...4)
                    TextField("YouTube URL", text: $youtubeUrl, axis: .vertical)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(1...3)

                    Button {
                        uploading = true
                        showingVideoPicker = true
                    } label: {
                        Label(videoImportTitle, systemImage: "photo.on.rectangle.angled")
                    }
                    .disabled(uploading)

                    if let pendingVideoFileName {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Видео подготовлено", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(pendingVideoFileName)
                                .lineLimit(1)
                            Text("Загрузится после сохранения курса")
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    } else if lesson.bunnyVideoID != nil {
                        Label(lesson.videoLabel, systemImage: "play.rectangle.on.rectangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Text(CourseVideoUploadPolicy.uploadGuidance)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                } header: {
                    Text("Видео")
                } footer: {
                    Text("Видео и обложка остаются черновиком до сохранения всего курса. При обрыве сети загрузка продолжится с подтвержденного блока; опубликованная ссылка не меняется до полного успеха.")
                }

                Section {
                    Toggle("Продавать отдельно", isOn: $sellSeparately)
                        // Переключателя preview больше нет, поэтому не блокируем продажу:
                        // автор сам включил «Продавать отдельно» → урок перестаёт быть бесплатным.
                        .onChange(of: sellSeparately) { newValue in
                            if newValue { isFreePreview = false }
                        }
                    if sellSeparately && !isFreePreview {
                        HStack {
                            Text("Цена урока")
                            Spacer()
                            TextField("0", text: $price)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 120)
                            Text("кр.")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Доступ")
                } footer: {
                    Text(accessFooterText)
                        .font(.footnote)
                }

                if let errorText {
                    Section { Text(errorText).foregroundColor(.red) }
                }
            }
            .navigationTitle("Урок")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { cancelAndDismiss() }
                        .disabled(uploading || uploadingThumbnail)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        commitAndDismiss()
                    }
                    .disabled(title.x5Trimmed.isEmpty || uploading || uploadingThumbnail)
                }
            }
            // Галерея обложки показывается только отсюда — одна презентация на весь экран.
            .photosPicker(isPresented: $showingThumbnailPicker, selection: $thumbnailItem, matching: .images)
            .task {
                // Урок открыли повторно до сохранения курса: обложка уже выбрана,
                // готовим картинку для показа один раз.
                guard pendingThumbnailImage == nil, let data = pendingThumbnailData else { return }
                pendingThumbnailImage = await Task.detached(priority: .userInitiated) {
                    UIImage(data: data)
                }.value
            }
            .onChange(of: thumbnailItem) { newValue in
                guard let newValue else { return }
                Task { await importThumbnail(newValue) }
            }
            .sheet(isPresented: $showingVideoPicker, onDismiss: {
                uploading = false
            }) {
                GalleryVideoPicker(
                    stagingID: "lesson-\(lesson.id)",
                    onResult: handleVideoPickerResult,
                    onCancel: {
                        uploading = false
                        showingVideoPicker = false
                    }
                )
                .ignoresSafeArea()
            }
        }
        .interactiveDismissDisabled(uploading || uploadingThumbnail)
        .onDisappear {
            if !didCommit {
                cleanupUncommittedVideo()
            }
        }
    }

    @ViewBuilder
    private var thumbnailPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Обложка видео")
                .font(.subheadline.weight(.semibold))

            // В строке Form кнопки со стилем по умолчанию срабатывают ВСЕ сразу
            // при тапе в любом месте строки. Поэтому .borderless у каждой кнопки,
            // а сама галерея — один .photosPicker на Form (см. body).
            Button {
                showingThumbnailPicker = true
            } label: {
                ZStack {
                    if pendingThumbnailData != nil, let img = pendingThumbnailImage {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else if let url = URL(string: thumbnailUrl), !thumbnailUrl.x5Trimmed.isEmpty {
                        CachedAsyncImage(url: url) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            thumbnailPlaceholder
                        }
                    } else {
                        thumbnailPlaceholder
                    }

                    if uploadingThumbnail {
                        Color.black.opacity(0.38)
                        ProgressView().tint(.white)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 154)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                // Тап только внутри карточки: scaledToFill вылезает за рамку.
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.borderless)
            .disabled(uploadingThumbnail)

            HStack {
                Button {
                    showingThumbnailPicker = true
                } label: {
                    Label(thumbnailActionTitle, systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.borderless)
                .disabled(uploadingThumbnail)

                Spacer()

                if pendingThumbnailData != nil || !thumbnailUrl.x5Trimmed.isEmpty {
                    Button(role: .destructive) {
                        pendingThumbnailData = nil
                        pendingThumbnailImage = nil
                        // Сброс выбора: иначе то же фото повторно не выбрать —
                        // onChange(of: thumbnailItem) не сработает.
                        thumbnailItem = nil
                        thumbnailUrl = ""
                    } label: {
                        Label("Убрать", systemImage: "trash")
                    }
                    // Без .borderless тап по «Заменить обложку» заодно стирал обложку.
                    .buttonStyle(.borderless)
                    .disabled(uploadingThumbnail)
                }
            }
            .font(.footnote)

            TextField("Thumbnail URL", text: $thumbnailUrl, axis: .vertical)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(1...3)
        }
    }

    private var accessFooterText: String {
        if sellSeparately && !isFreePreview {
            return "Ученик сможет купить только этот урок. Цену подтверждает сервер, поэтому она должна быть больше нуля."
        }
        // Старый урок с флагом preview: честно пишем, что он открыт всем.
        if isFreePreview {
            return "Урок открыт бесплатно. Включите «Продавать отдельно», чтобы продавать его."
        }
        return "Доступ к уроку открывается покупкой всего курса."
    }

    private var thumbnailActionTitle: String {
        if uploadingThumbnail { return "Загрузка..." }
        if pendingThumbnailData != nil || !thumbnailUrl.x5Trimmed.isEmpty { return "Заменить обложку" }
        return "Добавить обложку"
    }

    private var thumbnailPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 28, weight: .light))
            Text("Добавить обложку видео")
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundColor(.white.opacity(0.62))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.06))
    }

    private var videoImportTitle: String {
        if uploading { return "Подготовка видео..." }
        if pendingVideoFileURL != nil
            || !videoUrl.x5Trimmed.isEmpty
            || lesson.bunnyVideoID != nil {
            return "Заменить видео из галереи"
        }
        return "Выбрать видео из галереи"
    }

    @MainActor
    private func handleVideoPickerResult(_ result: Result<CourseGalleryVideo, Error>) {
        uploading = false
        showingVideoPicker = false
        errorText = nil

        switch result {
        case .success(let imported):
            if pendingVideoFileURL != initialPendingVideoFileURL {
                CourseVideoStaging.removeIfManaged(pendingVideoFileURL)
            }
            pendingVideoFileURL = imported.fileURL
            pendingVideoFileName = imported.originalFileName
        case .failure(let error):
            errorText = "Не удалось подготовить видео из галереи: \(error.localizedDescription)"
        }
    }

    private func importThumbnail(_ item: PhotosPickerItem) async {
        uploadingThumbnail = true
        defer {
            uploadingThumbnail = false
            // Сброс выбора: иначе то же фото второй раз не выбрать — onChange молчит.
            if thumbnailItem == item { thumbnailItem = nil }
        }
        errorText = nil

        // Общий загрузчик с генератором обложек: Data → запасной путь через файл,
        // ужатие до 1600 px вне главного потока (см. PickedPhotoLoader).
        do {
            let prepared = try await PickedPhotoLoader.loadPrepared(from: item)
            pendingThumbnailData = prepared.jpeg
            pendingThumbnailImage = prepared.preview
        } catch {
            errorText = PickedPhotoLoader.errorText
        }
    }

    private func commitAndDismiss() {
        if pendingVideoFileURL != initialPendingVideoFileURL {
            CourseVideoStaging.removeIfManaged(initialPendingVideoFileURL)
        }
        didCommit = true
        onSave(updatedLesson())
        dismiss()
    }

    private func cancelAndDismiss() {
        cleanupUncommittedVideo()
        dismiss()
    }

    private func cleanupUncommittedVideo() {
        guard pendingVideoFileURL != initialPendingVideoFileURL else { return }
        CourseVideoStaging.removeIfManaged(pendingVideoFileURL)
    }

    private func updatedLesson() -> EditableLesson {
        lesson.applyingEditorChanges(
            title: title.x5Trimmed,
            price: price.x5Trimmed.isEmpty ? "0" : price.x5Trimmed,
            videoUrl: videoUrl.x5Trimmed,
            youtubeUrl: youtubeUrl.x5Trimmed,
            thumbnailUrl: thumbnailUrl.x5Trimmed,
            isFreePreview: isFreePreview,
            sellSeparately: sellSeparately,
            pendingVideoFileURL: pendingVideoFileURL,
            pendingVideoFileName: pendingVideoFileName,
            pendingThumbnailData: pendingThumbnailData
        )
    }
}

private extension String {
    var x5Trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
