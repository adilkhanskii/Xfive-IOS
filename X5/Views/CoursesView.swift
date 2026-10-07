import SwiftUI
import PhotosUI

struct CoursesView: View {
    @EnvironmentObject private var auth: Auth
    @EnvironmentObject private var loc: LocalizationService
    @StateObject private var service = CoursesService()
    @State private var showingPaywall = false
    @State private var editorTarget: EditorTarget?
    @State private var showingCourseSubmission = false
    @State private var showingSubmissions = false

    private var isDev: Bool { Roles.isDeveloper(email: auth.userEmail, userId: auth.userId) }
    private var featuredCourse: Course? { service.courses.first }
    private var academyCourses: [Course] { Array(service.courses.dropFirst()) }

    /// Sheet payload — `.create` for new course, `.edit(course)` for existing.
    private enum EditorTarget: Identifiable {
        case create
        case edit(Course)
        var id: String {
            switch self {
            case .create: return "_new"
            case .edit(let c): return c.id
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if service.isLoading && service.courses.isEmpty {
                    ProgressView().tint(.accentColor)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = service.error, service.courses.isEmpty {
                    ErrorState(message: err) {
                        Task { await reloadCourses() }
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            HStack(alignment: .center, spacing: 12) {
                                Text("CourseUP")
                                    .font(.system(size: 34, weight: .black))
                                    .foregroundColor(.white)
                                    .kerning(0)

                                Spacer()
                            }
                            .padding(.top, 4)

                            if service.courses.isEmpty {
                                VStack(spacing: 14) {
                                    Image(systemName: "graduationcap")
                                        .font(.system(size: 40, weight: .medium))
                                        .foregroundColor(.accentColor)
                                    Text(loc.t("courses_empty_title"))
                                        .font(.title3.bold())
                                    Text(loc.t("courses_empty_message"))
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.center)
                                    Button(loc.t("courses_reload")) {
                                        Task { await reloadCourses() }
                                    }
                                    .buttonStyle(.bordered)
                                }
                                .padding(.vertical, 48)
                                .frame(maxWidth: .infinity)
                                .accessibilityIdentifier("Course.catalog.empty")
                            }

                            if let course = featuredCourse {
                                ZStack(alignment: .topLeading) {
                                    NavigationLink {
                                        CourseDetailView(course: course, openPaywall: { showingPaywall = true })
                                    } label: {
                                        CourseCard(course: course, showHiddenBadge: isDev && course.isPublic == false)
                                            .accessibilityIdentifier("Course.catalog.item.\(course.id)")
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        if isDev {
                                            Button {
                                                editorTarget = .edit(course)
                                            } label: {
                                                Label("Редактировать", systemImage: "pencil")
                                            }
                                            Button(role: .destructive) {
                                                Task {
                                                    guard let token = auth.accessToken else { return }
                                                    _ = await service.deleteCourse(id: course.id, accessToken: token)
                                                    await reloadCourses()
                                                }
                                            } label: {
                                                Label("Удалить", systemImage: "trash")
                                            }
                                        }
                                    }

                                    // Visible edit button for developers (overlay top-left)
                                    if isDev {
                                        Button {
                                            editorTarget = .edit(course)
                                        } label: {
                                            Image(systemName: "pencil")
                                                .font(.system(size: 14, weight: .bold))
                                                .foregroundColor(.black)
                                                .frame(width: 36, height: 36)
                                                .background(Color.accentColor)
                                                .clipShape(Circle())
                                                .shadow(color: .black.opacity(0.4), radius: 6)
                                        }
                                        .buttonStyle(.plain)
                                        .padding(12)
                                    }
                                }
                            }

                            ForEach(Array(academyCourses.enumerated()), id: \.element.id) { index, course in
                                ZStack(alignment: .topLeading) {
                                    NavigationLink {
                                        CourseDetailView(course: course, openPaywall: { showingPaywall = true })
                                    } label: {
                                        AcademyCourseCard(course: course, paletteIndex: index)
                                            .accessibilityIdentifier("Course.catalog.item.\(course.id)")
                                    }
                                    .buttonStyle(.plain)

                                    if isDev {
                                        Button {
                                            editorTarget = .edit(course)
                                        } label: {
                                            Image(systemName: "pencil")
                                                .font(.system(size: 14, weight: .bold))
                                                .foregroundColor(.black)
                                                .frame(width: 36, height: 36)
                                                .background(Color.accentColor)
                                                .clipShape(Circle())
                                                .shadow(color: .black.opacity(0.4), radius: 6)
                                        }
                                        .buttonStyle(.plain)
                                        .padding(12)
                                        .accessibilityLabel("Редактировать курс")
                                    }
                                }
                                .contextMenu {
                                    if isDev {
                                        Button {
                                            editorTarget = .edit(course)
                                        } label: {
                                            Label("Редактировать", systemImage: "pencil")
                                        }
                                        Button(role: .destructive) {
                                            Task {
                                                guard let token = await auth.freshAccessToken() else { return }
                                                _ = await service.deleteCourse(id: course.id, accessToken: token)
                                                await reloadCourses()
                                            }
                                        } label: {
                                            Label("Удалить", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 2)
                        .padding(.bottom, 32)
                        .frame(maxWidth: 640)
                        .frame(maxWidth: .infinity)
                    }
                    .refreshable { await reloadCourses() }
                }
            }
            .background { X5Background() }
            .navigationTitle("CourseUP")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                if isDev {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showingSubmissions = true
                        } label: {
                            Label("Заявки", systemImage: "tray.full")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            editorTarget = .create
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "plus")
                                Text(loc.t("courses_create_btn")).bold()
                            }
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color.accentColor)
                            .clipShape(Capsule())
                        }
                    }
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showingCourseSubmission = true } label: {
                            Text("Оставить заявку")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.black)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Color.accentColor)
                                .clipShape(Capsule())
                        }
                    }
                }
            }
            .sheet(isPresented: $showingPaywall) { PaywallView() }
            .sheet(isPresented: $showingCourseSubmission) {
                CourseSubmissionView()
            }
            .sheet(isPresented: $showingSubmissions) {
                CourseSubmissionsAdminView()
            }
            .sheet(item: $editorTarget) { target in
                switch target {
                case .create:
                    CourseEditorView(editing: nil) {
                        Task { await reloadCourses() }
                    }
                case .edit(let course):
                    CourseEditorView(editing: course) {
                        Task { await reloadCourses() }
                    }
                }
            }
            .task { await reloadCourses() }
        }
    }

    private func reloadCourses() async {
        let accessToken = isDev ? await auth.freshAccessToken() : nil
        await service.loadCourses(includeHidden: isDev, accessToken: accessToken)
    }

}

