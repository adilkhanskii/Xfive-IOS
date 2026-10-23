import SwiftUI

private func makeStartupChatInitialMessages() -> [StartupChatMessage] {
    [
        StartupChatMessage(
            role: .assistant,
            content: """
            Я стартап-помощник Xfive marketing. Опишите идею — помогу проверить спрос, аудиторию и выбрать следующий шаг.
            """
        )
    ]
}

struct StartupChatView: View {
    @EnvironmentObject private var auth: Auth

    @State private var messages = makeStartupChatInitialMessages()
    @State private var draft = ""
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var errorCanRetry = true
    @State private var retryAvailableAt: Date?
    @State private var sendTask: Task<Void, Never>?
    @State private var sendGeneration = UUID()
    @State private var isViewActive = false
    @FocusState private var draftFocused: Bool

    private let service = StartupChatService()
    private let pendingStore = StartupChatPendingRequestStore()

    var body: some View {
        VStack(spacing: 0) {
            conversation
            if let errorMessage {
                errorBanner(errorMessage)
            }
            composer
        }
        .background(background)
        .navigationTitle("Стартап чат")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .preferredColorScheme(.dark)
        .onAppear {
            isViewActive = true
            sendGeneration = UUID()
        }
        .onDisappear {
            isViewActive = false
            cancelActiveSend()
        }
        .onChange(of: auth.userId) { _ in
            cancelActiveSend()
            messages = makeStartupChatInitialMessages()
            draft = ""
            errorMessage = nil
            errorCanRetry = true
            retryAvailableAt = nil
            draftFocused = false
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    introCard

                    ForEach(messages) { message in
                        StartupChatBubble(message: message)
                            .id(message.id)
                    }

                    if isSending {
                        HStack {
                            StartupChatTypingBubble()
                            Spacer(minLength: 58)
                        }
                        .id("startup-chat-loading")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { _ in
                scrollToBottom(proxy)
            }
            .onChange(of: isSending) { _ in
                scrollToBottom(proxy)
            }
        }
    }

    private var introCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.black)
                .frame(width: 44, height: 44)
                .background(X5Style.blue)
                .clipShape(RoundedRectangle(cornerRadius: 13))

