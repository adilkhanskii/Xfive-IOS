import SwiftUI
import PhotosUI
import AVFoundation
import AVKit
import UniformTypeIdentifiers

struct ChatThreadView: View {
    let chat: ChatRoom

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var auth: Auth
    @EnvironmentObject private var loc: LocalizationService
    @StateObject private var service = ChatsService()
    @StateObject private var recorder = AudioRecorder()
    @State private var messages: [ChatMessageRow] = []
    @State private var draft: String = ""
    @State private var sending: Bool = false
    @State private var other: UserProfile?
    @State private var showingProfile: Bool = false
    @State private var showingMenu: Bool = false
    @State private var confirmBlock: Bool = false
    /// Галерея UIKit (X5PhotoPickerPresenter): SwiftUI-шная после Face ID закрывалась
    /// и открывалась по кругу (Адильхан 10.10). До 10 фото/видео за раз, как в WhatsApp.
    @State private var showingMediaPicker: Bool = false
    /// Пачка: какое сейчас по счёту («Отправка 3 из 10»). nil — пачки нет.
    @State private var mediaBatchProgress: ChatMediaBatchProgress?
    /// Фото на весь экран; у альбома листается.
    @State private var photoViewer: ChatPhotoViewerState?
    @State private var attachmentError: String?
    @State private var attachmentUploadProgress: Double?
    @State private var roomUnread: [String: Int] = [:]
    @State private var messageStateTick: Int = 0
    @State private var replyingTo: ChatMessageRow?
    @State private var voicePressActive: Bool = false
    @State private var voiceStartInFlight: Bool = false
    @State private var voiceSendInFlight: Bool = false
    @State private var lastVoiceSendFingerprint: String?
    @State private var lastVoiceSendAt: Date?
    @FocusState private var inputFocused: Bool
    @State private var searchActive: Bool = false
    @State private var searchQuery: String = ""
    @State private var showingStickers: Bool = false
    @State private var hasOlderMessages: Bool = false
    @State private var loadingOlderMessages: Bool = false
    @State private var pendingMessageIDs: Set<String> = []
    @State private var failedTextMessages: [String: FailedTextMessage] = [:]
    /// Bumped when ChatsLocalState mutations happen via the header menu so the
    /// view rereads `isMuted/isPinned` for icon toggles without observing.
    @State private var chatStateTick: Int = 0
    /// Первая прокрутка вниз — без анимации (чат сразу открывается на последнем сообщении).
    @State private var didInitialScroll: Bool = false
    /// Закреп с сервера (chats.pinned_message_id) — один на чат, общий для обоих, как в Telegram.
    @State private var pinnedMessageID: String?
    /// Закреплённое сообщение, если оно старше загруженной страницы (для превью в плашке).
    @State private var pinnedMessageFallback: ChatMessageRow?
    @State private var pinError: String?
    /// Тап по плашке → прокрутка к сообщению и короткая подсветка.
    @State private var scrollTargetID: String?
    @State private var highlightedMessageID: String?
    @State private var pollTick: Int = 0
    /// Пока наш запрос «закрепить» в пути, опрос сервера не перетирает экран старым значением.
    @State private var pinWriteInFlight: Bool = false

    init(chat: ChatRoom, initialOther: UserProfile? = nil) {
        self.chat = chat
        _other = State(initialValue: initialOther)
    }

    var body: some View {
        VStack(spacing: 0) {
            if searchActive {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.white.opacity(0.5))
                    TextField(loc.t("chats_search_placeholder"), text: $searchQuery)
                        .textFieldStyle(.plain)
                        .foregroundColor(.white)
                    if !searchQuery.isEmpty {
                        Button { searchQuery = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.white.opacity(0.4))
                        }
                    }
                    Button {
                        searchActive = false
                        searchQuery = ""
                    } label: {
                        Text(loc.t("btn_done")).foregroundColor(.accentColor)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color.white.opacity(0.06))
            }

            pinnedBanner

            messagesPane

            if let replyingTo {
                replyBanner(for: replyingTo)
            }

            mediaBatchBanner