private struct CourseAuthorLine: View {
    let authorName: String?
    let authorId: String?
    var compact = false

    init(authorName: String?, authorId: String? = nil, compact: Bool = false) {
        self.authorName = authorName
        self.authorId = authorId
        self.compact = compact
    }

    private var cleanName: String? {
        let value = (authorName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private var cleanAuthorId: String? {
        let value = (authorId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    @ViewBuilder
    var body: some View {
        if let cleanName {
            if let authorId = cleanAuthorId {
                NavigationLink {
                    UserProfileView(userId: authorId, fallback: nil)
                } label: {
                    content(cleanName)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Открыть профиль автора")
            } else {
                content(cleanName)
            }
        }
    }

    private func content(_ name: String) -> some View {
        HStack(spacing: compact ? 4 : 6) {
            Image(systemName: "person.crop.circle.fill")
            Text("Автор: \(name)")
                .lineLimit(1)
        }
        .font(.system(size: compact ? 10 : 12, weight: .semibold))
        .foregroundColor(.white.opacity(compact ? 0.46 : 0.58))
        .accessibilityElement(children: .combine)
    }
}

/// Big card with cover image taking ~50% of card height — matches web Академия style.
private struct CourseCard: View {
    let course: Course
    var showHiddenBadge: Bool = false
    @EnvironmentObject private var loc: LocalizationService

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                LinearGradient(colors: [Color.purple.opacity(0.6), Color.pink.opacity(0.6)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                if let cover = course.coverUrl, !cover.isEmpty, let url = URL(string: cover) {
                    CachedAsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: "graduationcap")
                            .font(.system(size: 40, weight: .light))
                            .foregroundColor(.white.opacity(0.7))
                    }
                } else {
                    Image(systemName: "play.circle")
                        .font(.system(size: 60, weight: .ultraLight))
                        .foregroundColor(.white.opacity(0.85))
                }
            }
            .frame(height: 220)
            .clipped()
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 6) {
                    if showHiddenBadge {
                        Text(loc.t("courses_draft"))
                            .font(.system(size: 10, weight: .heavy))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.white.opacity(0.86))
                            .foregroundColor(.black)
                            .clipShape(Capsule())
                    }
                    if !(course.isFree ?? false) && (course.price ?? 0) > 0 {
                        Text("\(max(course.price ?? 0, 0).formatted()) кр.")
                            .font(.system(size: 10, weight: .heavy))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.accentColor)
                            .foregroundColor(.black)
                            .clipShape(Capsule())
                    }
                }
                .padding(12)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(course.title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)

                CourseAuthorLine(authorName: course.authorName, authorId: course.authorId)

                if let desc = course.description, !desc.isEmpty {
                    Text(desc)
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.55))
                        .lineLimit(2)
                }

                HStack(spacing: 14) {
                    HStack(spacing: 5) {
                        Image(systemName: "book").font(.system(size: 11))
                        Text("\(course.totalLessons) уроков").font(.system(size: 12))
                    }.foregroundColor(.white.opacity(0.5))

                    if let students = course.studentsCount, students > 0 {
                        HStack(spacing: 5) {
                            Image(systemName: "person.2").font(.system(size: 11))
                            Text("\(students)").font(.system(size: 12))
                        }.foregroundColor(.white.opacity(0.5))
                    }

                    Spacer()

                    ZStack {
                        Circle().fill(Color.accentColor)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.black)
                    }
                    .frame(width: 36, height: 36)
                }
            }
            .padding(14)
        }
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct CourseRow: View {
    let course: Course
    @EnvironmentObject private var loc: LocalizationService

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                if let cover = course.coverUrl, !cover.isEmpty, let url = URL(string: cover) {
                    CachedAsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: "graduationcap")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(.accentColor)
                    }
                } else {
                    Image(systemName: "graduationcap")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.accentColor)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(course.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                    if !(course.isFree ?? false) && (course.price ?? 0) > 0 {
                        Text("\(max(course.price ?? 0, 0).formatted()) кр.")
                            .font(.system(size: 9, weight: .heavy))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.accentColor)
                            .foregroundColor(.black)
                            .clipShape(Capsule())
                    }
                }
                CourseAuthorLine(
                    authorName: course.authorName,
                    authorId: course.authorId,
                    compact: true
                )
                if let summary = course.description, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.55))
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    Text("\(course.totalLessons) \(loc.t("courses_lessons_word"))")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                    if let r = course.averageRating, r > 0 {
                        Text("·")
                            .foregroundColor(.white.opacity(0.3))
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill").font(.system(size: 9)).foregroundColor(X5Style.blueSoft)
                            Text(String(format: "%.1f", r)).font(.system(size: 11)).foregroundColor(.white.opacity(0.55))
                        }
                    }
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.35))
        }
        .padding(14)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct UpcomingCourseCard: View {
    let course: Course

    private var accent: Color {
        switch course.id {
        case "upcoming-vibecoding": return X5Style.blue
        case "upcoming-ai-reels": return Color.purple
        case "upcoming-marketplace": return Color.cyan
        case "upcoming-smm-system": return Color.green
        case "upcoming-youtube": return Color.red
        case "upcoming-target-analytics": return Color.orange
        default: return Color.accentColor
        }
    }

    private var icon: String {
        switch course.id {
        case "upcoming-vibecoding": return "curlybraces"
        case "upcoming-ai-reels": return "play.rectangle.on.rectangle"
        case "upcoming-marketplace": return "shippingbox"
        case "upcoming-smm-system": return "calendar.badge.clock"
        case "upcoming-youtube": return "rectangle.on.rectangle"
        case "upcoming-target-analytics": return "scope"
        default: return "graduationcap"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    colors: [
                        accent.opacity(0.34),
                        Color(red: 0.03, green: 0.04, blue: 0.07),
                        Color.black.opacity(0.94)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                HStack(alignment: .center, spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(accent.opacity(0.18))
                        Image(systemName: icon)
                            .font(.system(size: 36, weight: .bold))
                            .foregroundColor(accent)
                    }
                    .frame(width: 84, height: 84)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("COURSEUP")
                            .font(.system(size: 11, weight: .heavy))
                            .tracking(2.2)
                            .foregroundColor(.white.opacity(0.45))

                        Text(course.title)
                            .font(.system(size: 23, weight: .heavy))
                            .foregroundColor(.white)
                            .lineLimit(2)
                            .minimumScaleFactor(0.82)

                        Text("В разработке")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundColor(.black)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.accentColor)
                            .clipShape(Capsule())
                    }
                    Spacer(minLength: 0)
                }
                .padding(18)
            }
            .frame(height: 154)

            VStack(alignment: .leading, spacing: 10) {
                if let desc = course.description, !desc.isEmpty {
                    Text(desc)
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.62))
                        .lineLimit(2)
                }

                HStack(spacing: 14) {
                    Label("\(course.totalLessons) урока", systemImage: "book")
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.black)
                        .frame(width: 36, height: 36)
                        .background(Color.accentColor)
                        .clipShape(Circle())
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.48))
            }
            .padding(16)
        }
        .background(Color.white.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct AcademyCourseCard: View {
    let course: Course
    let paletteIndex: Int

    private var palette: [Color] {
        let palettes: [[Color]] = [
            [Color(red: 0.17, green: 0.44, blue: 1.0), Color(red: 0.17, green: 0.93, blue: 0.96)],
            [Color(red: 0.07, green: 0.86, blue: 0.42), Color(red: 0.05, green: 0.65, blue: 0.58)],
            [Color(red: 0.98, green: 0.34, blue: 0.57), Color(red: 0.96, green: 0.75, blue: 0.24)],
            [Color(red: 0.48, green: 0.37, blue: 0.96), Color(red: 0.28, green: 0.13, blue: 0.55)],
            [Color(red: 0.95, green: 0.31, blue: 0.82), Color(red: 0.67, green: 0.12, blue: 0.24)]
        ]
        return palettes[paletteIndex % palettes.count]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)

                if let cover = course.coverUrl, !cover.isEmpty, let url = URL(string: cover) {
                    CachedAsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.clear
                    }
                    .overlay(Color.black.opacity(0.10))
                }

                Circle()
                    .fill(.white.opacity(0.18))
                    .frame(width: 64, height: 64)
                    .overlay(
                        Circle()
                            .stroke(.white.opacity(0.28), lineWidth: 1)
                    )
                Image(systemName: "play.circle")
                    .font(.system(size: 31, weight: .light))
                    .foregroundColor(.white.opacity(0.9))
            }
            .frame(height: 210)
            .frame(maxWidth: .infinity)
            .clipped()

            VStack(alignment: .leading, spacing: 13) {
                Text(course.title)
                    .font(.system(size: 21, weight: .heavy))
                    .foregroundColor(.white)
                    .lineLimit(2)

                CourseAuthorLine(authorName: course.authorName, authorId: course.authorId)

                if let desc = course.description, !desc.isEmpty {
                    Text(desc)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white.opacity(0.56))
                        .lineSpacing(3)
                        .lineLimit(2)
                }

                HStack(spacing: 16) {
                    Label("\(course.totalLessons) уроков", systemImage: "book")
                    if let students = course.studentsCount, students >= 0 {
                        Label("\(students)", systemImage: "person.2")
                    }
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.system(size: 18, weight: .black))
                        .foregroundColor(.black)
                        .frame(width: 48, height: 48)
                        .background(Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.42))
            }
            .padding(18)
            .background(
                LinearGradient(
                    colors: [Color.white.opacity(0.070), Color.white.opacity(0.038)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        .background(Color(red: 0.08, green: 0.085, blue: 0.13))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 12)
    }

}