            VStack(alignment: .leading, spacing: 3) {
                Text("Советник для запуска")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundColor(.white)
                Text("Идея → проверка спроса → конкретный следующий шаг")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.58))
            }
            Spacer()
        }
        .padding(14)
        .x5ClearGlass(cornerRadius: 18, highlight: 0.11)
    }

    private var composer: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            composerContent(now: context.date)
        }
    }

    private func composerContent(now: Date) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(
                "Напишите о своей идее…",
                text: $draft,
                axis: .vertical
            )
            .focused($draftFocused)
            .lineLimit(1...5)
            .textInputAutocapitalization(.sentences)
            .submitLabel(.send)
            .onSubmit {
                if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    submit()
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 17))
            .overlay(
                RoundedRectangle(cornerRadius: 17)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            )

            Button(action: submit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 18, weight: .black))
                    .foregroundColor(.black)
                    .frame(width: 44, height: 44)
                    .background(
                        canSend(at: now)
                            ? X5Style.blue
                            : Color.white.opacity(0.18)
                    )
                    .clipShape(Circle())
            }
            .disabled(!canSend(at: now))
            .accessibilityLabel("Отправить")
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider().overlay(Color.white.opacity(0.08))
        }
        .disabled(!canRetry(at: now))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(message)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.86))
            Spacer()
            if errorCanRetry {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if canRetry(at: context.date) {
                        Button("Повторить") {
                            retry()
                        }
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundColor(X5Style.blue)
                    } else if let retryAvailableAt {
                        Text(
                            retryCountdownText(
                                until: retryAvailableAt,
                                now: context.date
                            )
                        )
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundColor(.orange)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.red.opacity(0.16))
    }

    private var background: some View {
        ZStack {
            X5Style.ink.ignoresSafeArea()
            RadialGradient(
                colors: [
                    X5Style.backgroundBlue.opacity(0.25),
                    .clear
                ],
                center: .topLeading,
                startRadius: 10,
                endRadius: 430
            )
            .ignoresSafeArea()
        }
    }

    private func canSend(at now: Date) -> Bool {
        !isSending &&
            canRetry(at: now) &&
            !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func canRetry(at now: Date) -> Bool {
        guard let retryAvailableAt else { return true }
        return retryAvailableAt <= now
    }

    private func cancelActiveSend() {
        sendGeneration = UUID()
        sendTask?.cancel()
        sendTask = nil
        isSending = false
    }

    private func isSendCurrent(
        _ generation: UUID,
        userID: String
    ) -> Bool {
        isViewActive &&
            sendGeneration == generation &&
            auth.userId == userID
    }

    private func submit() {
        guard !isSending,
              canRetry(at: Date()),
              let content = try? StartupChatService
                .normalizeUserMessage(draft)
        else { return }

        messages.append(
            StartupChatMessage(
                role: .user,
                content: content
            )
        )
        draft = ""
        errorMessage = nil
        errorCanRetry = true
        retryAvailableAt = nil
        draftFocused = false
        sendHistory()
    }

    private func retry() {
        guard messages.last?.role == .user,
              !isSending,
              canRetry(at: Date())
        else { return }
        errorMessage = nil
        errorCanRetry = true
        retryAvailableAt = nil
        sendHistory()
    }

    private func sendHistory() {
        guard isViewActive, let userID = auth.userId else {
            errorMessage = StartupChatServiceError
                .missingAccessToken
                .localizedDescription
            errorCanRetry = true
            retryAvailableAt = nil
            return
        }

        sendTask?.cancel()
        let generation = UUID()
        sendGeneration = generation
        isSending = true
        let history = Array(messages.suffix(12))

        sendTask = Task { @MainActor in
            var activeRequestID: UUID?
            defer {
                if isSendCurrent(generation, userID: userID) {
                    sendTask = nil
                    isSending = false
                }
            }

            guard let token = await auth.freshAccessToken() else {
                guard
                    !Task.isCancelled,
                    isSendCurrent(generation, userID: userID)
                else {
                    return
                }
                errorMessage = StartupChatServiceError
                    .missingAccessToken
                    .localizedDescription
                errorCanRetry = true
                retryAvailableAt = nil
                return
            }

            do {
                try Task.checkCancellation()
                guard isSendCurrent(generation, userID: userID) else {
                    return
                }
                let normalized = try StartupChatService
                    .normalizeForTransport(history)
                let fingerprint = try StartupChatService
                    .fingerprint(for: normalized)
                let requestID = pendingStore.requestID(
                    userID: userID,
                    fingerprint: fingerprint
                )
                activeRequestID = requestID
                let result = try await service.send(
                    messages: normalized,
                    requestID: requestID,
                    accessToken: token
                )
                try Task.checkCancellation()
                guard isSendCurrent(generation, userID: userID) else {
                    return
                }
                pendingStore.clear(
                    userID: userID,
                    requestID: requestID
                )
                let displayedReply = try StartupChatService
                    .normalizeAssistantReply(result.reply)
                messages.append(
                    StartupChatMessage(
                        role: .assistant,
                        content: displayedReply
                    )
                )
                retryAvailableAt = nil
            } catch is CancellationError {
                return
            } catch {
                guard
                    !Task.isCancelled,
                    isSendCurrent(generation, userID: userID)
                else {
                    return
                }
                let serviceError = error as? StartupChatServiceError
                if serviceError == .invalidConversation,
                   let requestID = activeRequestID {
                    pendingStore.clear(
                        userID: userID,
                        requestID: requestID
                    )
                }
                errorMessage = serviceError?.errorDescription ??
                    StartupChatServiceError
                    .assistantUnavailable
                    .localizedDescription
                errorCanRetry = serviceError != .invalidConversation
                if let retryAfter = serviceError?.retryAfterSeconds {
                    draftFocused = false
                    retryAvailableAt = Date().addingTimeInterval(
                        TimeInterval(retryAfter)
                    )
                } else {
                    retryAvailableAt = nil
                }
            }
        }
    }

    private func retryCountdownText(until deadline: Date, now: Date) -> String {
        let remaining = max(
            1,
            Int(ceil(deadline.timeIntervalSince(now)))
        )
        if remaining >= 3_600 {
            let hours = remaining / 3_600
            let minutes = (remaining % 3_600) / 60
            return "Повторить можно через \(hours) ч \(minutes) мин"
        }
        if remaining >= 60 {
            let minutes = remaining / 60
            let seconds = remaining % 60
            return "Повторить можно через \(minutes) мин \(seconds) сек"
        }
        return "Повторить можно через \(remaining) сек"
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        let target: AnyHashable
        if isSending {
            target = AnyHashable("startup-chat-loading")
        } else if let messageID = messages.last?.id {
            target = AnyHashable(messageID)
        } else {
            target = AnyHashable("startup-chat-loading")
        }
        withAnimation(.easeOut(duration: 0.22)) {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }
}

private struct StartupChatBubble: View {
    let message: StartupChatMessage

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 58)
            }

            Text(message.content)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(message.role == .user ? .black : .white)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(
                    message.role == .user
                        ? X5Style.blue
                        : Color.white.opacity(0.09)
                )
                .clipShape(
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                )
                .overlay {
                    if message.role == .assistant {
                        RoundedRectangle(cornerRadius: 17)
                            .stroke(Color.white.opacity(0.10), lineWidth: 1)
                    }
                }

            if message.role == .assistant {
                Spacer(minLength: 58)
            }
        }
    }
}

private struct StartupChatTypingBubble: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .tint(X5Style.blue)
            Text("Формирую ответ…")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(pulse ? 0.78 : 0.48))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color.white.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 17))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever()) {
                pulse = true
            }
        }
    }
}
