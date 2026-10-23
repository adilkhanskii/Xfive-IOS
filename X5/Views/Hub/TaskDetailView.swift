import SwiftUI

struct TaskDetailView: View {
    let task: HubTask

    @EnvironmentObject private var auth: Auth
    @EnvironmentObject private var currentUser: CurrentUser
    @EnvironmentObject private var loc: LocalizationService
    @Environment(\.dismiss) private var dismiss
    @StateObject private var service = HubService()
    @StateObject private var chats = ChatsService()
    @State private var responses: [TaskResponse] = []
    @State private var navigatingChat: ChatRoom?
    @State private var accepting: String?
    @State private var confirmBlock = false
    @State private var openingChat = false
    @State private var acceptError: String?

    private var isAuthor: Bool { auth.userId == task.authorId }
    private var hasRespondedAlready: Bool {
        guard let me = auth.userId else { return false }
        return responses.contains { $0.specialistId == me }
    }

    private func reportTask() {
        let subject = "Report task \(task.id)"
        let body = "Hi Xfive marketing team,\n\nI'd like to report this task. Please review the content.\n\nTask ID: \(task.id)\nAuthor ID: \(task.authorId)\n"
        let to = "appreview@x5studio.app"
        let s = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let b = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "mailto:\(to)?subject=\(s)&body=\(b)") {
            UIApplication.shared.open(url)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Text(HubCategories.label(for: task.category, language: loc.current).uppercased())
                        .font(.system(size: 10, weight: .heavy))
                        .tracking(1.2)
                        .foregroundColor(.accentColor)
                    Spacer()
                    if let budget = task.budget, !budget.isEmpty {
                        Text(budget)
                            .font(.system(size: 16, weight: .heavy))
                            .foregroundColor(.white)
                    }
                }

                Text(task.title)
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundColor(.white)