            inputBar
        }
        .background(ChatBackground())
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .tabBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        searchActive.toggle()
                        if !searchActive { searchQuery = "" }
                    } label: {
                        Label(loc.t("chats_search_placeholder"), systemImage: "magnifyingglass")
                    }
                    let muted = ChatsLocalState.isMuted(chat.id)
                    Button {
                        if muted { ChatsLocalState.unmute(chat.id) }
                        else { ChatsLocalState.mute(chat.id) }
                        chatStateTick &+= 1
                    } label: {
                        Label(
                            muted ? loc.t("chats_unmute") : loc.t("chats_mute"),
                            systemImage: muted ? "bell" : "bell.slash"
                        )
                    }
                    let pinned = ChatsLocalState.isPinned(chat.id)
                    Button {
                        if pinned { ChatsLocalState.unpin(chat.id) }
                        else { ChatsLocalState.pin(chat.id) }
                        chatStateTick &+= 1
                    } label: {
                        Label(
                            pinned ? loc.t("chats_unpin") : loc.t("chats_pin"),
                            systemImage: pinned ? "pin.slash" : "pin"
                        )
                    }
                    Divider()
                    Button {
                        if peerId != nil { showingProfile = true }
                    } label: {
                        Label(loc.t("chat_open_profile"), systemImage: "person.crop.circle")
                    }
                    .disabled(peerId == nil)
                    Divider()
                    Button {
                        report()
                    } label: {
                        Label(loc.t("chat_report_user"), systemImage: "exclamationmark.bubble")
                    }
                    Button(role: .destructive) {
                        confirmBlock = true
                    } label: {
                        Label(loc.t("chat_block_user"), systemImage: "hand.raised.slash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            // Telegram-style: avatar + name in nav bar, tappable → opens profile
            ToolbarItem(placement: .principal) {
                ChatHeaderButton(
                    profile: other,
                    fallbackName: peerFallbackName,
                    taskTitle: chat.taskTitle,
                    subtitle: loc.t("chats_view_profile"),
                    canOpen: peerId != nil
                ) {
                    showingProfile = true
                }
            }
        }
        .navigationDestination(isPresented: $showingProfile) {
            if let otherId = peerId {
                UserProfileView(userId: otherId, fallback: nil)
            } else {
                EmptyView()
            }
        }
        .confirmationDialog(
            loc.t("chat_block_title"),
            isPresented: $confirmBlock,
            titleVisibility: .visible
        ) {
            Button(loc.t("chat_block_confirm"), role: .destructive) { block() }
            Button(loc.t("common_cancel"), role: .cancel) {}
        } message: {
            Text(loc.t("chat_block_message"))
        }
        .x5PhotoPicker(
            isPresented: $showingMediaPicker,
            limit: ChatAlbumGrouping.pickLimit,
            filter: .any(of: [.images, .videos])
        ) { providers in
            Task { await sendPickedMedia(providers) }
        }
        .fullScreenCover(item: $photoViewer) { state in
            ChatPhotoViewer(state: state, chatID: chat.id, service: service)
                // Явно передаём: картинки берут токен из Auth для подписанной ссылки.
                .environmentObject(auth)
        }
        .alert("Не отправилось", isPresented: Binding(
            get: { attachmentError != nil },
            set: { if !$0 { attachmentError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(attachmentError ?? "")
        }
        .alert("Не получилось", isPresented: Binding(
            get: { pinError != nil },
            set: { if !$0 { pinError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(pinError ?? "")
        }
        .sheet(isPresented: $showingStickers) {
            StickerTray { sticker in
                showingStickers = false
                sendSticker(sticker)
            }
            .presentationDetents([.medium])
            .preferredColorScheme(.dark)
        }
        .task {
            service.configureAccessTokenProvider(auth: auth)
            roomUnread = chat.unread ?? [:]
            // Paint cached messages instantly so the chat doesn't appear
            // blank during the fetch — Telegram-style.
            let cached = service.cachedMessages(chatId: chat.id)
            if !cached.isEmpty && messages.isEmpty {
                messages = cached
            }
            await reload()
            await refreshPin()
            await markThreadRead()
            await loadOther()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { break }
                await pollNewMessages()
                // Закреп собеседника подтягиваем раз в ~12 с — чаще не нужно, это лишний запрос.
                pollTick &+= 1
                if pollTick % 4 == 0 { await refreshPin() }
            }
        }
    }

    private var peerId: String? {
        guard let myId = auth.userId else { return nil }
        return chat.otherParticipantId(currentUser: myId)
    }

    private var peerFallbackName: String {
        guard let peerId, !peerId.isEmpty else { return loc.t("common_user") }
        return "ID " + String(peerId.prefix(6))
    }

    private var messagesPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if hasOlderMessages {
                        Button {
                            Task { await loadOlderMessages() }
                        } label: {
                            HStack(spacing: 8) {
                                if loadingOlderMessages { ProgressView().tint(.white) }
                                Text("Показать более ранние сообщения")
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.72))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .disabled(loadingOlderMessages)
                    }
                    // Подряд идущие фото одного человека — один пузырь-альбом (ChatAlbumGrouping).
                    ForEach(ChatAlbumGrouping.group(visibleMessages)) { item in
                        messageRow(item: item)
                    }
                    // Якорь «низ ленты»: прокручиваем к нему, а не к id сообщения —
                    // так работает, даже если последнее сообщение скрыто («удалить у себя»).
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchorID)
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 12)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .modifier(ChatBottomAnchorModifier())
            // Было: onChange(messages.count) → «Показать более ранние» тоже меняло
            // count и кидало ленту вниз; при открытии кэш и свежие данные одного
            // размера не вызывали прокрутку, чат оставался сверху/посередине.
            // Теперь следим за ПОСЛЕДНИМ видимым сообщением: подгрузка старых его не меняет.
            .onChange(of: visibleMessages.last?.id) { _ in
                scrollToBottom(proxy, animated: didInitialScroll)
                didInitialScroll = true
            }
            .onAppear {
                scrollToBottom(proxy, animated: false)
            }
            // Тап по плашке закрепа: прокрутка к сообщению по центру экрана.
            .onChange(of: scrollTargetID) { target in
                guard let target else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                    scrollTargetID = nil
                }
            }
            // Клавиатура открылась — поднимаем последние сообщения над ней.
            .onChange(of: inputFocused) { focused in
                guard focused else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    scrollToBottom(proxy, animated: true)
                }
            }
        }
    }

    private static let bottomAnchorID = "chat-bottom-anchor"

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        // Ждём один кадр: LazyVStack должен сначала разложить новые строки,
        // иначе scrollTo промахивается (типичный «прыжок не до конца»).
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func messageRow(item: ChatAlbumGrouping.Item) -> some View {
        let message = item.first
        if shouldShowDateHeader(at: item.startIndex) {
            DateDivider(text: dateHeaderText(for: message))
        }
        // У альбома время и галочки — по последнему фото, ответ/закреп — по первому
        // (или по тому, что уже закреплено). идея: меню на конкретном фото альбома.
        Bubble(
            message: item.last,
            album: item.isAlbum ? item.messages : nil,
            chatID: chat.id,
            service: service,
            isMine: message.senderId == auth.userId,
            isRead: isReadByPeer(item.last),
            isPinned: item.contains(pinnedMessageID),
            isHighlighted: item.contains(highlightedMessageID),
            deliveryState: deliveryState(for: item.last),
            onReply: { replyingTo = message },
            onTogglePin: {
                toggleMessagePin(item.messages.first(where: { $0.id == pinnedMessageID }) ?? message)
            },
            onRetry: { retry(messageID: item.last.id) },
            onDeleteForMe: {
                item.messages.forEach { MessagesLocalState.hide($0.id) }
                messageStateTick &+= 1
            },
            onOpenPhoto: { index in
                photoViewer = ChatPhotoViewerState(messages: item.messages, startIndex: index)
            }
        )
        .id(item.id)
        .simultaneousGesture(
            DragGesture(minimumDistance: 24, coordinateSpace: .local)
                .onEnded { value in
                    handleReplySwipe(value, message: message)
                }
        )
    }

    private func handleReplySwipe(_ value: DragGesture.Value, message: ChatMessageRow) {
        let horizontal = value.translation.width
        let vertical = abs(value.translation.height)
        guard horizontal > 56, abs(horizontal) > vertical * 1.5 else { return }
        replyingTo = message
    }

    private func replyBanner(for message: ChatMessageRow) -> some View {
        // Было: зелёная черта — отдельный Rectangle без высоты. Он жадный по вертикали
        // и делил место с лентой, поэтому плашка иногда раздувалась на пол-экрана
        // (баг Адильхана 09.10). Теперь черта — подложка текста и всегда равна его высоте.
        HStack(spacing: 10) {
            accentLabel(title: loc.t("chats_msg_reply"), preview: messagePreview(message))
            Spacer(minLength: 8)
            Button {
                replyingTo = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.white.opacity(0.45))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.white.opacity(0.05))
    }

    /// Заголовок + 1 строка превью с зелёной чертой слева (плашки «Ответить» и «Закреплено»).
    private func accentLabel(title: String, preview: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.accentColor)
            Text(preview.replacingOccurrences(of: "\n", with: " "))
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.65))
                .lineLimit(1)
        }
        .padding(.leading, 13)
        .overlay(alignment: .leading) {
            Capsule()
                .fill(Color.accentColor)
                .frame(width: 3)
        }
    }

    /// Закреплённое сообщение для плашки: из ленты, а если оно старше загруженного — отдельно с сервера.
    private var pinnedMessage: ChatMessageRow? {
        guard let pinnedMessageID else { return nil }
        return messages.first(where: { $0.id == pinnedMessageID })
            ?? (pinnedMessageFallback?.id == pinnedMessageID ? pinnedMessageFallback : nil)
    }

    /// Плашка сверху чата, как в Telegram: тап — к сообщению, булавка — открепить.
    @ViewBuilder
    private var pinnedBanner: some View {
        if let pinned = pinnedMessage {
            HStack(spacing: 10) {
                Button {
                    Task { await jumpToPinned() }
                } label: {
                    HStack(spacing: 0) {
                        accentLabel(title: loc.t("chats_pinned_banner_title"), preview: messagePreview(pinned))
                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button {
                    toggleMessagePin(pinned)
                } label: {
                    Image(systemName: "pin.slash")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white.opacity(0.55))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(loc.t("chats_msg_unpin"))
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color(red: 0.08, green: 0.08, blue: 0.14).opacity(0.92))
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            Button {
                showingMediaPicker = true
            } label: {
                ZStack {
                    if let attachmentUploadProgress {
                        ProgressView(value: attachmentUploadProgress)
                            .progressViewStyle(.circular)
                            .tint(.accentColor)
                    } else {
                        Image(systemName: "paperclip")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(.white.opacity(0.55))
                    }
                }
                .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .disabled(sending)
            .accessibilityLabel("Фото или видео, до \(ChatAlbumGrouping.pickLimit)")

            if recorder.isRecording {
                recordingIndicator
            } else {
                textComposer
            }

            sendOrVoiceButton
        }
        .padding(12)
        .background(Color.black.opacity(0.72).ignoresSafeArea(edges: .bottom))
    }

    /// «Отправка 3 из 10» над полем ввода, пока уходит пачка.
    @ViewBuilder
    private var mediaBatchBanner: some View {
        if let mediaBatchProgress {
            HStack(spacing: 8) {
                ProgressView()
                    .tint(.accentColor)
                Text(ChatAlbumGrouping.progressLabel(
                    current: mediaBatchProgress.current,
                    total: mediaBatchProgress.total
                ))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.8))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color.white.opacity(0.05))
        }
    }

    private var recordingIndicator: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
            Text(loc.t("chat_recording_hint"))
                .font(.system(size: 13))
                .foregroundColor(.white)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.red.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var textComposer: some View {
        HStack(spacing: 8) {
            TextField(loc.t("chats_message_placeholder"), text: $draft, axis: .vertical)
                .focused($inputFocused)
                .lineLimit(1...4)
            Button {
                showingStickers = true
            } label: {
                Image(systemName: "face.smiling")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundColor(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.08))
        .clipShape(Capsule())
    }

    @ViewBuilder
    private var sendOrVoiceButton: some View {
        if canSend {
            Button(action: send) {
                Image(systemName: sending ? "hourglass" : "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundColor(.accentColor)
            }
            .disabled(sending)
        } else {
            Image(systemName: recorder.isRecording ? "mic.circle.fill" : "mic.circle")
                .font(.system(size: 30))
                .foregroundColor(recorder.isRecording ? .red : .white.opacity(0.6))
                .opacity((sending || voiceSendInFlight) ? 0.35 : 1)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            beginVoicePress()
                        }
                        .onEnded { _ in
                            endVoicePress()
                        }
                )
                .allowsHitTesting(!sending && !voiceSendInFlight)
        }
    }

    /// Пачка из галереи (до 10, как в WhatsApp — Адильхан 10.10).
    /// Каждое фото/видео — отдельное сообщение: так пачку видят и старые версии
    /// приложения, и сайт, без миграции базы. Альбомом их склеивает уже показ.
    /// Строго по очереди, не параллельно: порядок в чате = порядок выбора.
    private func sendPickedMedia(_ providers: [NSItemProvider]) async {
        // Галерея больше 10 не даст, но лимит держим и тут.
        let batch = Array(providers.prefix(ChatAlbumGrouping.pickLimit))
        guard !batch.isEmpty, !sending else { return }
        sending = true
        defer {
            sending = false
            mediaBatchProgress = nil
        }

        var failures: [String] = []
        for (offset, provider) in batch.enumerated() {
            if batch.count > 1 {
                mediaBatchProgress = ChatMediaBatchProgress(current: offset + 1, total: batch.count)
            }
            let failure: String?
            if Self.isVideo(provider) {
                failure = await sendPickedVideo(provider)
            } else {
                failure = await sendPickedPhoto(provider)
            }
            // Одно не ушло — не молчим, но остальные всё равно отправляем.
            if let failure { failures.append(failure) }
        }

        guard let firstFailure = failures.first else { return }
        attachmentError = batch.count == 1
            ? firstFailure
            : "Не отправилось \(failures.count) из \(batch.count).\n\(firstFailure)"
    }

    private static func isVideo(_ provider: NSItemProvider) -> Bool {
        provider.registeredTypeIdentifiers.contains { identifier in
            guard let type = UTType(identifier) else { return false }
            return type.conforms(to: .movie) || type.conforms(to: .video)
        }
    }

    /// Новое сообщение — в ленту. merge, а не append: опрос сервера мог уже
    /// принести это же сообщение, пока мы ждали ответ (иначе будет дубль).
    private func appendSentMessage(_ inserted: ChatMessageRow) {
        messages = ChatMessageTimeline.merge(messages, with: [inserted])
        service.persistMessageCache(chatId: chat.id, rows: messages)
        incrementPeerUnread()
    }

    /// nil — фото ушло; иначе текст, почему нет (покажем после всей пачки).
    private func sendPickedPhoto(_ provider: NSItemProvider) async -> String? {
        // Токен берём на каждое фото: пачка из 10 может идти дольше жизни токена.
        guard let token = await auth.freshAccessToken(), let uid = auth.userId else {
            return "Сессия истекла. Войдите снова и повторите отправку."
        }
        let raw: Data
        do {
            raw = try await PickedPhotoLoader.loadMedia(from: provider).data
        } catch {
            return PickedPhotoLoader.errorText
        }
        // Ужатие как раньше (JPEG 0.82), но вне главного потока: 10 фото подряд не должны тормозить экран.
        let jpeg = await Task.detached(priority: .userInitiated) {
            UIImage(data: raw)?.jpegData(compressionQuality: 0.82)
        }.value
        guard let jpeg else { return "Не удалось прочитать фото." }

        guard let url = await service.uploadAttachment(
            chatId: chat.id,
            currentUserId: uid,
            data: jpeg,
            mime: "image/jpeg",
            ext: "jpg",
            accessToken: token
        ) else {
            return service.error ?? "Не удалось загрузить фото."
        }
        if let inserted = await service.sendMedia(chatId: chat.id, currentUserId: uid, type: "image", mediaUrl: url, mime: "image/jpeg", accessToken: token) {
            appendSentMessage(inserted)
            return nil
        }
        let failure = service.error ?? "Не удалось отправить фото."
        await service.deleteUploadedAttachment(
            canonicalURL: url,
            chatId: chat.id,
            currentUserId: uid,
            accessToken: token
        )
        return failure
    }

    /// nil — видео ушло; иначе текст ошибки. Видео грузится файлом (TUS, с докачкой), не в память.
    private func sendPickedVideo(_ provider: NSItemProvider) async -> String? {
        guard let initialToken = await auth.accessTokenForUpload(),
              let uid = auth.userId
        else {
            return "Сессия истекла. Войдите снова и повторите отправку."
        }

        attachmentUploadProgress = 0
        defer { attachmentUploadProgress = nil }

        let fileURL: URL
        do {
            fileURL = try await ChatPickedVideo.stage(from: provider)
        } catch {
            return "Не удалось подготовить видео: \(error.localizedDescription)"
        }
        defer { CourseVideoStaging.removeIfManaged(fileURL) }

        let format = chatVideoFormat(for: fileURL)
        guard let mediaURL = await service.uploadVideoAttachment(
            chatId: chat.id,
            currentUserId: uid,
            fileURL: fileURL,
            mime: format.mime,
            ext: format.ext,
            accessToken: initialToken,
            accessTokenProvider: { [weak auth] in
                await auth?.accessTokenForUpload()
            },
            progress: { progress in
                Task { @MainActor in
                    attachmentUploadProgress = progress
                }
            }
        ) else {
            return service.error ?? "Не удалось загрузить видео."
        }

        guard let postUploadToken = await auth.freshAccessToken() else {
            await service.deleteUploadedAttachment(
                canonicalURL: mediaURL,
                chatId: chat.id,
                currentUserId: uid,
                accessToken: initialToken
            )
            return "Видео загружено, но сессия истекла до отправки сообщения. Повторите отправку."
        }
        if let inserted = await service.sendMedia(
            chatId: chat.id,
            currentUserId: uid,
            type: "video",
            mediaUrl: mediaURL,
            mime: format.mime,
            accessToken: postUploadToken
        ) {
            appendSentMessage(inserted)
            return nil
        }
        let failure = service.error ?? "Не удалось отправить видео."
        await service.deleteUploadedAttachment(
            canonicalURL: mediaURL,
            chatId: chat.id,
            currentUserId: uid,
            accessToken: postUploadToken
        )
        return failure
    }

    private func chatVideoFormat(for url: URL) -> (mime: String, ext: String) {
        switch url.pathExtension.lowercased() {
        case "mov": return ("video/quicktime", "mov")
        case "m4v": return ("video/x-m4v", "m4v")
        default: return ("video/mp4", "mp4")
        }
    }

    private func sendVoice(_ result: (data: Data, mime: String, ext: String)) async {
        guard let token = await auth.freshAccessToken(), let uid = auth.userId else { return }
        let fingerprint = voiceFingerprint(result.data)
        let now = Date()
        if lastVoiceSendFingerprint == fingerprint,
           let lastAt = lastVoiceSendAt,
           now.timeIntervalSince(lastAt) < 8 {
            return
        }
        lastVoiceSendFingerprint = fingerprint
        lastVoiceSendAt = now

        sending = true
        defer { sending = false }
        guard let url = await service.uploadAttachment(
            chatId: chat.id,
            currentUserId: uid,
            data: result.data,
            mime: result.mime,
            ext: result.ext,
            accessToken: token
        ) else {
            clearVoiceFingerprint(fingerprint)
            attachmentError = service.error ?? "Не удалось загрузить голосовое."
            return
        }
        if let inserted = await service.sendMedia(chatId: chat.id, currentUserId: uid, type: "audio", mediaUrl: url, mime: result.mime, accessToken: token) {
            messages.append(inserted)
            service.persistMessageCache(chatId: chat.id, rows: messages)
            incrementPeerUnread()
        } else {
            clearVoiceFingerprint(fingerprint)
            await service.deleteUploadedAttachment(
                canonicalURL: url,
                chatId: chat.id,
                currentUserId: uid,
                accessToken: token
            )
            attachmentError = service.error ?? "Не удалось отправить голосовое."
        }
    }

    private func voiceFingerprint(_ data: Data) -> String {
        let head = data.prefix(96).map { String(format: "%02x", $0) }.joined()
        let tail = data.suffix(32).map { String(format: "%02x", $0) }.joined()
        return "\(data.count):\(head):\(tail)"
    }

    private func clearVoiceFingerprint(_ fingerprint: String) {
        guard lastVoiceSendFingerprint == fingerprint else { return }
        lastVoiceSendFingerprint = nil
        lastVoiceSendAt = nil
    }

    private func report() {
        let otherId = chat.otherParticipantId(currentUser: auth.userId ?? "") ?? "unknown"
        let subject = "Report user \(otherId)"
        let body = "Hi Xfive marketing team,\n\nI'd like to report this user. Please review their content.\n\nUser ID: \(otherId)\nChat ID: \(chat.id)\n"
        if let s = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let b = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let url = URL(string: "mailto:support@x5studio.app?subject=\(s)&body=\(b)") {
            UIApplication.shared.open(url)
        }
    }

    private func block() {
        guard let otherId = chat.otherParticipantId(currentUser: auth.userId ?? "") else { return }
        BlockList.add(otherId)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func reload() async {
        guard let token = await auth.freshAccessToken(), let uid = auth.userId else { return }
        let hasUnread = chat.unreadCount(for: uid) > 0
        messages = await service.loadMessages(chatId: chat.id, accessToken: token, forceRefresh: hasUnread)
        hasOlderMessages = messages.count >= ChatsService.messagePageSize
    }

    private func loadOlderMessages() async {
        guard !loadingOlderMessages,
              let oldest = messages.first(where: { !$0.id.hasPrefix("local-") })?.createdAt,
              let token = await auth.freshAccessToken()
        else { return }
        loadingOlderMessages = true
        defer { loadingOlderMessages = false }
        let page = await service.loadOlderMessages(
            chatId: chat.id,
            before: oldest,
            accessToken: token
        )
        messages = ChatMessageTimeline.merge(messages, with: page.rows)
        hasOlderMessages = page.hasMore
        service.persistMessageCache(chatId: chat.id, rows: messages)
    }

    private func pollNewMessages() async {
        guard let latest = messages.last(where: { !$0.id.hasPrefix("local-") })?.createdAt,
              let token = await auth.freshAccessToken()
        else { return }
        let incoming = await service.loadNewerMessages(
            chatId: chat.id,
            after: latest,
            accessToken: token
        )
        guard !incoming.isEmpty else { return }
        messages = ChatMessageTimeline.merge(messages, with: incoming)
        service.persistMessageCache(chatId: chat.id, rows: messages)
        if incoming.contains(where: { $0.senderId != auth.userId }) {
            await markThreadRead()
        }
    }

    private func loadOther() async {
        guard let token = await auth.freshAccessToken(),
              let otherId = peerId
        else { return }
        if let existing = other, existing.id == otherId { return }
        other = await service.loadPublicProfile(userId: otherId, accessToken: token)
    }

    /// Active filter applied to `messages` for rendering. Filtering happens at
    /// render time only — the underlying array stays intact so scroll/auto-
    /// scroll behaviour and message identity are unaffected when the search
    /// box closes.
    private var visibleMessages: [ChatMessageRow] {
        _ = messageStateTick
        let activeMessages = messages.filter { !MessagesLocalState.isHidden($0.id) }
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard searchActive, !q.isEmpty else { return activeMessages }
        return activeMessages.filter { msg in
            if let taskCard = msg.taskCard {
                return taskCard.copyText.localizedCaseInsensitiveContains(q)
                    || HubCategories.label(for: taskCard.category, language: loc.current).localizedCaseInsensitiveContains(q)
            }
            let parts = splitReplyText(msg.content)
            return parts.body.localizedCaseInsensitiveContains(q)
                || (parts.reply ?? "").localizedCaseInsensitiveContains(q)
        }
    }

    private func beginVoicePress() {
        guard !sending,
              !voiceSendInFlight,
              !voicePressActive,
              !voiceStartInFlight,
              !recorder.isRecording
        else { return }
        voicePressActive = true
        voiceStartInFlight = true
        Task {
            await recorder.start()
            voiceStartInFlight = false
            if !voicePressActive {
                recorder.cancel()
            }
        }
    }

    private func endVoicePress() {
        guard voicePressActive else { return }
        voicePressActive = false
        guard !sending, !voiceSendInFlight else {
            recorder.cancel()
            return
        }
        guard recorder.isRecording, let result = recorder.stop() else {
            recorder.cancel()
            return
        }
        voiceSendInFlight = true
        Task {
            defer { voiceSendInFlight = false }
            await sendVoice(result)
        }
    }

    private func markThreadRead() async {
        guard let token = await auth.freshAccessToken(), let uid = auth.userId else { return }
        if let updated = await service.markRead(chatId: chat.id, currentUserId: uid, accessToken: token) {
            roomUnread = updated.unread ?? [:]
        } else {
            roomUnread[uid] = 0
        }
    }

    private func incrementPeerUnread() {
        guard let uid = auth.userId,
              let peer = chat.otherParticipantId(currentUser: uid)
        else { return }
        let current = roomUnread[peer] ?? chat.unreadCount(for: peer)
        roomUnread[peer] = current + 1
    }

    private func isReadByPeer(_ message: ChatMessageRow) -> Bool {
        guard message.senderId == auth.userId,
              let uid = auth.userId,
              let peer = chat.otherParticipantId(currentUser: uid)
        else { return false }
        guard let peerUnread = roomUnread[peer] ?? chat.unread?[peer] else { return false }
        return peerUnread == 0
    }

    /// Закрепить / открепить. Сразу меняем экран, потом сервер; отказал — возвращаем как было.
    /// Новый закреп заменяет старый (один на чат, как в личке Telegram).
    private func toggleMessagePin(_ message: ChatMessageRow) {
        let previousID = pinnedMessageID
        let previousFallback = pinnedMessageFallback
        let nextID: String? = previousID == message.id ? nil : message.id
        pinnedMessageID = nextID
        if nextID != nil { pinnedMessageFallback = message }
        pinWriteInFlight = true
        Task {
            defer { pinWriteInFlight = false }
            guard let token = await auth.freshAccessToken() else {
                pinnedMessageID = previousID
                pinnedMessageFallback = previousFallback
                pinError = "Нет связи. Попробуйте ещё раз."
                return
            }
            let ok = await service.setPinnedMessage(chatId: chat.id, messageId: nextID, accessToken: token)
            guard !ok else { return }
            pinnedMessageID = previousID
            pinnedMessageFallback = previousFallback
            pinError = nextID == nil ? "Не удалось открепить сообщение." : "Не удалось закрепить сообщение."
        }
    }

    /// Читает закреп с сервера. Если сообщение старше загруженной ленты — берём его отдельно для превью.
    private func refreshPin() async {
        guard let token = await auth.freshAccessToken(),
              let state = await service.loadPinnedMessage(chatId: chat.id, accessToken: token),
              !pinWriteInFlight
        else { return }
        pinnedMessageID = state.messageId
        guard let id = state.messageId,
              !messages.contains(where: { $0.id == id }),
              pinnedMessageFallback?.id != id
        else { return }
        pinnedMessageFallback = await service.loadMessage(id: id, chatId: chat.id, accessToken: token)
    }

    /// Тап по плашке: если сообщения нет в ленте — догружаем старые страницы (до 10), потом прокрутка и подсветка.
    private func jumpToPinned() async {
        guard let id = pinnedMessageID else { return }
        var pages = 0
        while !visibleMessages.contains(where: { $0.id == id }), hasOlderMessages, pages < 10 {
            await loadOlderMessages()
            pages += 1
        }
        guard visibleMessages.contains(where: { $0.id == id }) else { return }
        // Закреплено фото из середины альбома — своей строки у него нет, крутим к альбому.
        scrollTargetID = ChatAlbumGrouping.anchorID(for: id, in: ChatAlbumGrouping.group(visibleMessages))
        highlightedMessageID = id
        try? await Task.sleep(nanoseconds: 1_400_000_000)
        if highlightedMessageID == id {
            withAnimation(.easeOut(duration: 0.3)) { highlightedMessageID = nil }
        }
    }

    private func messagePreview(_ message: ChatMessageRow) -> String {
        if let taskCard = message.taskCard {
            return taskCard.preview
        }
        let text = splitReplyText(message.content).body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            return text
        }
        switch message.type {
        case "image": return loc.t("chats_preview_photo")
        case "audio": return loc.t("chat_voice_message")
        case "video": return "Видео"
        default: return loc.t("chats_no_messages")
        }
    }

    private func encodedReplyText(_ text: String, replyingTo message: ChatMessageRow?) -> String {
        guard let message else { return text }
        let preview = messagePreview(message)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preview.isEmpty else { return text }
        return "\(replyLinePrefix)\(String(preview.prefix(120)))\n\(text)"
    }

    private func shouldShowDateHeader(at index: Int) -> Bool {
        guard visibleMessages.indices.contains(index),
              let current = messageDate(visibleMessages[index])
        else { return false }
        guard index > 0,
              let previous = messageDate(visibleMessages[index - 1])
        else { return true }
        return !Calendar.current.isDate(current, inSameDayAs: previous)
    }

    private func dateHeaderText(for message: ChatMessageRow) -> String {
        guard let date = messageDate(message) else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return loc.t("chats_date_today") }
        if cal.isDateInYesterday(date) { return loc.t("chats_date_yesterday") }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func messageDate(_ message: ChatMessageRow) -> Date? {
        guard let iso = message.createdAt, !iso.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }

    private func send() {
        guard let uid = auth.userId else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let outboundText = encodedReplyText(text, replyingTo: replyingTo)
        let localID = "local-\(UUID().uuidString)"
        let localMessage = ChatMessageRow(
            id: localID,
            chatId: chat.id,
            senderId: uid,
            type: "text",
            content: outboundText,
            mediaUrl: nil,
            mediaMime: nil,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
        messages = ChatMessageTimeline.merge(messages, with: [localMessage])
        pendingMessageIDs.insert(localID)
        failedTextMessages[localID] = nil
        service.persistMessageCache(chatId: chat.id, rows: messages)
        draft = ""
        replyingTo = nil
        inputFocused = false
        sending = true
        Task {
            await deliverText(
                localID: localID,
                currentUserID: uid,
                outboundText: outboundText,
                previewText: text
            )
            sending = false
        }
    }

    private func deliveryState(for message: ChatMessageRow) -> ChatDeliveryState {
        if pendingMessageIDs.contains(message.id) { return .sending }
        if failedTextMessages[message.id] != nil { return .failed }
        return .sent
    }

    private func retry(messageID: String) {
        guard let failed = failedTextMessages[messageID],
              let uid = auth.userId,
              !pendingMessageIDs.contains(messageID)
        else { return }
        failedTextMessages[messageID] = nil
        pendingMessageIDs.insert(messageID)
        sending = true
        Task {
            await deliverText(
                localID: messageID,
                currentUserID: uid,
                outboundText: failed.outboundText,
                previewText: failed.previewText
            )
            sending = false
        }
    }

    private func deliverText(
        localID: String,
        currentUserID: String,
        outboundText: String,
        previewText: String
    ) async {
        guard let token = await auth.freshAccessToken(),
              let inserted = await service.sendText(
                chatId: chat.id,
                currentUserId: currentUserID,
                text: outboundText,
                accessToken: token,
                previewText: previewText
              )
        else {
            pendingMessageIDs.remove(localID)
            failedTextMessages[localID] = FailedTextMessage(
                outboundText: outboundText,
                previewText: previewText
            )
            attachmentError = service.error ?? "Сообщение не отправилось. Нажмите на красный значок, чтобы повторить."
            return
        }

        pendingMessageIDs.remove(localID)
        failedTextMessages[localID] = nil
        messages.removeAll { $0.id == localID }
        messages = ChatMessageTimeline.merge(messages, with: [inserted])
        service.persistMessageCache(chatId: chat.id, rows: messages)
        incrementPeerUnread()
    }

    private func sendSticker(_ sticker: String) {
        guard let uid = auth.userId else { return }
        sending = true
        Task {
            guard let token = await auth.freshAccessToken() else {
                sending = false
                return
            }
            if let inserted = await service.sendText(
                chatId: chat.id,
                currentUserId: uid,
                text: "\(stickerLinePrefix)\(sticker)",
                accessToken: token,
                previewText: sticker
            ) {
                messages.append(inserted)
                service.persistMessageCache(chatId: chat.id, rows: messages)
                incrementPeerUnread()
            }
            sending = false
        }
    }
}

private let replyLinePrefix = "↪ "
private let stickerLinePrefix = "x5_sticker:"

private struct FailedTextMessage {
    let outboundText: String
    let previewText: String
}

/// Прогресс пачки из галереи: «Отправка current из total».
private struct ChatMediaBatchProgress: Equatable {
    let current: Int
    let total: Int
}

/// Что открыть на весь экран: все сообщения пузыря (альбом листается) и с какого начать.
private struct ChatPhotoViewerState: Identifiable {
    let id = UUID()
    let messages: [ChatMessageRow]
    let startIndex: Int
}

/// Видео из галереи UIKit → копия во временной папке (CourseVideoStaging).
/// Не читаем в память целиком, как PickedPhotoLoader.loadMedia: видео до 47 МБ,
/// а выбрать могут и больше — TUS-загрузке нужен файл, и он же даёт докачку.
private enum ChatPickedVideo {
    static func stage(from provider: NSItemProvider) async throws -> URL {
        let registered = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
        let movieType = registered.first { $0.conforms(to: .movie) || $0.conforms(to: .video) } ?? .movie
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: movieType.identifier) { url, error in
                // Файл системы живёт только внутри замыкания — копируем сразу.
                guard let url else {
                    continuation.resume(throwing: error ?? PickedPhotoLoader.LoadError.unreadable)
                    return
                }
                do {
                    continuation.resume(returning: try CourseVideoStaging.stage(sourceURL: url, lessonID: "chat"))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// iOS 17+: лента сама стартует снизу (как в Telegram), без мигания сверху.
/// На iOS 16 работает только scrollTo к якорю.
private struct ChatBottomAnchorModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.defaultScrollAnchor(.bottom)
        } else {
            content
        }
    }
}

private enum ChatDeliveryState: Equatable {
    case sending
    case sent
    case failed
}

private struct ChatHeaderButton: View {
    let profile: UserProfile?
    let fallbackName: String
    let taskTitle: String?
    let subtitle: String
    let canOpen: Bool
    let action: () -> Void

    private var title: String {
        profile?.displayName ?? fallbackName
    }

    var body: some View {
        Button {
            guard canOpen else { return }
            action()
        } label: {
            HStack(spacing: 8) {
                AvatarView(urlString: profile?.avatar, name: title, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                        if profile?.hasActiveVerifiedBadge == true {
                            VerifiedChip(size: 11)
                        }
                        if profile?.isPro == true {
                            Text("PRO")
                                .font(.system(size: 8, weight: .heavy))
                                .foregroundColor(.black)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.accentColor)
                                .clipShape(Capsule())
                        }
                    }
                    Text(secondaryText)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(taskTitle?.isEmpty == false ? 0.5 : 0.4))
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!canOpen)
    }

    private var secondaryText: String {
        guard let taskTitle, !taskTitle.isEmpty else { return subtitle }
        return taskTitle
    }
}

