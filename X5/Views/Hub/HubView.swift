import SwiftUI

/// Hub — bottom tab matching web HireView. Two segmented sub-tabs:
/// Specialists (profiles where show_in_hub=true) and Tasks (open task marketplace).
struct HubView: View {
    enum Segment: String, CaseIterable, Identifiable {
        case specialists, tasks
        var id: String { rawValue }
    }

    @EnvironmentObject private var auth: Auth
    @EnvironmentObject private var currentUser: CurrentUser
    @EnvironmentObject private var loc: LocalizationService
    @StateObject private var service = HubService()
    @StateObject private var chats = ChatsService()
    @StateObject private var deepLinkRouter = AppDeepLinkRouter.shared
    @State private var segment: Segment = .specialists
    @State private var category: String? = nil
    @State private var taskBrowseState = HubTaskBrowseState()
    @State private var showingPostTask = false
    @State private var showingEditProfile = false
    @State private var openingChatWith: String? = nil
    @State private var startingChat: ChatRoom? = nil
    @State private var chatError: String? = nil
    @State private var selectedCountryCode: String = "KZ"
    @State private var selectedCity: String = ""
    @State private var didSeedLocation = false
    @State private var taskCategoriesExpanded = false
    @State private var deepLinkedTask: HubTask?
    @State private var taskOpenError: String?

    private var currentRole: String {
        (currentUser.profile?.userRole ?? "").lowercased()
    }

    private var canAddPortfolioFromHub: Bool {
        currentRole == "entrepreneur" || currentRole == "creator"
    }