                if let city = task.city, !city.isEmpty {
                    let country = task.countryCode.flatMap(CISLocations.countryName(for:))
                    Label([city, country].compactMap { $0 }.joined(separator: ", "), systemImage: "mappin.and.ellipse")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.68))
                }

                if let desc = task.description, !desc.isEmpty {
                    Text(desc)
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().background(Color.white.opacity(0.06))

                HStack(spacing: 10) {
                    NavigationLink {
                        UserProfileView(userId: task.authorId, fallback: authorFallback)
                    } label: {
                        HStack(spacing: 10) {
                            AvatarView(urlString: task.authorAvatar, name: task.authorName, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.authorName ?? loc.t("hub_anonymous"))
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.white)
                                if let company = task.companyName, !company.isEmpty {
                                    Text(company).font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    if let deadline = task.deadline, !deadline.isEmpty {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(loc.t("hub_deadline").uppercased()).font(.system(size: 9, weight: .heavy)).tracking(1.0).foregroundColor(.white.opacity(0.45))
                            Text(formatDate(deadline)).font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                        }
                    }
                }

                Text("\(loc.t("hub_responses_label")) (\(responses.count))")
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(1.4)
                    .foregroundColor(.white.opacity(0.45))
                    .padding(.top, 8)

                if responses.isEmpty {
                    Text(loc.t("hub_no_responses"))
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                } else {
                    ForEach(responses) { r in responseRow(r) }
                }

                if isAuthor {
                    Text(loc.t("hub_author_notice"))
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.45))
                        .padding(.top, 8)
                } else if hasRespondedAlready {
                    Text(loc.t("hub_response_sent"))
                        .font(.system(size: 12))
                        .foregroundColor(.accentColor.opacity(0.85))
                        .padding(.top, 8)
                } else if task.status == "open" {
                    Button {
                        Task { await openChatWithAuthor() }
                    } label: {
                        HStack {
                            if openingChat { ProgressView().tint(.black) }
                            Text(openingChat ? "Открываю чат..." : loc.t("hub_respond_to_task"))
                                .font(.system(size: 16, weight: .bold))
                        }
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.accentColor)
                        .cornerRadius(14)
                    }
                    .buttonStyle(.plain)
                    .disabled(openingChat)
                    .padding(.top, 8)
                } else {
                    Text(loc.t("hub_task_closed"))
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.top, 8)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 32)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(Color(red: 0.04, green: 0.05, blue: 0.10).ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            if !isAuthor {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            reportTask()
                        } label: {
                            Label(loc.t("hub_report_user"), systemImage: "exclamationmark.bubble")
                        }
                        Button(role: .destructive) {
                            confirmBlock = true
                        } label: {
                            Label(loc.t("hub_block_author"), systemImage: "hand.raised.slash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
            }
        }
        .alert(loc.t("hub_block_author_title"), isPresented: $confirmBlock) {
            Button(loc.t("btn_cancel"), role: .cancel) {}
            Button(loc.t("hub_block_user"), role: .destructive) {
                BlockList.add(task.authorId)
                dismiss()
            }
        } message: {
            Text(loc.t("hub_block_author_message"))
        }
        .alert("Не удалось принять отклик", isPresented: Binding(
            get: { acceptError != nil },
            set: { if !$0 { acceptError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(acceptError ?? "")
        }
        .task {
            chats.configureAccessTokenProvider(auth: auth)
            responses = await service.loadResponses(taskId: task.id)
        }
        .sheet(item: $navigatingChat) { chat in
            NavigationStack { ChatThreadView(chat: chat) }
                .preferredColorScheme(.dark)
        }
    }

    private var authorFallback: HubSpecialist {
        HubSpecialist(
            id: task.authorId,
            name: task.authorName,
            nickname: nil,
            avatar: task.authorAvatar,
            bio: task.companyName,
            specialistCategory: nil,
            plan: nil,
            services: nil,
            socialLinks: nil,
            countryCode: task.countryCode,
            city: task.city,
            isVerified: nil,
            verifiedUntil: nil
        )
    }

    private func openChatWithAuthor() async {
        guard let uid = auth.userId, let token = auth.accessToken else { return }
        openingChat = true
        defer { openingChat = false }
        if let chat = await chats.ensureChat(
            otherUserId: task.authorId,
            currentUserId: uid,
            taskId: task.id,
            taskTitle: task.title,
            accessToken: token
        ) {
            var rows = await chats.loadMessages(chatId: chat.id, accessToken: token, forceRefresh: true)
            if !rows.contains(where: { $0.taskCard?.id == task.id }),
               let card = await chats.sendTaskCard(chatId: chat.id, currentUserId: uid, task: task, accessToken: token) {
                rows.append(card)
                chats.persistMessageCache(chatId: chat.id, rows: rows)
            }
            navigatingChat = chat
        }
    }

    @ViewBuilder
    private func responseRow(_ r: TaskResponse) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                AvatarView(urlString: r.specialistAvatar, name: r.specialistName, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(r.specialistName ?? loc.t("hub_specialist"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                        if r.status == "accepted" {
                            Text(loc.t("hub_accepted"))
                                .font(.system(size: 9, weight: .heavy))
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Color.accentColor)
                                .foregroundColor(.black)
                                .clipShape(Capsule())
                        }
                    }
                    Text(r.message ?? "")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            if isAuthor && r.status == "open" && task.status == "open" {
                Button {
                    Task { await accept(r) }
                } label: {
                    HStack {
                        if accepting == r.id { ProgressView().tint(.black) }
                        Text(accepting == r.id ? "Accepting…" : "Accept & open chat")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.accentColor)
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .disabled(accepting != nil)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func accept(_ r: TaskResponse) async {
        guard let token = await auth.freshAccessToken(), let me = auth.userId else { return }
        accepting = r.id
        defer { accepting = nil }
        guard await service.acceptResponse(
            taskId: task.id,
            responseId: r.id,
            accessToken: token
        ) != nil else {
            acceptError = service.error ?? "Сервер не подтвердил принятие отклика."
            return
        }
        if let chat = await chats.ensureChat(
            otherUserId: r.specialistId,
            currentUserId: me,
            taskId: task.id,
            taskTitle: task.title,
            accessToken: token
        ) {
            var rows = await chats.loadMessages(chatId: chat.id, accessToken: token, forceRefresh: true)
            if !rows.contains(where: { $0.taskCard?.id == task.id }),
               let card = await chats.sendTaskCard(chatId: chat.id, currentUserId: me, task: task, accessToken: token) {
                rows.append(card)
            }
            if let acceptedMessage = await chats.sendText(
                chatId: chat.id,
                currentUserId: me,
                text: "Принял отклик по заданию «\(task.title)». Давай начнем.",
                accessToken: token
            ) {
                rows.append(acceptedMessage)
            }
            chats.persistMessageCache(chatId: chat.id, rows: rows)
            navigatingChat = chat
        }
        responses = await service.loadResponses(taskId: task.id)
    }

    private func formatDate(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return iso }
        let out = DateFormatter()
        out.dateStyle = .short
        return out.string(from: d)
    }
}