private func splitReplyText(_ content: String?) -> (reply: String?, body: String) {
    guard let content, !content.isEmpty else { return (nil, "") }
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
    guard let first = lines.first else { return (nil, content) }
    let firstLine = String(first)
    guard firstLine.hasPrefix(replyLinePrefix), lines.count > 1 else {
        return (nil, content)
    }
    let reply = String(firstLine.dropFirst(replyLinePrefix.count))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let body = lines.dropFirst()
        .map(String.init)
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !reply.isEmpty, !body.isEmpty else { return (nil, content) }
    return (reply, body)
}

private struct StickerTray: View {
    let onPick: (String) -> Void

    private let stickers = [
        "🌙", "✨", "🔥", "💎",
        "😂", "😍", "😭", "😎",
        "👍", "🙏", "❤️", "🚀",
        "🎯", "💸", "✅", "👀"
    ]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(stickers, id: \.self) { sticker in
                        Button {
                            onPick(sticker)
                        } label: {
                            Text(sticker)
                                .font(.system(size: 46))
                                .frame(maxWidth: .infinity)
                                .frame(height: 76)
                                .background(Color.white.opacity(0.07))
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .background(Color(red: 0.04, green: 0.05, blue: 0.10).ignoresSafeArea())
            .navigationTitle("Стикеры")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }
}

private struct DateDivider: View {
    let text: String