    private var visibleTaskCategories: [HubCategory] {
        taskCategoriesExpanded
            ? HubCategories.hubDisplayOrder
            : Array(HubCategories.hubDisplayOrder.prefix(7))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                hubHeader

                Picker("", selection: $segment) {
                    ForEach(Segment.allCases) { s in
                        Text(s == .specialists ? loc.t("hub_specialists") : loc.t("hub_tasks")).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)

                if segment == .specialists {
                    if canAddPortfolioFromHub {
                        addPortfolioButton
                    }
                    countrySelector(messageKey: "hub_country_specialists")
                } else if segment == .tasks {
                    createTaskButton
                    countrySelector(messageKey: "hub_country_orders")
                    if taskBrowseState.isShowingResults {
                        categoryRail
                    }
                }

                Group {
                    switch segment {
                    case .specialists:
                        specialistsContent
                    case .tasks:
                        tasksList
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
            .background { X5Background() }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .task {
                chats.configureAccessTokenProvider(auth: auth)
                applyProfileCategoriesOnEntry()
                await repairCurrentHubProfileIfNeeded()
                seedLocationFromProfileIfNeeded()
                await service.loadSpecialists()
                await loadHubTasks()
                await openPendingTaskIfNeeded()
            }
            .onChange(of: currentUser.profile?.specialistCategory ?? []) { _ in
                applyProfileCategoriesOnEntry()
            }
            .onChange(of: deepLinkRouter.pendingHubTaskID) { taskID in
                guard taskID != nil else { return }
                Task { await openPendingTaskIfNeeded() }
            }
            .navigationDestination(isPresented: Binding(
                get: { deepLinkedTask != nil },
                set: { if !$0 { deepLinkedTask = nil } }
            )) {
                if let task = deepLinkedTask { TaskDetailView(task: task) }
            }
            .sheet(isPresented: $showingPostTask) {
                CreateTaskView(onCreated: {
                    Task { await loadHubTasks() }
                })
            }
            .sheet(isPresented: $showingEditProfile, onDismiss: {
                Task { await service.loadSpecialists() }
            }) {
                EditProfileView(activateSpecialistOnOpen: true)
            }
            .sheet(item: $startingChat) { chat in
                NavigationStack { ChatThreadView(chat: chat) }
                    .preferredColorScheme(.dark)
            }
            .alert("Чат не открылся", isPresented: Binding(
                get: { chatError != nil },
                set: { if !$0 { chatError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(chatError ?? "")
            }
            .alert("Задание не открылось", isPresented: Binding(
                get: { taskOpenError != nil },
                set: { if !$0 { taskOpenError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(taskOpenError ?? "")
            }
        }
    }

    private var hubHeader: some View {
        HStack(alignment: .center) {
            Text(loc.t("hub_title"))
                .font(.system(size: 34, weight: .black))
                .foregroundColor(.white)
                .kerning(0)
                .shadow(color: X5Style.blueSoft.opacity(0.45), radius: 18, x: 0, y: 0)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private var createTaskButton: some View {
        Button {
            showingPostTask = true
        } label: {
            Label(loc.t("hub_create_task"), systemImage: "plus.circle.fill")
                .font(.system(size: 16, weight: .black))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var addPortfolioButton: some View {
        Button {
            showingEditProfile = true
        } label: {
            Label(loc.t("hub_add_portfolio"), systemImage: "photo.badge.plus")
                .font(.system(size: 16, weight: .black))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private func countrySelector(messageKey: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Menu {
                    Button(loc.t("hub_all_countries")) {
                        selectedCountryCode = ""
                        selectedCity = ""
                    }
                    ForEach(CISLocations.countries, id: \.code) { country in
                        Button {
                            selectedCountryCode = country.code
                            selectedCity = ""
                        } label: {
                            if selectedCountryCode == country.code {
                                Label(country.name, systemImage: "checkmark")
                            } else {
                                Text(country.name)
                            }
                        }
                    }
                } label: {
                    Label(selectedCountryName, systemImage: "location.fill")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundColor(.white.opacity(0.94))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
                }
                .buttonStyle(.plain)

                CISCityPickerButton(
                    city: $selectedCity,
                    countryCode: selectedCountryCode,
                    allowsAllCities: true,
                    compact: true
                )
            }

            Text(loc.t(messageKey))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.62))
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
    }

    private var selectedCountryName: String {
        guard !selectedCountryCode.isEmpty else { return loc.t("hub_all_countries") }
        return CISLocations.countryName(for: selectedCountryCode) ?? selectedCountryCode
    }

    private var categoryRail: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    taskBrowseState.showCategories()
                    taskCategoriesExpanded = false
                }
            } label: {
                CategoryChip(title: loc.t("hub_back_to_categories"),
                             systemImage: "chevron.left",
                             count: nil,
                             isSelected: false)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("hub-task-results-back")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            taskBrowseState.showAllResults()
                        }
                    } label: {
                        CategoryChip(title: loc.t("hub_all"),
                                     systemImage: "line.3.horizontal.decrease.circle",
                                     count: totalVisibleCount,
                                     isSelected: taskBrowseState.selectedCategoryIds.isEmpty)
                    }
                    .buttonStyle(.plain)
                    .id("cat-all")

                    ForEach(visibleTaskCategories) { cat in
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                taskBrowseState.toggleResults(for: cat.id)
                            }
                        } label: {
                            CategoryChip(title: HubCategories.label(for: cat.id, language: loc.current),
                                         systemImage: hubCategorySymbol(for: cat.id),
                                         count: countForCategory(cat.id),
                                         isSelected: taskBrowseState.selectedCategoryIds.contains(cat.id))
                        }
                        .buttonStyle(.plain)
                        .id("cat-\(cat.id)")
                    }

                    if !taskCategoriesExpanded {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) { taskCategoriesExpanded = true }
                        } label: {
                            CategoryChip(title: loc.t("common_more"),
                                         systemImage: "ellipsis.circle",
                                         count: nil,
                                         isSelected: false)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.trailing, 16)
            }
        }
        .padding(.leading, 16)
        .padding(.vertical, 10)
    }

    private func startChat(with person: HubSpecialist) {
        guard let myId = auth.userId else {
            chatError = "Сначала войди в аккаунт."
            return
        }
        openingChatWith = person.id
        Task {
            guard let token = await auth.freshAccessToken() else {
                openingChatWith = nil
                chatError = "Сначала войди в аккаунт."
                return
            }
            let chat = await chats.ensureChat(otherUserId: person.id, currentUserId: myId, taskId: nil, taskTitle: nil, accessToken: token)
            openingChatWith = nil
            if let chat {
                startingChat = chat
            } else {
                chatError = chats.error ?? "Не удалось открыть чат. Попробуй ещё раз."
            }
        }
    }

    // MARK: - Сетка категорий (главный экран Hub)

    private var specialistsContent: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 14) {
                if category == nil {
                    specialistCategoryGrid
                    if totalVisibleCount == 0 && !service.isLoading {
                        EmptyState(systemImage: "person.crop.circle.badge.questionmark",
                                   title: loc.t("hub_no_specialists"),
                                   subtitle: loc.t("hub_no_specialists_sub"))
                            .padding(.top, 40)
                    }
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(filteredSpecialists) { person in
                            HStack(spacing: 8) {
                                NavigationLink {
                                    UserProfileView(userId: person.id, fallback: person)
                                } label: {
                                    SpecialistRow(person: person)
                                }
                                .buttonStyle(.plain)

                                Button {
                                    startChat(with: person)
                                } label: {
                                    Group {
                                        if openingChatWith == person.id {
                                            ProgressView().tint(.accentColor)
                                        } else {
                                            Image(systemName: "message.fill")
                                                .font(.system(size: 16, weight: .semibold))
                                                .foregroundColor(.accentColor)
                                        }
                                    }
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(openingChatWith != nil)
                            }
                        }
                        if filteredSpecialists.isEmpty && !service.isLoading {
                            EmptyState(systemImage: "person.crop.circle.badge.questionmark",
                                       title: loc.t("hub_no_specialists"),
                                       subtitle: loc.t("hub_no_specialists_sub"))
                                .padding(.top, 60)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .clipped()
        .refreshable { await service.loadSpecialists() }
    }

    private var specialistCategoryGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 8), count: 4),
            spacing: 8
        ) {
            NavigationLink {
                specialistCategoryPage(categoryId: nil, title: loc.t("hub_all"))
            } label: {
                CategoryTile(
                    title: loc.t("hub_all"),
                    systemImage: "line.3.horizontal.decrease.circle",
                    count: totalVisibleCount,
                    isSelected: false
                )
            }
            .buttonStyle(.plain)

            ForEach(HubCategories.hubDisplayOrder) { cat in
                NavigationLink {
                    specialistCategoryPage(
                        categoryId: cat.id,
                        title: HubCategories.label(for: cat.id, language: loc.current)
                    )
                } label: {
                    CategoryTile(
                        title: HubCategories.label(for: cat.id, language: loc.current),
                        systemImage: hubCategorySymbol(for: cat.id),
                        count: countForCategory(cat.id),
                        isSelected: false
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func specialistCategoryPage(categoryId: String?, title: String) -> some View {
        let people = specialists(matching: categoryId)

        return ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 10) {
                ForEach(people) { person in
                    HStack(spacing: 8) {
                        NavigationLink {
                            UserProfileView(userId: person.id, fallback: person)
                        } label: {
                            SpecialistRow(person: person)
                        }
                        .buttonStyle(.plain)

                        Button {
                            startChat(with: person)
                        } label: {
                            Group {
                                if openingChatWith == person.id {
                                    ProgressView().tint(.accentColor)
                                } else {
                                    Image(systemName: "message.fill")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(.accentColor)
                                }
                            }
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(openingChatWith != nil)
                    }
                }

                if people.isEmpty && !service.isLoading {
                    EmptyState(systemImage: "person.crop.circle.badge.questionmark",
                               title: loc.t("hub_no_specialists"),
                               subtitle: loc.t("hub_no_specialists_sub"))
                        .padding(.top, 60)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .clipped()
        .background { X5Background() }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .refreshable { await service.loadSpecialists() }
    }

    private func countForCategory(_ id: String) -> Int {
        if segment == .tasks {
            return taskCategoryCounts[id] ?? 0
        }
        return specialistCategoryCounts[id] ?? 0
    }

    // The "Все" tile has to promise exactly what opening it delivers. It used to
    // drop the signed-in user while the list and the category tiles kept them,
    // so a user who published their own profile saw "2" and then three cards.
    private var totalVisibleCount: Int {
        switch segment {
        case .specialists:
            return visibleSpecialists.count
        case .tasks:
            return service.tasks
                .filter { !BlockList.contains($0.authorId) }
                .filter { locationMatches(countryCode: $0.countryCode, city: $0.city) }
                .count
        }
    }

    private var specialistCategoryCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for person in visibleSpecialists {
            for id in person.specialistCategory ?? [] {
                counts[normalizedHubCategory(id), default: 0] += 1
            }
        }
        return counts
    }

    private var taskCategoryCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for task in service.tasks
        where !BlockList.contains(task.authorId)
            && locationMatches(countryCode: task.countryCode, city: task.city) {
            if let category = task.category {
                counts[normalizedHubCategory(category), default: 0] += 1
            }
        }
        return counts
    }

    private var specialistsList: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 10) {
                ForEach(filteredSpecialists) { person in
                    HStack(spacing: 8) {
                        NavigationLink {
                            UserProfileView(userId: person.id, fallback: person)
                        } label: {
                            SpecialistRow(person: person)
                        }
                        .buttonStyle(.plain)

                        Button {
                            startChat(with: person)
                        } label: {
                            Group {
                                if openingChatWith == person.id {
                                    ProgressView().tint(.accentColor)
                                } else {
                                    Image(systemName: "message.fill")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(.accentColor)
                                }
                            }
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(openingChatWith != nil)
                    }
                }
                if filteredSpecialists.isEmpty && !service.isLoading {
                    EmptyState(systemImage: "person.crop.circle.badge.questionmark",
                               title: loc.t("hub_no_specialists"),
                               subtitle: loc.t("hub_no_specialists_sub"))
                        .padding(.top, 60)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .clipped()
        .refreshable { await service.loadSpecialists() }
    }

    private var tasksList: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 10) {
                if let error = service.error {
                    VStack(spacing: 10) {
                        Text(loc.t("hub_tasks_load_error"))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.58))
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                        Button(loc.t("btn_retry")) {
                            Task { await loadHubTasks() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.accentColor)
                        .foregroundStyle(.black)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity)
                    .background(Color.red.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                if !taskBrowseState.isShowingResults {
                    taskCategoryGrid
                    if totalVisibleCount == 0 && !service.isLoading {
                        EmptyState(systemImage: "tray",
                                   title: loc.t("hub_no_tasks"),
                                   subtitle: loc.t("hub_no_tasks_sub"))
                            .padding(.top, 40)
                    }
                } else {
                    ForEach(filteredTasks) { task in
                        NavigationLink {
                            TaskDetailView(task: task)
                        } label: {
                            TaskRow(task: task)
                        }
                        .buttonStyle(.plain)
                    }
                    if filteredTasks.isEmpty && !service.isLoading {
                        EmptyState(systemImage: "tray",
                                   title: loc.t("hub_no_tasks"),
                                   subtitle: loc.t("hub_no_tasks_sub"))
                            .padding(.top, 60)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .clipped()
        .refreshable { await loadHubTasks() }
    }

    private var taskCategoryGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 8), count: 4),
            spacing: 8
        ) {
            Button {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    taskBrowseState.showAllResults()
                    taskCategoriesExpanded = true
                }
            } label: {
                CategoryTile(
                    title: loc.t("hub_all"),
                    systemImage: "line.3.horizontal.decrease.circle",
                    count: totalVisibleCount,
                    isSelected: false
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("hub-task-category-all")

            Button {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    taskBrowseState.showResults(forProfileCategories: currentUser.profile?.specialistCategory)
                    taskCategoriesExpanded = true
                }
            } label: {
                CategoryTile(
                    title: loc.t("hub_tasks_by_categories"),
                    systemImage: "slider.horizontal.3",
                    count: 0,
                    isSelected: false
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("hub-task-category-filter")

            ForEach(HubCategories.hubDisplayOrder) { cat in
                Button {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                        taskBrowseState.showResults(for: cat.id)
                        taskCategoriesExpanded = true
                    }
                } label: {
                    CategoryTile(
                        title: HubCategories.label(for: cat.id, language: loc.current),
                        systemImage: hubCategorySymbol(for: cat.id),
                        count: countForCategory(cat.id),
                        isSelected: false
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("hub-task-category-\(cat.id)")
            }
        }
    }

    private var filteredSpecialists: [HubSpecialist] {
        specialists(matching: category)
    }

    private var visibleSpecialists: [HubSpecialist] {
        let visible = service.specialists
            .filter { !BlockList.contains($0.id) }
            .filter { locationMatches(countryCode: $0.countryCode, city: $0.city) }
        // Экран галочки обещает «твои карточки выше»: с активной галочкой — первыми,
        // внутри групп порядок сервера (новые сверху) не меняется.
        let now = Date()
        return visible.filter { $0.hasActiveVerifiedBadge(at: now) }
            + visible.filter { !$0.hasActiveVerifiedBadge(at: now) }
    }

    private func specialists(matching categoryId: String?) -> [HubSpecialist] {
        guard let categoryId else { return visibleSpecialists }
        return visibleSpecialists.filter { person in
            (person.specialistCategory ?? []).contains { normalizedHubCategory($0) == categoryId }
        }
    }

    private var filteredTasks: [HubTask] {
        let visible = service.tasks
            .filter { !BlockList.contains($0.authorId) }
            .filter { locationMatches(countryCode: $0.countryCode, city: $0.city) }
        let filtered = visible.filter {
            taskBrowseState.includes(categoryId: normalizedHubCategory($0.category))
        }
        guard taskBrowseState.selectedCategoryIds.isEmpty,
              !taskBrowseState.preferredCategoryIds.isEmpty
        else { return filtered }

        // Stable partition: profile matches appear first while every open task
        // remains visible in the server's original newest-first order.
        return filtered.enumerated().sorted { lhs, rhs in
            let lhsPreferred = taskBrowseState.preferredCategoryIds.contains(
                normalizedHubCategory(lhs.element.category)
            )
            let rhsPreferred = taskBrowseState.preferredCategoryIds.contains(
                normalizedHubCategory(rhs.element.category)
            )
            if lhsPreferred != rhsPreferred { return lhsPreferred && !rhsPreferred }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private func refreshCurrentHubSegment() async {
        switch segment {
        case .specialists:
            await service.loadSpecialists()
        case .tasks:
            await loadHubTasks()
        }
    }

    private func seedLocationFromProfileIfNeeded() {
        guard !didSeedLocation else { return }
        didSeedLocation = true
        if let code = currentUser.profile?.countryCode, !code.isEmpty {
            selectedCountryCode = code
        }
        selectedCity = currentUser.profile?.city ?? ""
    }

    private func locationMatches(countryCode: String?, city: String?) -> Bool {
        if !selectedCountryCode.isEmpty,
           countryCode?.caseInsensitiveCompare(selectedCountryCode) != .orderedSame {
            return false
        }
        let requestedCity = selectedCity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedCity.isEmpty else { return true }
        return city?.range(of: requestedCity, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private func loadHubTasks() async {
        // Never reuse a possibly expired cached JWT. The open feed remains
        // readable anonymously if refresh is temporarily unavailable.
        let token: String?
        if auth.isAuthenticated {
            token = await auth.freshAccessToken()
        } else {
            token = nil
        }
        await service.loadTasks(accessToken: token)
    }

    private func repairCurrentHubProfileIfNeeded() async {
        guard let profileOperation = currentUser.operationContext() else { return }
        guard currentUser.profile?.showInHub == true,
              currentUser.profile?.isPublic != true,
              let token = await auth.freshAccessToken()
        else { return }
        await currentUser.patchMany(["is_public": AnyEncodable(true)], accessToken: token, operation: profileOperation)
    }

    private func applyProfileCategoriesOnEntry() {
        _ = taskBrowseState.applyProfileCategoriesOnEntry(
            currentUser.profile?.specialistCategory
        )
    }

    private func openPendingTaskIfNeeded() async {
        guard let taskID = deepLinkRouter.pendingHubTaskID else { return }
        segment = .tasks
        taskCategoriesExpanded = true

        if let task = service.tasks.first(where: { $0.id == taskID }) {
            deepLinkedTask = task
            deepLinkRouter.consumeHubTask(id: taskID)
            return
        }
        guard let token = await auth.freshAccessToken(),
              let task = await service.loadTask(id: taskID, accessToken: token)
        else {
            taskOpenError = "Задание недоступно или было удалено."
            deepLinkRouter.consumeHubTask(id: taskID)
            return
        }
        deepLinkedTask = task
        deepLinkRouter.consumeHubTask(id: taskID)
    }
}

// MARK: - Background

// MARK: - Tile категории

private func hubCategorySymbol(for id: String) -> String {
    HubCategories.symbol(for: id)
}

private func normalizedHubCategory(_ value: String?) -> String {
    guard let value else { return "other" }
    let cleaned = value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: "-", with: "_")
        .replacingOccurrences(of: " ", with: "_")

    switch cleaned {
    case "smm", "смм", "смм_специалист", "smm_specialist":
        return "smm"
    case "ads", "ad", "target", "target_ads", "targeting_ads", "reklama", "реклама", "таргет", "таргет_реклама":
        return "targeting"
    case "chatbot", "chatbots", "bot", "bots", "botdev", "bot_dev":
        return "bot_dev"
    case "web", "webdev", "web_development":
        return "web_dev"
    case "mobile", "mobiledev", "mobile_development":
        return "mobile_dev"
    case "ai", "ml", "ai_ml", "ai_neural", "нейросети":
        return "ai_ml"
    case "game", "game_dev":
        return "gamedev"
    case "uiux", "ui/ux", "ux_ui":
        return "ui_ux"
    default:
        return cleaned
    }
}

private struct CategoryChip: View {
    let title: String
    let systemImage: String
    let count: Int?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white.opacity(0.72))
            Text(title)
                .font(.system(size: 14, weight: .heavy))
                .lineLimit(1)
                .foregroundColor(isSelected ? .black : .white.opacity(0.76))
            if let count, count > 0 {
                Text("\(count)")
                    .font(.system(size: 12, weight: .black))
                    .padding(.leading, 1)
                    .foregroundColor(isSelected ? .black.opacity(0.78) : .white.opacity(0.60))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.white.opacity(0.075))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.3) : Color.white.opacity(0.10), lineWidth: 1)
        )
    }
}

private struct CategoryTile: View {
    let title: String
    let systemImage: String
    let count: Int
    let isSelected: Bool

    private var isSingleWord: Bool {
        !title.contains(" ") && !title.contains("-")
    }

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(isSelected ? .black : .white.opacity(0.74))
                .frame(height: 26)
            Text(title)
                .font(.system(size: 10.5, weight: .heavy))
                .foregroundColor(isSelected ? .black : .white)
                .multilineTextAlignment(.center)
                // Одно длинное слово («Видеооператор», «Корреспондент») не переносится
                // и вылезало за края плитки (Адильхан 10.10 18:30) — ужимаем в строку.
                .lineLimit(isSingleWord ? 1 : 3)
                .minimumScaleFactor(isSingleWord ? 0.6 : 0.68)
                .padding(.horizontal, 5)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundColor(isSelected ? .black.opacity(0.72) : .white.opacity(0.62))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 92)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.white.opacity(0.075))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.40) : Color.white.opacity(0.12), lineWidth: 1)
        )
    }
}