struct CourseInDevelopmentView: View {
    let course: Course
    @State private var expandedCategoryIds: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("CourseUP")
                        .font(.system(size: 12, weight: .heavy))
                        .tracking(2)
                        .foregroundColor(.accentColor)

                    Text(course.title)
                        .font(.system(size: 32, weight: .heavy))
                        .foregroundColor(.white)
                        .fixedSize(horizontal: false, vertical: true)

                    if let desc = course.description, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 15))
                            .foregroundColor(.white.opacity(0.66))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.20), Color.white.opacity(0.055)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

                HStack(spacing: 12) {
                    Image(systemName: "hammer.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.black)
                        .frame(width: 48, height: 48)
                        .background(Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Курс в разработке")
                            .font(.system(size: 18, weight: .heavy))
                            .foregroundColor(.white)
                        Text("Скоро добавим уроки, видео и материалы.")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.58))
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.055))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                programHeader

                ForEach(sortedCategories) { category in
                    CourseProgramCategorySection(
                        category: category,
                        isExpanded: categoryBinding(category.id)
                    ) { lesson in
                        LockedSoonLessonRow(lesson: lesson)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 32)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(Color(red: 0.04, green: 0.05, blue: 0.10).ignoresSafeArea())
        .navigationTitle("В разработке")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear { expandAllIfNeeded() }
    }

    private var sortedCategories: [CourseCategory] {
        course.categories.sorted { ($0.order ?? 0) < ($1.order ?? 0) }
    }

    private var allCategoryIds: Set<String> {
        Set(sortedCategories.map(\.id))
    }

    private var isFullyExpanded: Bool {
        !allCategoryIds.isEmpty && expandedCategoryIds == allCategoryIds
    }

    private var programHeader: some View {
        HStack {
            Text("Программа")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.4)
                .foregroundColor(.white.opacity(0.45))
            Spacer()
            Button(isFullyExpanded ? "Свернуть все" : "Развернуть все") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isFullyExpanded {
                        expandedCategoryIds.removeAll()
                    } else {
                        expandedCategoryIds = allCategoryIds
                    }
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.accentColor)
        }
    }

    private func expandAllIfNeeded() {
        guard expandedCategoryIds.isEmpty else { return }
        expandedCategoryIds = allCategoryIds
    }

    private func categoryBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { expandedCategoryIds.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    expandedCategoryIds.insert(id)
                } else {
                    expandedCategoryIds.remove(id)
                }
            }
        )
    }
}