    var body: some View {
        HStack {
            Spacer()
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.58))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.08))
                .clipShape(Capsule())
            Spacer()
        }
        .padding(.vertical, 6)
    }
}

private struct Bubble: View {
    let message: ChatMessageRow
    /// 2+ фото пачкой — сетка в одном пузыре. message тогда — последнее фото (время, галочки).
    var album: [ChatMessageRow]? = nil
    let chatID: String
    let service: ChatsService
    let isMine: Bool
    let isRead: Bool
    let isPinned: Bool
    var isHighlighted: Bool = false
    let deliveryState: ChatDeliveryState
    var onCopy: (() -> Void)? = nil
    var onReply: (() -> Void)? = nil
    var onTogglePin: (() -> Void)? = nil
    var onRetry: (() -> Void)? = nil
    var onDeleteForMe: (() -> Void)? = nil
    /// Тап по фото → на весь экран; число — какое фото альбома открыть.
    var onOpenPhoto: ((Int) -> Void)? = nil
    @EnvironmentObject private var loc: LocalizationService

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isMine { Spacer(minLength: 40) }
            content
                .contextMenu {
                    if deliveryState == .failed {
                        Button { onRetry?() } label: {
                            Label("Отправить снова", systemImage: "arrow.clockwise")
                        }
                        Divider()
                    }
                    Button { onReply?() } label: {
                        Label(loc.t("chats_msg_reply"), systemImage: "arrowshape.turn.up.left")
                    }
                    // Закрепить можно только то, что уже дошло до сервера (у неотправленного нет id в базе).
                    if deliveryState == .sent, !message.id.hasPrefix("local-") {
                        Button { onTogglePin?() } label: {
                            Label(
                                isPinned ? loc.t("chats_msg_unpin") : loc.t("chats_msg_pin"),
                                systemImage: isPinned ? "pin.slash" : "pin"
                            )
                        }
                    }
                    // «Спросить StartupChat» убрали: Адильхан 09.10 — «непонятно, можно убрать».
                    Divider()
                    if !copyText.isEmpty,
                       !["image", "audio", "video"].contains(message.type) {
                        Button {
                            UIPasteboard.general.string = copyText
                            onCopy?()
                        } label: {
                            Label(loc.t("chats_msg_copy"), systemImage: "doc.on.doc")
                        }
                    }
                    Button(role: .destructive) {
                        onDeleteForMe?()
                    } label: {
                        Label(loc.t("chats_msg_delete_for_me"), systemImage: "trash")
                    }
                }
            if !isMine { Spacer(minLength: 40) }
        }
    }

    private var copyText: String {
        if let taskCard = message.taskCard {
            return taskCard.copyText
        }
        return splitReplyText(message.content).body
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isPinned {
                HStack(spacing: 4) {
                    Image(systemName: "pin.fill")
                    Text(loc.t("chats_pinned_label"))
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))
            }
            if let reply = splitReplyText(message.content).reply {
                ReplyPreview(text: reply)
            }
            payload
            HStack {
                Spacer(minLength: 8)
                messageStatus
            }
        }
        .padding(["image", "video"].contains(message.type) ? 4 : (stickerText == nil ? (message.type == "task_card" ? 8 : 10) : 2))
        .background(stickerText == nil ? bubbleColor : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        // Подсветка после тапа по плашке закрепа — видно, к какому сообщению прыгнули.
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.accentColor, lineWidth: isHighlighted ? 2 : 0)
        )
    }

    private var bubbleColor: Color {
        isMine ? Color(red: 0.08, green: 0.16, blue: 0.43) : Color(red: 0.14, green: 0.14, blue: 0.15)
    }

    @ViewBuilder
    private var payload: some View {
        switch message.type {
        case "image":
            if let album, album.count > 1 {
                PrivateChatAlbumBubble(messages: album, chatID: chatID, service: service) { index in
                    onOpenPhoto?(index)
                }
            } else {
                PrivateChatImageBubble(message: message, chatID: chatID, service: service)
                    .contentShape(Rectangle())
                    .onTapGesture { onOpenPhoto?(0) }
            }
        case "audio":
            PrivateChatAudioBubble(message: message, chatID: chatID, service: service)
        case "video":
            PrivateChatVideoBubble(message: message, chatID: chatID, service: service)
        case "task_card":
            if let card = message.taskCard {
                TaskCardBubble(card: card)
            } else {
                Text(loc.t("chats_no_messages"))
                    .font(.system(size: 15))
                    .foregroundColor(.white)
            }
        default:
            if let sticker = stickerText {
                Text(sticker)
                    .font(.system(size: 76))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
            } else {
                Text(splitReplyText(message.content).body)
                    .font(.system(size: 15))
                    .foregroundColor(.white)
            }
        }
    }

    private var stickerText: String? {
        let body = splitReplyText(message.content).body
        guard body.hasPrefix(stickerLinePrefix) else { return nil }
        return String(body.dropFirst(stickerLinePrefix.count))
    }

    private var messageStatus: some View {
        HStack(spacing: 4) {
            if let stamp = formattedTimestamp {
                Text(stamp)
            }
            if isMine {
                switch deliveryState {
                case .sending:
                    Image(systemName: "clock")
                case .failed:
                    Button { onRetry?() } label: {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                case .sent:
                    ReadReceipt(isRead: isRead)
                }
            }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundColor(.white.opacity(0.5))
    }

    /// Short relative-time label rendered inside text bubbles.
    /// Today → `HH:mm`. Yesterday → `Вчера HH:mm`. Older → `dd.MM`.
    private var formattedTimestamp: String? {
        guard let iso = message.createdAt, !iso.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return nil }
        let cal = Calendar.current
        let now = Date()
        let timeFmt = DateFormatter()
        timeFmt.locale = .current
        timeFmt.dateFormat = "HH:mm"
        if cal.isDateInToday(date) {
            return timeFmt.string(from: date)
        }
        if cal.isDateInYesterday(date) {
            return loc.t("chats_date_yesterday") + " " + timeFmt.string(from: date)
        }
        let dayFmt = DateFormatter()
        dayFmt.locale = .current
        dayFmt.dateFormat = (cal.component(.year, from: date) == cal.component(.year, from: now))
            ? "dd.MM"
            : "dd.MM.yy"
        return dayFmt.string(from: date)
    }

}