// MARK: - Rows

// Не private: та же строка используется в списках подписчиков/подписок
// (ProfileFollowListView), чтобы люди выглядели одинаково везде.
struct SpecialistRow: View {
    let person: HubSpecialist
    @EnvironmentObject private var loc: LocalizationService

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(urlString: person.avatar, name: person.name, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(person.name ?? person.nickname ?? "Xfive marketing")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                    if person.hasActiveVerifiedBadge {
                        VerifiedChip(size: 12)
                    }
                    if person.isPro {
                        Text("PRO").font(.system(size: 9, weight: .heavy))
                            .foregroundColor(.black)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.accentColor)
                            .clipShape(Capsule())
                    }
                }
                Text(categoryLabel)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.58))
                if let bio = person.bio, !bio.isEmpty {
                    Text(bio)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.55))
                        .lineLimit(2)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.3))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.065))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private var categoryLabel: String {
        let ids = HubCategories.orderedIDs(from: person.specialistCategory)
        let label = ids.prefix(2).map { HubCategories.label(for: $0, language: loc.current) }.joined(separator: " · ")
        // В Хабе у всех есть категория; в списке подписчиков бывают обычные
        // пользователи без неё — тогда показываем @ник вместо пустой строки.
        if label.isEmpty, let nick = person.nickname, !nick.isEmpty {
            return "@\(nick)"
        }
        return label
    }
}