struct CourseDetailView: View {
    let course: Course
    var openPaywall: () -> Void

    @EnvironmentObject private var auth: Auth
    @EnvironmentObject private var currentUser: CurrentUser
    @EnvironmentObject private var loc: LocalizationService
    @StateObject private var purchaseService = CoursePurchaseService()
    @State private var expandedCategoryIds: Set<String> = []
    @State private var showingPurchaseConfirmation = false
    @State private var purchaseNotice: CoursePurchaseNotice?
    @State private var serverConfirmedPrice: Int?
    @State private var lessonToBuy: CourseLesson?
    /// Prices the server corrected mid-flight, keyed by lesson id, so the next
    /// confirmation shows the amount that will actually be charged.
    @State private var serverConfirmedLessonPrices: [String: Int] = [:]

    private var activeProfile: UserProfile? {
        guard let profile = currentUser.profile,
              let userId = auth.userId,
              profile.id.caseInsensitiveCompare(userId) == .orderedSame
        else { return nil }
        return profile
    }

    var hasFullAccess: Bool {
        CourseAccessPolicy.hasFullAccess(to: course, profile: activeProfile)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let cover = course.coverUrl, !cover.isEmpty, let url = URL(string: cover) {
                    CachedAsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.white.opacity(0.05)
                    }
                    .frame(height: 180)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                Text(course.title)
                    .font(.system(size: 26, weight: .heavy))
                    .foregroundColor(.white)

                CourseAuthorLine(authorName: course.authorName, authorId: course.authorId)

                if let hook = course.marketingHook, !hook.isEmpty {
                    Text(hook)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.accentColor)
                }
                if let desc = course.description, !desc.isEmpty {
                    Text(desc)
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 12) {
                    StatBubble(value: "\(course.totalLessons)", label: "lessons")
                    if let r = course.averageRating, r > 0 {
                        StatBubble(value: String(format: "%.1f ⭐", r), label: "\(course.studentsCount ?? 0) students")
                    }
                }

                if !hasFullAccess {
                    purchaseButton
                }

                lessonsHeader
                    .padding(.top, 8)