private struct ReplyPreview: View {
    let text: String
    @EnvironmentObject private var loc: LocalizationService

    var body: some View {
        HStack(spacing: 7) {
            Rectangle()
                .fill(Color.accentColor.opacity(0.9))
                .frame(width: 3)
                .clipShape(Capsule())
            VStack(alignment: .leading, spacing: 1) {
                Text(loc.t("chats_msg_reply"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color.accentColor)
                Text(text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.62))
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.16))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct TaskCardBubble: View {
    let card: ChatTaskCardPayload
    @EnvironmentObject private var loc: LocalizationService

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(HubCategories.label(for: card.category, language: loc.current).uppercased(), systemImage: HubCategories.symbol(for: card.category))
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundColor(Color.accentColor)
                    .lineLimit(1)
                Spacer(minLength: 10)
                if let budget = clean(card.budget) {
                    Text(budget)
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(card.title)
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let description = clean(card.description) {
                    Text(description)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.68))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "briefcase.fill")
                    .font(.system(size: 11, weight: .bold))
                Text("Отклик по заданию")
                    .font(.system(size: 12, weight: .bold))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .opacity(0.65)
            }
            .foregroundColor(.black)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.accentColor)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .frame(width: 266, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.055))
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 4)
                        .clipShape(Capsule())
                        .padding(.vertical, 12)
                }
        )
    }

    private func clean(_ value: String?) -> String? {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }
}

