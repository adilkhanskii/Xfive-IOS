import SwiftUI

/// Specialist responds to a task. On success: insert task_response, ensure chat, navigate to chat.
struct RespondTaskView: View {
    let task: HubTask

    @EnvironmentObject private var auth: Auth
    @EnvironmentObject private var currentUser: CurrentUser
    @EnvironmentObject private var loc: LocalizationService
    @Environment(\.dismiss) private var dismiss

    @State private var message: String = ""
    @State private var saving: Bool = false
    @State private var errorMessage: String?
    @State private var navigatingChat: ChatRoom?

    @StateObject private var hub = HubService()
    @StateObject private var chats = ChatsService()

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text(loc.t("task_section"))) {
                    Text(task.title).font(.headline)
                    if let budget = task.budget, !budget.isEmpty {
                        HStack {
                            Text(loc.t("task_budget")); Spacer()
                            Text(budget).foregroundColor(.accentColor).bold()
                        }
                    }
                }
                Section(header: Text(loc.t("task_your_message"))) {
                    TextField("Чем можешь помочь?", text: $message, axis: .vertical)
                        .lineLimit(3...8)
                }
                if let err = errorMessage {
                    Section { Text(err).foregroundColor(.red) }
                }
                Section(footer: Text(loc.t("task_response_footer"))) {
                    EmptyView()
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(red: 0.04, green: 0.05, blue: 0.10))
            .navigationTitle("Отклик")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc.t("btn_cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if saving { ProgressView() } else { Text(loc.t("task_send")).bold() }
                    }
                    .disabled(saving || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(item: $navigatingChat) { chat in
            NavigationStack { ChatThreadView(chat: chat) }
                .preferredColorScheme(.dark)
        }
    }

    private func submit() async {
        chats.configureAccessTokenProvider(auth: auth)
        guard let uid = auth.userId, let token = auth.accessToken else { return }
        saving = true
        defer { saving = false }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let resp = await hub.respondToTask(
            taskId: task.id,
            specialistId: uid,
            specialistName: currentUser.profile?.name ?? auth.userEmail,
            specialistAvatar: currentUser.profile?.avatar,
            message: trimmed,
            accessToken: token
        )
        if resp == nil {
            errorMessage = "Could not send your response."
            return
        }
        // Open a chat with the task author tagged with this task
        if let chat = await chats.ensureChat(otherUserId: task.authorId, currentUserId: uid, taskId: task.id, taskTitle: task.title, accessToken: token) {
            var rows = await chats.loadMessages(chatId: chat.id, accessToken: token, forceRefresh: true)
            if !rows.contains(where: { $0.taskCard?.id == task.id }),
               let card = await chats.sendTaskCard(chatId: chat.id, currentUserId: uid, task: task, accessToken: token) {
                rows.append(card)
            }
            if let responseMessage = await chats.sendText(chatId: chat.id, currentUserId: uid, text: trimmed, accessToken: token) {
                rows.append(responseMessage)
            }
            chats.persistMessageCache(chatId: chat.id, rows: rows)
            navigatingChat = chat
        } else {
            dismiss()
        }
    }
}