                ForEach(sortedCategories) { category in
                    CourseProgramCategorySection(
                        category: category,
                        isExpanded: categoryBinding(category.id)
                    ) { lesson in
                        LessonRow(
                            lesson: lesson,
                            courseID: course.id,
                            canPlay: CourseAccessPolicy.canAccess(
                                lesson: lesson,
                                in: course,
                                profile: activeProfile
                            ),
                            separatePrice: separatePrice(for: lesson),
                            requestUnlock: { requestUnlock(lesson: lesson) }
                        )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(Color(red: 0.04, green: 0.05, blue: 0.10).ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear { expandAllIfNeeded() }
        .confirmationDialog(
            "Купить курс?",
            isPresented: $showingPurchaseConfirmation,
            titleVisibility: .visible
        ) {
            Button("Купить за \(formattedPrice) кредитов") {
                Task { await completePurchase() }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Баланс: \(formattedCredits) кредитов. Списание и выдача доступа выполняются одной операцией.")
        }
        .confirmationDialog(
            "Купить только этот урок?",
            isPresented: Binding(
                get: { lessonToBuy != nil },
                set: { if !$0 { lessonToBuy = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let lesson = lessonToBuy {
                Button("Купить за \(lessonPrice(for: lesson).formatted()) кредитов") {
                    Task { await completeLessonPurchase(lesson) }
                }
            }
            Button("Отмена", role: .cancel) { lessonToBuy = nil }
        } message: {
            if let lesson = lessonToBuy {
                Text("\(lesson.title)\nБаланс: \(formattedCredits) кредитов. Откроется только этот урок, остальной курс останется закрытым.")
            }
        }
        .alert(item: $purchaseNotice) { notice in
            notice.makeAlert(openTopUp: openPaywall)
        }
    }

    private var coursePrice: Int { max(serverConfirmedPrice ?? course.price ?? 0, 0) }
    private var availableCredits: Int { max(activeProfile?.credits ?? 0, 0) }
    private var formattedPrice: String { coursePrice.formatted() }
    private var formattedCredits: String { availableCredits.formatted() }

    private var purchaseButton: some View {
        Button(action: { requestUnlock() }) {
            HStack(spacing: 12) {
                if purchaseService.isPurchasing {
                    ProgressView()
                        .tint(.black)
                } else {
                    Image(systemName: "creditcard.fill")
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Купить курс · \(formattedPrice) кредитов")
                        .font(.system(size: 15, weight: .bold))
                    Text("Баланс: \(formattedCredits)")
                        .font(.system(size: 11, weight: .semibold))
                        .opacity(0.68)
                }
                Spacer()
            }
            .foregroundColor(.black)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(Color.accentColor)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .disabled(purchaseService.isPurchasing)
        .accessibilityHint("Открывает подтверждение покупки этого курса за кредиты")
    }

    /// Price of a lesson that may be bought on its own, or nil when it only
    /// unlocks with the whole course. Already-owned lessons show no price.
    private func separatePrice(for lesson: CourseLesson) -> Int? {
        guard !hasFullAccess,
              CourseAccessPolicy.isSoldSeparately(lesson),
              !CourseAccessPolicy.hasPurchasedLesson(lesson, in: course, profile: activeProfile)
        else { return nil }
        return lessonPrice(for: lesson)
    }

    private func lessonPrice(for lesson: CourseLesson) -> Int {
        max(serverConfirmedLessonPrices[lesson.id] ?? lesson.price ?? 0, 0)
    }

    private func requestUnlock() {
        requestUnlock(lesson: nil)
    }

    /// A locked lesson that the author sells on its own offers exactly that
    /// lesson; anything else falls back to buying the course.
    private func requestUnlock(lesson: CourseLesson?) {
        guard auth.isAuthenticated else {
            purchaseNotice = CoursePurchaseNotice(
                title: "Нужен вход",
                message: "Войдите в Xfive marketing, чтобы купить курс.",
                offersTopUp: false
            )
            return
        }

        if let lesson, separatePrice(for: lesson) != nil {
            lessonToBuy = lesson
            return
        }

        showingPurchaseConfirmation = true
    }

    @MainActor
    private func completePurchase() async {
        guard let profileOperation = currentUser.operationContext() else { return }
        guard let token = await currentUser.accessTokenForOperation(profileOperation, refresh: {
            await auth.freshAccessToken()
        }) else {
            purchaseNotice = CoursePurchaseNotice(
                title: "Сессия истекла",
                message: "Войдите снова и повторите покупку.",
                offersTopUp: false
            )
            return
        }

        guard currentUser.isCurrent(profileOperation) else { return }
        do {
            let response = try await purchaseService.purchase(
                courseId: course.id,
                expectedPrice: coursePrice,
                accessToken: token,
                refreshAccessToken: {
                    await currentUser.accessTokenForOperation(profileOperation, refresh: {
                        await auth.accessTokenAfterUnauthorized(
                            rejectedAccessToken: token,
                            expectedUserId: profileOperation.userID
                        )
                    })
                }
            )
            guard currentUser.isCurrent(profileOperation) else { return }
            currentUser.applyCoursePurchase(response, for: profileOperation)

            switch response.status {
            case .purchased:
                purchaseNotice = CoursePurchaseNotice(
                    title: "Курс куплен",
                    message: "Доступ ко всем урокам открыт.",
                    offersTopUp: false
                )
            case .alreadyOwned:
                purchaseNotice = CoursePurchaseNotice(
                    title: "Курс уже доступен",
                    message: "Повторного списания не было.",
                    offersTopUp: false
                )
            case .insufficientCredits:
                purchaseNotice = CoursePurchaseNotice(
                    title: "Недостаточно кредитов",
                    message: "Баланс изменился. Пополните его и повторите покупку.",
                    offersTopUp: true
                )
            case .priceChanged:
                let latestPrice = response.reconciledExpectedPrice(currentPrice: coursePrice)
                serverConfirmedPrice = latestPrice
                purchaseNotice = CoursePurchaseNotice(
                    title: "Цена изменилась",
                    message: "Списание не выполнялось. Новая цена — \(latestPrice.formatted()) кредитов. Нажмите купить ещё раз и подтвердите новую цену.",
                    offersTopUp: false
                )
            case .courseUnavailable, .lessonUnavailable:
                purchaseNotice = CoursePurchaseNotice(
                    title: "Курс недоступен",
                    message: "Обновите список курсов и попробуйте позже.",
                    offersTopUp: false
                )
            case .profileUnavailable:
                purchaseNotice = CoursePurchaseNotice(
                    title: "Профиль не готов",
                    message: "Перезапустите приложение или войдите снова.",
                    offersTopUp: false
                )
            case .notAuthenticated:
                purchaseNotice = CoursePurchaseNotice(
                    title: "Нужен вход",
                    message: "Войдите снова и повторите покупку.",
                    offersTopUp: false
                )
            case .unknown(let status):
                purchaseNotice = CoursePurchaseNotice(
                    title: "Покупка не завершена",
                    message: "Сервер вернул статус: \(status).",
                    offersTopUp: false
                )
            }

            if response.grantsOwnership,
               let userId = auth.userId,
               let refreshedToken = await auth.freshAccessToken() {
                await currentUser.load(userId: userId, accessToken: refreshedToken)
            }
        } catch {
            purchaseNotice = CoursePurchaseNotice(
                title: "Покупка не выполнена",
                message: purchaseService.error ?? error.localizedDescription,
                offersTopUp: false
            )
        }
    }

    @MainActor
    private func completeLessonPurchase(_ lesson: CourseLesson) async {
        lessonToBuy = nil
        let confirmedPrice = lessonPrice(for: lesson)

        guard let profileOperation = currentUser.operationContext() else { return }
        guard let token = await currentUser.accessTokenForOperation(profileOperation, refresh: {
            await auth.freshAccessToken()
        }) else {
            purchaseNotice = CoursePurchaseNotice(
                title: "Сессия истекла",
                message: "Войдите снова и повторите покупку.",
                offersTopUp: false
            )
            return
        }

        guard currentUser.isCurrent(profileOperation) else { return }
        do {
            let response = try await purchaseService.purchaseLesson(
                courseId: course.id,
                lessonId: lesson.id,
                expectedPrice: confirmedPrice,
                accessToken: token,
                refreshAccessToken: {
                    await currentUser.accessTokenForOperation(profileOperation, refresh: {
                        await auth.accessTokenAfterUnauthorized(
                            rejectedAccessToken: token,
                            expectedUserId: profileOperation.userID
                        )
                    })
                }
            )
            guard currentUser.isCurrent(profileOperation) else { return }
            currentUser.applyLessonPurchase(response, for: profileOperation)

            switch response.status {
            case .purchased:
                purchaseNotice = CoursePurchaseNotice(
                    title: "Урок куплен",
                    message: "«\(lesson.title)» открыт. Остальные уроки курса остались закрытыми.",
                    offersTopUp: false
                )
            case .alreadyOwned:
                purchaseNotice = CoursePurchaseNotice(
                    title: "Урок уже доступен",
                    message: "Повторного списания не было.",
                    offersTopUp: false
                )
            case .insufficientCredits:
                purchaseNotice = CoursePurchaseNotice(
                    title: "Недостаточно кредитов",
                    message: "Баланс изменился. Пополните его и повторите покупку.",
                    offersTopUp: true
                )
            case .priceChanged:
                let latestPrice = response.reconciledExpectedPrice(currentPrice: confirmedPrice)
                serverConfirmedLessonPrices[lesson.id] = latestPrice
                purchaseNotice = CoursePurchaseNotice(
                    title: "Цена изменилась",
                    message: "Списание не выполнялось. Новая цена — \(latestPrice.formatted()) кредитов. Нажмите на урок ещё раз и подтвердите новую цену.",
                    offersTopUp: false
                )
            case .lessonUnavailable:
                purchaseNotice = CoursePurchaseNotice(
                    title: "Урок нельзя купить отдельно",
                    message: "Автор больше не продаёт его отдельно. Доступ открывается покупкой всего курса.",
                    offersTopUp: false
                )
            case .courseUnavailable:
                purchaseNotice = CoursePurchaseNotice(
                    title: "Курс недоступен",
                    message: "Обновите список курсов и попробуйте позже.",
                    offersTopUp: false
                )
            case .profileUnavailable:
                purchaseNotice = CoursePurchaseNotice(
                    title: "Профиль не готов",
                    message: "Перезапустите приложение или войдите снова.",
                    offersTopUp: false
                )
            case .notAuthenticated:
                purchaseNotice = CoursePurchaseNotice(
                    title: "Нужен вход",
                    message: "Войдите снова и повторите покупку.",
                    offersTopUp: false
                )
            case .unknown(let status):
                purchaseNotice = CoursePurchaseNotice(
                    title: "Покупка не завершена",
                    message: "Сервер вернул статус: \(status).",
                    offersTopUp: false
                )
            }

            if response.grantsOwnership,
               let userId = auth.userId,
               let refreshedToken = await auth.freshAccessToken() {
                await currentUser.load(userId: userId, accessToken: refreshedToken)
            }
        } catch {
            purchaseNotice = CoursePurchaseNotice(
                title: "Покупка не выполнена",
                message: purchaseService.error ?? error.localizedDescription,
                offersTopUp: false
            )
        }
    }

    private var sortedCategories: [CourseCategory] {
        course.categories.sorted { ($0.order ?? 0) < ($1.order ?? 0) }
    }

    private var allCategoryIds: Set<String> {
        Set(sortedCategories.map(\.id))
    }

    private var isFullyExpanded: Bool {
        !allCategoryIds.isEmpty && expandedCategoryIds == allCategoryIds
    }

    private var lessonsHeader: some View {
        HStack {
            Text(loc.t("courses_lessons_section"))
                .font(.system(size: 11, weight: .bold))
                .tracking(1.4)
                .foregroundColor(.white.opacity(0.45))
            Spacer()
            Button(isFullyExpanded ? "Свернуть все" : "Развернуть все") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isFullyExpanded {
                        expandedCategoryIds.removeAll()
                    } else {
                        expandedCategoryIds = allCategoryIds
                    }
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.accentColor)
        }
    }

    private func expandAllIfNeeded() {
        guard expandedCategoryIds.isEmpty else { return }
        expandedCategoryIds = allCategoryIds
    }

    private func categoryBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { expandedCategoryIds.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    expandedCategoryIds.insert(id)
                } else {
                    expandedCategoryIds.remove(id)
                }
            }
        )
    }
}

private struct CoursePurchaseNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let offersTopUp: Bool

    func makeAlert(openTopUp: @escaping () -> Void) -> Alert {
        if offersTopUp {
            return Alert(
                title: Text(title),
                message: Text(message),
                primaryButton: .default(Text("Пополнить"), action: openTopUp),
                secondaryButton: .cancel(Text("Отмена"))
            )
        }
        return Alert(
            title: Text(title),
            message: Text(message),
            dismissButton: .default(Text("OK"))
        )
    }
}

private struct StatBubble: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 14, weight: .bold)).foregroundColor(.white)
            Text(label).font(.system(size: 10)).foregroundColor(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct CourseProgramCategorySection<LessonContent: View>: View {
    let category: CourseCategory
    let isExpanded: Binding<Bool>
    @ViewBuilder let lessonContent: (CourseLesson) -> LessonContent

    private var lessonsCount: Int {
        category.days.reduce(0) { $0 + $1.lessons.count }
    }

    private var sortedDays: [CourseDay] {
        category.days.sorted { ($0.order ?? 0) < ($1.order ?? 0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: isExpanded.wrappedValue ? "chevron.down.circle.fill" : "chevron.right.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.accentColor)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(category.title)
                            .font(.system(size: 17, weight: .heavy))
                            .foregroundColor(.white)
                        Text("\(lessonsCount) уроков")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.45))
                    }

                    Spacer()
                }
                .padding(14)
                .background(Color.white.opacity(0.055))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)

            if isExpanded.wrappedValue {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(sortedDays) { day in
                        VStack(alignment: .leading, spacing: 8) {
                            if !day.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(day.title)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.white.opacity(0.68))
                                    .padding(.horizontal, 4)
                            }

                            ForEach(day.lessons.sorted { ($0.order ?? 0) < ($1.order ?? 0) }) { lesson in
                                lessonContent(lesson)
                            }
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

private struct LockedSoonLessonRow: View {
    let lesson: CourseLesson

    var body: some View {
        HStack(spacing: 12) {
            lessonThumbnail

            Text(lesson.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.82))
                .lineLimit(2)

            Spacer()

            Text("скоро")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.36))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var lessonThumbnail: some View {
        if let url = lesson.safeThumbnailURL {
            ZStack {
                CachedAsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.06)
                }
                Color.black.opacity(0.24)
                Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(0.82))
            }
            .frame(width: 58, height: 38)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        } else {
            ZStack {
                Circle().fill(Color.white.opacity(0.06))
                Image(systemName: "lock.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white.opacity(0.38))
            }
            .frame(width: 32, height: 32)
        }
    }
}