private struct TaskRow: View {
    let task: HubTask
    @EnvironmentObject private var loc: LocalizationService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                    Text(HubCategories.label(for: task.category, language: loc.current))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.58))
                }
                Spacer()
                if let budget = task.budget, !budget.isEmpty {
                    Text(budget)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            if let desc = task.description, !desc.isEmpty {
                Text(desc).font(.system(size: 12)).foregroundColor(.white.opacity(0.55)).lineLimit(2)
            }
            HStack(spacing: 8) {
                AvatarView(urlString: task.authorAvatar, name: task.authorName, size: 22)
                Text(task.authorName ?? "Anonymous")
                    .font(.system(size: 11)).foregroundColor(.white.opacity(0.55))
                Spacer()
                if let deadline = task.deadline, !deadline.isEmpty {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                    Text(formatDate(deadline))
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.065))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private func formatDate(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return iso }
        let out = DateFormatter()
        out.dateStyle = .medium
        return out.string(from: d)
    }
}

// MARK: - Helpers

struct AvatarView: View {
    let urlString: String?
    let name: String?
    var size: CGFloat = 36

    var body: some View {
        Group {
            if let s = urlString, !s.isEmpty, let url = URL(string: s) {
                CachedAsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    placeholder
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(initials)
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundColor(.white)
        }
    }

    private var initials: String {
        let parts = (name ?? "?").split(separator: " ")
        let first = parts.first?.first.map(String.init) ?? "?"
        let last = parts.dropFirst().first?.first.map(String.init) ?? ""
        return (first + last).uppercased()
    }
}

struct EmptyState: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 38, weight: .light))
                .foregroundColor(.white.opacity(0.4))
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }
}