private struct ReadReceipt: View {
    let isRead: Bool
    @EnvironmentObject private var loc: LocalizationService

    var body: some View {
        ZStack {
            Image(systemName: "checkmark")
                .offset(x: isRead ? -3 : 0)
            if isRead {
                Image(systemName: "checkmark")
                    .offset(x: 3)
            }
        }
        .font(.system(size: 10, weight: .bold))
        .foregroundColor(isRead ? Color.accentColor : Color.white.opacity(0.58))
        .frame(width: isRead ? 15 : 9, height: 10)
        .accessibilityLabel(isRead ? loc.t("chats_msg_read") : loc.t("chats_msg_sent"))
    }
}

/// Одиночное фото в ленте (как было до альбомов).
private struct PrivateChatImageBubble: View {
    let message: ChatMessageRow
    let chatID: String
    let service: ChatsService

    var body: some View {
        ChatRemoteImage(message: message, chatID: chatID, service: service)
            .frame(maxWidth: 360, maxHeight: 480)
            .aspectRatio(3/4, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Пузырь-альбом, как в WhatsApp: 2 — в ряд, 3 — большое + 2, 4+ — 2×2 и «+N» на 4-й плитке.
private struct PrivateChatAlbumBubble: View {
    let messages: [ChatMessageRow]
    let chatID: String
    let service: ChatsService
    let onOpen: (Int) -> Void

    // 260 — как ширина альбома на сайте; влезает в самый узкий iPhone с iOS 16 (375 pt).
    private let width: CGFloat = 260
    private let spacing: CGFloat = 2

    var body: some View {
        let layout = ChatAlbumGrouping.layout(count: messages.count)
        let half = (width - spacing) / 2
        VStack(spacing: spacing) {
            switch layout.shape {
            case .pair:
                HStack(spacing: spacing) {
                    tile(0, width: half, height: half, extra: 0)
                    tile(1, width: half, height: half, extra: 0)
                }
            case .hero:
                tile(0, width: width, height: width * 0.75, extra: 0)
                HStack(spacing: spacing) {
                    tile(1, width: half, height: half, extra: 0)
                    tile(2, width: half, height: half, extra: 0)
                }
            case .grid:
                HStack(spacing: spacing) {
                    tile(0, width: half, height: half, extra: 0)
                    tile(1, width: half, height: half, extra: 0)
                }
                HStack(spacing: spacing) {
                    tile(2, width: half, height: half, extra: 0)
                    tile(3, width: half, height: half, extra: layout.extra)
                }
            }
        }
        .frame(width: width)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Альбом, фото: \(messages.count)")
    }

    @ViewBuilder
    private func tile(_ index: Int, width: CGFloat, height: CGFloat, extra: Int) -> some View {
        if messages.indices.contains(index) {
            ChatRemoteImage(message: messages[index], chatID: chatID, service: service)
                .frame(width: width, height: height)
                .clipped()
                .overlay {
                    if extra > 0 {
                        ZStack {
                            Color.black.opacity(0.55)
                            Text("+\(extra)")
                                .font(.system(size: 26, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                }
                .contentShape(Rectangle())
                // onTapGesture, а не Button: внутри плитки своя кнопка «Повторить».
                .onTapGesture { onOpen(index) }
        }
    }
}

/// Фото на весь экран. Альбом листается свайпом (TabView-страницы).
private struct ChatPhotoViewer: View {
    let state: ChatPhotoViewerState
    let chatID: String
    let service: ChatsService

    @Environment(\.dismiss) private var dismiss
    @State private var selection: Int

    init(state: ChatPhotoViewerState, chatID: String, service: ChatsService) {
        self.state = state
        self.chatID = chatID
        self.service = service
        _selection = State(initialValue: state.startIndex)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            TabView(selection: $selection) {
                ForEach(Array(state.messages.enumerated()), id: \.element.id) { pair in
                    ChatRemoteImage(message: pair.element, chatID: chatID, service: service, contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .tag(pair.offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            HStack {
                if state.messages.count > 1 {
                    Text("\(selection + 1) из \(state.messages.count)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .background(Color.white.opacity(0.15))
                        .clipShape(Circle())
                }
                .accessibilityLabel("Закрыть")
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .preferredColorScheme(.dark)
        // идея: щипок для зума и свайп вниз, чтобы закрыть, как в Telegram.
    }
}

/// Фото из приватного бакета чата: подписанная ссылка → кэш → картинка; не вышло — «Повторить».
/// Один загрузчик для пузыря, плиток альбома и полноэкранного просмотра.
private struct ChatRemoteImage: View {
    let message: ChatMessageRow
    let chatID: String
    let service: ChatsService
    /// .fill — плитка/пузырь (края обрезаем), .fit — весь кадр на экране просмотра.
    var contentMode: ContentMode = .fill

    @EnvironmentObject private var auth: Auth
    @State private var image: UIImage?
    @State private var isLoading = true
    @State private var failed = false
    @State private var requestVersion = 0

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if isLoading {
                (contentMode == .fit ? Color.clear : Color.white.opacity(0.06))
                    .overlay(ProgressView().tint(.white.opacity(0.5)))
            } else {
                Button {
                    requestVersion &+= 1
                } label: {
                    VStack(spacing: 7) {
                        Image(systemName: "arrow.clockwise")
                        Text("Повторить")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(.white.opacity(0.75))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.white.opacity(0.06))
                }
                .buttonStyle(.plain)
            }
        }
        .task(id: requestVersion) {
            await load(forceRefresh: requestVersion > 0)
        }
        .accessibilityLabel(failed ? "Вложение не загрузилось" : "Фото")
    }

    private func load(forceRefresh: Bool) async {
        guard let canonicalURL = message.mediaUrl,
              let currentUserID = auth.userId,
              let token = await auth.freshAccessToken()
        else {
            isLoading = false
            failed = true
            return
        }

        isLoading = true
        failed = false
        var signedURL = await service.signedMediaURL(
            canonicalURL: canonicalURL,
            chatId: chatID,
            currentUserId: currentUserID,
            accessToken: token,
            forceRefresh: forceRefresh
        )
        var loaded: UIImage?
        if let signedURL {
            loaded = await ImageCache.shared.image(for: signedURL)
        }

        // A signed URL can expire between resolving and downloading. Force one
        // fresh signature automatically; subsequent failure stays user-retryable.
        if loaded == nil, !forceRefresh, let freshToken = await auth.freshAccessToken() {
            service.invalidateSignedMedia(
                canonicalURL: canonicalURL,
                chatId: chatID,
                currentUserId: currentUserID
            )
            signedURL = await service.signedMediaURL(
                canonicalURL: canonicalURL,
                chatId: chatID,
                currentUserId: currentUserID,
                accessToken: freshToken,
                forceRefresh: true
            )
            if let signedURL {
                loaded = await ImageCache.shared.image(for: signedURL)
            }
        }

        guard !Task.isCancelled else { return }
        image = loaded
        failed = loaded == nil
        isLoading = false
    }
}

private struct PrivateChatVideoBubble: View {
    let message: ChatMessageRow
    let chatID: String
    let service: ChatsService

    @EnvironmentObject private var auth: Auth
    @State private var player: AVPlayer?
    @State private var isLoading = true
    @State private var failed = false
    @State private var requestVersion = 0

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .background(Color.black)
            } else if isLoading {
                Color.black
                    .overlay(ProgressView().tint(.white.opacity(0.65)))
            } else {
                Button {
                    requestVersion &+= 1
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 22, weight: .semibold))
                        Text("Повторить загрузку видео")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(.white.opacity(0.8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: 360)
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .task(id: requestVersion) {
            await resolvePlayer(forceRefresh: requestVersion > 0)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .AVPlayerItemFailedToPlayToEndTime
            )
        ) { note in
            guard let item = note.object as? AVPlayerItem,
                  item === player?.currentItem
            else { return }
            player?.pause()
            player = nil
            failed = true
            isLoading = false
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
        .accessibilityLabel(failed ? "Видео не загрузилось" : "Видео")
    }

    private func resolvePlayer(forceRefresh: Bool) async {
        guard let canonicalURL = message.mediaUrl,
              let currentUserID = auth.userId,
              let token = await auth.freshAccessToken()
        else {
            isLoading = false
            failed = true
            return
        }

        isLoading = true
        failed = false
        if forceRefresh {
            service.invalidateSignedMedia(
                canonicalURL: canonicalURL,
                chatId: chatID,
                currentUserId: currentUserID
            )
        }
        guard let signedURL = await service.signedMediaURL(
            canonicalURL: canonicalURL,
            chatId: chatID,
            currentUserId: currentUserID,
            accessToken: token,
            forceRefresh: forceRefresh
        ) else {
            isLoading = false
            failed = true
            return
        }
        guard !Task.isCancelled else { return }
        player = AVPlayer(url: signedURL)
        isLoading = false
    }
}

// Голосовое в чате: ▶/⏸ + ползунок (тянуть пальцем = перемотка) + «0:12 / 0:40».
// Просьба Адильхана 08.10 «надо ползунок сделать», как в WhatsApp/Telegram.
// Одновременно играет одно голосовое; после конца — снова ▶ и ползунок в начале.
extension Notification.Name {
    /// object = id сообщения, которое начало играть; остальные голосовые встают на паузу.
    static let x5VoiceMessageDidStart = Notification.Name("x5VoiceMessageDidStart")
}

enum VoiceMessageTime {
    /// «0:07», «1:05». NaN/∞/минус → «0:00».
    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Длительность из текста сообщения: сайт пишет «12s», здесь бывает «0:12».
    /// Нужна, пока файл не загрузился (или если webm с сайта не читается).
    static func parse(_ content: String?) -> Double {
        let text = (content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasSuffix("s"), let value = Double(text.dropLast()) { return max(0, value) }
        let parts = text.split(separator: ":")
        if parts.count == 2, let m = Double(parts[0]), let s = Double(parts[1]) { return m * 60 + s }
        return 0
    }
}

/// Часы плеера: следит за временем AVPlayer 10 раз в секунду.
private final class VoicePlaybackClock: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    var isScrubbing = false

    private weak var observedPlayer: AVPlayer?
    private var observer: Any?

    func attach(to player: AVPlayer) {
        guard observedPlayer !== player else { return }
        detach()
        observedPlayer = player
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self, !self.isScrubbing, time.seconds.isFinite else { return }
            self.currentTime = time.seconds
        }
        Task { @MainActor in await self.loadDuration(of: player) }
    }

    func detach() {
        if let observer, let observedPlayer {
            observedPlayer.removeTimeObserver(observer)
        }
        observer = nil
        observedPlayer = nil
    }

    @MainActor
    private func loadDuration(of player: AVPlayer) async {
        guard let asset = player.currentItem?.asset,
              let value = try? await asset.load(.duration),
              value.isNumeric, value.seconds.isFinite, value.seconds > 0
        else { return }
        duration = value.seconds
    }
}

private struct PrivateChatAudioBubble: View {
    let message: ChatMessageRow
    let chatID: String
    let service: ChatsService

    @EnvironmentObject private var loc: LocalizationService
    @EnvironmentObject private var auth: Auth
    @StateObject private var clock = VoicePlaybackClock()
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var isLoading = false
    @State private var failed = false
    @State private var retriedExpiredURL = false
    @State private var wasPlayingBeforeScrub = false

    /// Длина из файла, а пока её нет — из текста сообщения.
    private var duration: Double {
        clock.duration > 0 ? clock.duration : VoiceMessageTime.parse(message.content)
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                Task { await togglePlay() }
            } label: {
                Image(systemName: isLoading ? "clock" : (isPlaying ? "pause.circle.fill" : "play.circle.fill"))
                    .font(.system(size: 32))
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
            .accessibilityLabel(isPlaying ? "Пауза" : loc.t("chat_voice_message"))

            VStack(alignment: .leading, spacing: 0) {
                Slider(
                    value: Binding(
                        get: { min(clock.currentTime, max(duration, 0.01)) },
                        set: { newValue in
                            clock.currentTime = newValue
                            seek(to: newValue)
                        }
                    ),
                    in: 0...max(duration, 0.01),
                    onEditingChanged: scrubbingChanged
                )
                .tint(.white)
                // Пока длина неизвестна, тянуть нечего.
                .disabled(duration <= 0 || isLoading)
                .accessibilityLabel("Перемотка голосового")
                .accessibilityValue("\(VoiceMessageTime.format(clock.currentTime)) из \(VoiceMessageTime.format(duration))")

                HStack(spacing: 6) {
                    Text("\(VoiceMessageTime.format(clock.currentTime)) / \(VoiceMessageTime.format(duration))")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundColor(.white.opacity(0.75))
                    if failed {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.65))
                    }
                }
            }
            // Было width: 170 — пузырь шире, справа оставалась пустота (Адильхан 09.10).
            // Теперь полоска тянется на всю ширину пузыря, но не уже 170.
            .frame(minWidth: 170, maxWidth: .infinity, alignment: .leading)
        }
        .task(id: message.id) {
            // Как в WhatsApp: длина видна до нажатия ▶. Ссылка кешируется в сервисе.
            await preparePlayer(forceRefresh: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .x5VoiceMessageDidStart)) { note in
            guard let startedID = note.object as? String, startedID != message.id, isPlaying else { return }
            player?.pause()
            isPlaying = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { note in
            guard let item = note.object as? AVPlayerItem, item === player?.currentItem else { return }
            isPlaying = false
            player?.seek(to: .zero)
            clock.currentTime = 0
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)) { note in
            guard let item = note.object as? AVPlayerItem, item === player?.currentItem else { return }
            isPlaying = false
            failed = true
            guard !retriedExpiredURL else { return }
            retriedExpiredURL = true
            Task { await startPlayback(forceRefresh: true) }
        }
        .onDisappear {
            player?.pause()
            clock.detach()
            player = nil
            isPlaying = false
        }
    }

    private func scrubbingChanged(_ editing: Bool) {
        if editing {
            clock.isScrubbing = true
            wasPlayingBeforeScrub = isPlaying
            player?.pause()
        } else {
            seek(to: clock.currentTime)
            clock.isScrubbing = false
            if wasPlayingBeforeScrub {
                player?.play()
            }
        }
    }

    private func seek(to seconds: Double) {
        guard let player else { return }
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func togglePlay() async {
        if isPlaying {
            player?.pause()
            isPlaying = false
        } else {
            await startPlayback(forceRefresh: failed)
        }
    }

    /// Достаёт подписанную ссылку и создаёт плеер (без звука). true — плеер готов.
    @discardableResult
    private func preparePlayer(forceRefresh: Bool) async -> Bool {
        guard let canonicalURL = message.mediaUrl,
              let currentUserID = auth.userId,
              let token = await auth.freshAccessToken()
        else {
            return false
        }
        if forceRefresh {
            service.invalidateSignedMedia(
                canonicalURL: canonicalURL,
                chatId: chatID,
                currentUserId: currentUserID
            )
        }
        guard let signedURL = await service.signedMediaURL(
            canonicalURL: canonicalURL,
            chatId: chatID,
            currentUserId: currentUserID,
            accessToken: token,
            forceRefresh: forceRefresh
        ) else {
            return false
        }
        let currentURL = (player?.currentItem?.asset as? AVURLAsset)?.url
        if player == nil || currentURL != signedURL {
            let newPlayer = AVPlayer(url: signedURL)
            // Новая ссылка (старая истекла) — продолжаем с того же места.
            if clock.currentTime > 0 {
                // completionHandler — чтобы в async-функции не выбрался async-вариант seek.
                newPlayer.seek(to: CMTime(seconds: clock.currentTime, preferredTimescale: 600)) { _ in }
            }
            player = newPlayer
            clock.attach(to: newPlayer)
        }
        return true
    }

    private func startPlayback(forceRefresh: Bool) async {
        isLoading = true
        guard await preparePlayer(forceRefresh: forceRefresh) else {
            isLoading = false
            failed = true
            return
        }

        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        NotificationCenter.default.post(name: .x5VoiceMessageDidStart, object: message.id)
        player?.play()
        isPlaying = true
        isLoading = false
        failed = false
    }
}