private struct LessonRow: View {
    let lesson: CourseLesson
    let courseID: String
    let canPlay: Bool
    /// Price to show when this single lesson can be bought on its own. Nil when
    /// the lesson only comes with the whole course.
    var separatePrice: Int? = nil
    let requestUnlock: () -> Void
    @EnvironmentObject private var loc: LocalizationService
    @EnvironmentObject private var auth: Auth
    @State private var bunnyThumbnailURL: URL?

    var hasVideo: Bool { lesson.hasAnyVideo }

    /// Обложка урока: своя (thumbnailUrl) или авто-превью Bunny.
    private var coverURL: URL? { lesson.safeThumbnailURL ?? bunnyThumbnailURL }

    /// Большая карточка 16:9 — когда обложка есть или может прийти от Bunny.
    /// Раньше обложка была 58×38 и текст на ней не читался (Адильхан).
    private var showsCoverCard: Bool {
        lesson.safeThumbnailURL != nil || lesson.bunnyVideoID != nil
    }

    private var statusIcon: String {
        !hasVideo ? "doc.text" : (canPlay ? "play.fill" : "lock.fill")
    }

    var body: some View {
        Group {
            if canPlay && hasVideo {
                NavigationLink {
                    LessonPlayerView(lesson: lesson, courseID: courseID)
                } label: { content }
                .buttonStyle(.plain)
            } else {
                Button(action: { if !canPlay { requestUnlock() } }) { content }
                    .buttonStyle(.plain)
            }
        }
        .task(id: lesson.id) { await loadBunnyThumbnailIfNeeded() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsCoverCard {
                coverCard
            }

            HStack(spacing: 12) {
                if !showsCoverCard {
                    compactIcon
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(lesson.title)
                        .font(.system(size: showsCoverCard ? 15 : 14, weight: showsCoverCard ? .semibold : .regular))
                        .foregroundColor(.white)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        if lesson.freePreview {
                            Text(loc.t("courses_free_preview"))
                                .font(.system(size: 9, weight: .heavy))
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(X5Style.blue.opacity(0.18))
                                .foregroundColor(.accentColor)
                                .clipShape(Capsule())
                        }
                        if let separatePrice {
                            Text(loc.t("courses_lesson_price_badge")
                                .replacingOccurrences(of: "{price}", with: separatePrice.formatted()))
                                .font(.system(size: 9, weight: .heavy))
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.18))
                                .foregroundColor(.accentColor)
                                .clipShape(Capsule())
                        }
                    }
                }
                Spacer()
                if canPlay && hasVideo {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.3))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Обложка во всю ширину строки, 16:9 (как кадр видео), те же цвета
    /// и скругления, что были у мини-превью. Пока грузится / не загрузилась /
    /// у Bunny ещё нет кадра — аккуратная заглушка, а не пустой прямоугольник.
    private var coverCard: some View {
        Color.clear
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay {
                if let url = coverURL {
                    CachedAsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        coverPlaceholder
                    }
                } else {
                    coverPlaceholder
                }
            }
            .overlay {
                LinearGradient(colors: [.black.opacity(0.04), .black.opacity(0.34)], startPoint: .top, endPoint: .bottom)
            }
            .overlay {
                Image(systemName: statusIcon)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(canPlay ? .black : .white.opacity(0.82))
                    .frame(width: 44, height: 44)
                    .background(canPlay ? Color.accentColor : Color.white.opacity(0.14))
                    .clipShape(Circle())
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var coverPlaceholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color.white.opacity(0.08), Color.white.opacity(0.03)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "film")
                .font(.system(size: 28, weight: .regular))
                .foregroundColor(.white.opacity(0.16))
        }
    }

    private var compactIcon: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.06))
            Image(systemName: statusIcon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(canPlay ? .accentColor : .white.opacity(0.45))
        }
        .frame(width: 32, height: 32)
    }

    /// Bunny-урок без своей обложки: берём авто-кадр Bunny (подписанная
    /// ссылка из course-video-playback). Только для открытых уроков — для
    /// закрытых сервер всё равно ответит 403, лишний запрос не шлём.
    // идея: кэшировать превью по videoID без токена в ссылке, чтобы не
    // перекачивать картинку при каждом входе в курс.
    @MainActor
    private func loadBunnyThumbnailIfNeeded() async {
        guard bunnyThumbnailURL == nil,
              lesson.safeThumbnailURL == nil,
              lesson.bunnyVideoID != nil,
              canPlay
        else { return }
        let token = await auth.freshAccessToken(
            invalidateSessionOnCredentialFailure: false
        )
        let url = await CourseVideoPlaybackClient(
            baseURL: X5Config.supabaseBaseURL,
            anonKey: X5Config.supabaseAnonKey
        ).fetchThumbnailURL(
            courseID: courseID,
            lessonID: lesson.id,
            accessToken: token
        )
        if let url { bunnyThumbnailURL = url }
    }
}

private extension CourseLesson {
    var safeThumbnailURL: URL? {
        guard let raw = thumbnailUrl, !raw.isEmpty, let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        return url
    }
}

private struct CourseSubmissionView: View {
    @EnvironmentObject private var auth: Auth
    @EnvironmentObject private var currentUser: CurrentUser
    @Environment(\.dismiss) private var dismiss
    @StateObject private var service = CoursesService()

    @State private var title = ""
    @State private var description = ""
    @State private var contact = ""
    @State private var videoFileURL: URL?
    @State private var videoFileName: String?
    @State private var showingVideoPicker = false
    @State private var isImportingVideo = false
    @State private var isSending = false
    @State private var message: String?

    private var canSend: Bool {
        !title.x5Trimmed.isEmpty && !description.x5Trimmed.isEmpty && !contact.x5Trimmed.isEmpty && videoFileURL != nil && !isImportingVideo && !isSending
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Название курса", text: $title)
                        .textInputAutocapitalization(.sentences)
                    TextField("Что будет в курсе", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                    TextField("Контакт для связи", text: $contact)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                } header: {
                    Text("Заявка на курс")
                } footer: {
                    Text("Опиши идею курса и прикрепи первое видео. Команда Xfive marketing проверит заявку и свяжется с тобой.")
                }

                Section("Видео") {
                    Button {
                        isImportingVideo = true
                        showingVideoPicker = true
                    } label: {
                        Label(
                            isImportingVideo ? "Подготовка видео..." : (videoFileName == nil ? "Выбрать видео из галереи" : "Заменить видео из галереи"),
                            systemImage: "photo.on.rectangle.angled"
                        )
                    }
                    .disabled(isImportingVideo || isSending)

                    if let videoFileName {
                        Label(videoFileName, systemImage: "film")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if isSending, let progress = service.videoUploadProgress {
                        ProgressView(value: progress)
                            .tint(.accentColor)
                        // NaN/∞ в Int(...) = вылет — подстраховка.
                        Text("Загрузка видео: \(progress.isFinite ? Int((min(max(progress, 0), 1) * 100).rounded()) : 0)%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                if let message {
                    Section {
                        Text(message)
                            .foregroundColor(message.contains("отправлена") ? .green : .red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(red: 0.04, green: 0.05, blue: 0.10))
            .navigationTitle("Оставить заявку")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { cancelAndDismiss() }
                        .disabled(isImportingVideo || isSending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await send() }
                    } label: {
                        if isSending { ProgressView() } else { Text("Отправить").bold() }
                    }
                    .disabled(!canSend)
                }
            }
            .sheet(isPresented: $showingVideoPicker, onDismiss: {
                isImportingVideo = false
            }) {
                GalleryVideoPicker(
                    stagingID: "course-submission",
                    onResult: handleVideoPickerResult,
                    onCancel: {
                        isImportingVideo = false
                        showingVideoPicker = false
                    }
                )
                .ignoresSafeArea()
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(isImportingVideo || isSending)
        .onDisappear { CourseVideoStaging.removeIfManaged(videoFileURL) }
    }

    @MainActor
    private func handleVideoPickerResult(_ result: Result<CourseGalleryVideo, Error>) {
        isImportingVideo = false
        showingVideoPicker = false
        message = nil

        switch result {
        case .success(let imported):
            CourseVideoStaging.removeIfManaged(videoFileURL)
            videoFileURL = imported.fileURL
            videoFileName = imported.originalFileName
        case .failure(let error):
            message = "Не удалось подготовить видео из галереи: \(error.localizedDescription)"
        }
    }

    private func cancelAndDismiss() {
        CourseVideoStaging.removeIfManaged(videoFileURL)
        videoFileURL = nil
        dismiss()
    }

    private func send() async {
        guard !isSending else { return }
        guard let selectedVideoURL = videoFileURL else {
            message = "Нужно войти и прикрепить видео."
            return
        }
        isSending = true
        defer { isSending = false }

        guard let token = await auth.freshAccessToken(),
              let userID = auth.userId else {
            message = "Нужно войти и прикрепить видео."
            return
        }

        let uploadedVideo = await service.uploadCourseSubmissionVideo(
            fileURL: selectedVideoURL,
            userID: userID,
            accessToken: token,
            accessTokenProvider: {
                await auth.accessTokenForUpload()
            }
        )
        guard let uploadedVideo else {
            message = service.error ?? "Видео не загрузилось."
            return
        }

        guard let postUploadToken = await auth.accessTokenForUpload() else {
            message = "Сессия истекла во время загрузки. Войди снова."
            return
        }

        let ok = await service.createSubmission(
            title: title.x5Trimmed,
            description: description.x5Trimmed,
            contact: contact.x5Trimmed,
            authorId: auth.userId,
            authorEmail: auth.userEmail,
            authorName: currentUser.profile?.name ?? auth.userEmail,
            videoURL: uploadedVideo,
            accessToken: postUploadToken
        )

        if ok {
            X5Feedback.success()
            message = "Заявка отправлена. Проверим видео и напишем."
            CourseVideoStaging.removeIfManaged(selectedVideoURL)
            self.videoFileURL = nil
            try? await Task.sleep(nanoseconds: 700_000_000)
            dismiss()
        } else {
            X5Feedback.error()
            message = service.error ?? "Не удалось отправить заявку."
        }
    }
}

private struct CourseSubmissionsAdminView: View {
    @EnvironmentObject private var auth: Auth
    @Environment(\.dismiss) private var dismiss
    @StateObject private var service = CoursesService()

    var body: some View {
        NavigationStack {
            Group {
                if service.isLoadingSubmissions {
                    ProgressView().tint(.accentColor)
                } else if service.submissions.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tray")
                            .font(.system(size: 38, weight: .light))
                            .foregroundColor(.white.opacity(0.52))
                        Text("Заявок пока нет")
                            .font(.system(size: 20, weight: .heavy))
                            .foregroundColor(.white)
                        Text("Когда люди предложат курс, он появится здесь.")
                            .font(.system(size: 14, weight: .medium))
                            .multilineTextAlignment(.center)
                            .foregroundColor(.white.opacity(0.55))
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(service.submissions) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(item.title)
                                    .font(.headline)
                                Spacer()
                                Text((item.status ?? "new").uppercased())
                                    .font(.caption2.weight(.heavy))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.accentColor.opacity(0.18))
                                    .foregroundColor(.accentColor)
                                    .clipShape(Capsule())
                            }

                            if let description = item.description, !description.isEmpty {
                                Text(description)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            if let contact = item.contact, !contact.isEmpty {
                                Label(contact, systemImage: "at")
                                    .font(.caption)
                            }

                            if let email = item.authorEmail, !email.isEmpty {
                                Label(email, systemImage: "person")
                                    .font(.caption)
                            }

                            if let raw = item.videoUrl, let url = URL(string: raw) {
                                Link(destination: url) {
                                    Label("Открыть видео", systemImage: "play.rectangle")
                                }
                                .font(.caption.weight(.semibold))
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color(red: 0.04, green: 0.05, blue: 0.10))
            .navigationTitle("Заявки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
            .task {
                guard let token = await auth.freshAccessToken() else { return }
                await service.loadSubmissions(accessToken: token)
            }
        }
        .preferredColorScheme(.dark)
    }
}

private extension String {
    var x5Trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct ErrorState: View {
    let message: String
    let retry: () -> Void
    @EnvironmentObject private var loc: LocalizationService

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 38, weight: .light))
                .foregroundColor(.white.opacity(0.6))
            Text(loc.t("courses_load_failed"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Retry", action: retry)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.accentColor)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
