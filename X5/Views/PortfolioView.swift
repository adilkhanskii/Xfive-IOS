import SwiftUI
import PhotosUI
import AVKit
import AVFoundation
import UniformTypeIdentifiers

/// Instagram-style portfolio feed. Used inside ProfileView (own) and UserProfileView (public).
enum PortfolioGridMode: Equatable {
    case posts
    case saved
}

struct PortfolioGrid: View {
    let userId: String
    let canEdit: Bool
    var mode: PortfolioGridMode = .posts

    @EnvironmentObject private var auth: Auth
    @StateObject private var service = PortfolioService()
    @State private var showingAdd = false
    @State private var selectedIndex: Int?
    @State private var showingPostViewer = false
    @State private var pinnedTick = 0

    private var orderedItems: [PortfolioItem] {
        if mode == .saved { return service.items }
        _ = pinnedTick
        let pinned = service.items.filter { PortfolioPinnedStore.isPinned($0.id) }
            .sorted { (PortfolioPinnedStore.index(of: $0.id) ?? 99) < (PortfolioPinnedStore.index(of: $1.id) ?? 99) }
        let rest = service.items.filter { !PortfolioPinnedStore.isPinned($0.id) }
        return pinned + rest
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(mode == .saved ? "Сохранённые" : "Портфолио")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                if canEdit && mode == .posts {
                    Button {
                        showingAdd = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                            Text("Добавить")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.accentColor)
                    }
                }
            }

            if service.items.isEmpty && !service.isLoading {
                VStack(spacing: 6) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 28, weight: .light))
                        .foregroundColor(.white.opacity(0.4))
                    Text(mode == .saved ? "Здесь будут сохранённые работы" : (canEdit ? "Загрузи свои работы" : "Портфолио пустое"))
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3),
                    spacing: 3
                ) {
                    ForEach(Array(orderedItems.enumerated()), id: \.element.id) { index, item in
                        PortfolioGridCell(
                            item: item,
                            isPinned: mode == .posts && PortfolioPinnedStore.isPinned(item.id),
                            onOpen: {
                                X5Feedback.selection()
                                selectedIndex = index
                                showingPostViewer = true
                            }
                        )
                    }
                }
            }
        }
        .task {
            guard let token = await auth.freshAccessToken() else { return }
            if mode == .saved {
                await service.loadSaved(userId: userId, accessToken: token)
            } else {
                await service.load(userId: userId, accessToken: token, includeUnapproved: canEdit)
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddPortfolioItemView { data, mediaType, mime, ext, thumbnailData, thumbnailHasCover, title, desc in
                guard let token = await auth.freshAccessToken() else { return false }
                return await service.addMedia(
                    data: data,
                    type: mediaType,
                    mime: mime,
                    ext: ext,
                    thumbnailData: thumbnailData,
                    thumbnailHasCover: thumbnailHasCover,
                    userId: userId,
                    title: title,
                    description: desc,
                    accessToken: token
                )
            }
            .preferredColorScheme(.dark)
        }
        .fullScreenCover(isPresented: $showingPostViewer) {
            PortfolioInstagramViewer(
                items: orderedItems,
                initialIndex: selectedIndex ?? 0,
                canEdit: canEdit && mode == .posts,
                authorForItem: { item in service.authors[item.userId] },
                onDelete: { item in
                    Task {
                        guard let token = await auth.freshAccessToken() else { return }
                        await service.delete(itemId: item.id, accessToken: token)
                    }
                    showingPostViewer = false
                },
                onTogglePin: { item in
                    PortfolioPinnedStore.toggle(item.id)
                    pinnedTick += 1
                },
                onUpdateDetails: { item, title, description, newCover in
                    guard let token = await auth.freshAccessToken() else { return nil }
                    var newThumbnail: Data?
                    if let newCover {
                        // Новая обложка + кадры из текущего превью: автопроверка
                        // по-прежнему видит кадры самого видео, а не только обложку.
                        guard let current = await service.thumbnailData(for: item, accessToken: token),
                              let composed = PortfolioVideoCover.recompose(
                                cover: newCover,
                                currentThumbnail: current,
                                currentHasCover: item.hasVideoCover
                              )
                        else { return nil }
                        newThumbnail = composed
                    }
                    return await service.updateDetails(
                        itemId: item.id,
                        title: title,
                        description: description,
                        newVideoThumbnail: newThumbnail,
                        ownerId: item.userId,
                        accessToken: token
                    )
                },
                isPinned: { item in
                    PortfolioPinnedStore.isPinned(item.id)
                },
                onLoadLike: { item in
                    guard let uid = auth.userId,
                          let token = await auth.freshAccessToken()
                    else {
                        return PortfolioLikeState(isLiked: false, count: 0)
                    }
                    return await service.likeState(itemId: item.id, currentUserId: uid, accessToken: token)
                },
                onSetLiked: { item, liked in
                    guard let uid = auth.userId,
                          let token = await auth.freshAccessToken()
                    else { return false }
                    return await service.setLiked(itemId: item.id, liked: liked, currentUserId: uid, accessToken: token)
                },
                onLoadSaved: { item in
                    guard let uid = auth.userId,
                          let token = await auth.freshAccessToken()
                    else { return PortfolioSaveState(isSaved: false) }
                    return await service.saveState(itemId: item.id, userId: uid, accessToken: token)
                },
                onSetSaved: { item, saved in
                    guard let uid = auth.userId,
                          let token = await auth.freshAccessToken()
                    else { return false }
                    let ok = await service.setSaved(itemId: item.id, saved: saved, userId: uid, accessToken: token)
                    if ok, mode == .saved, !saved {
                        await service.loadSaved(userId: uid, accessToken: token)
                    }
                    return ok
                },
                onLoadComments: { item in
                    guard let token = await auth.freshAccessToken() else { return [] }
                    return await service.loadComments(itemId: item.id, accessToken: token)
                },
                onAddComment: { item, text in
                    guard let uid = auth.userId,
                          let token = await auth.freshAccessToken()
                    else { return nil }
                    // Раньше сюда шёл email — он показывался всем под комментарием.
                    // Теперь имя/ник подставляет сервис из profiles.
                    return await service.addComment(itemId: item.id,
                                                    userId: uid,
                                                    userName: nil,
                                                    userAvatar: nil,
                                                    text: text,
                                                    accessToken: token)
                },
                currentUserId: auth.userId,
                onEditComment: { comment, text in
                    guard let token = await auth.freshAccessToken() else { return nil }
                    return await service.editComment(comment, newText: text, accessToken: token)
                },
                onDeleteComment: { comment in
                    guard let token = await auth.freshAccessToken() else { return false }
                    return await service.deleteComment(commentId: comment.id, accessToken: token)
                }
            )
            .preferredColorScheme(.dark)
        }
    }
}

private enum PortfolioPinnedStore {
    private static let key = "x5.portfolio.pinned.ids"

    static func ids() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func isPinned(_ id: String) -> Bool {
        ids().contains(id)
    }

    static func index(of id: String) -> Int? {
        ids().firstIndex(of: id)
    }

    static func toggle(_ id: String) {
        var current = ids()
        if let index = current.firstIndex(of: id) {
            current.remove(at: index)
        } else {
            current.insert(id, at: 0)
            current = Array(current.prefix(3))
        }
        UserDefaults.standard.set(current, forKey: key)
    }
}

private struct PortfolioGridCell: View {
    let item: PortfolioItem
    let isPinned: Bool
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            // Размер плитки задаёт пустой фон 3:4, а картинка — наложение поверх.
            // Раньше картинка сама была внутри ZStack и раздувала плитку: у видео
            // с обложкой превью высокое (обложка + кадры снизу), и плитка
            // растягивалась на весь экран — обложка сверху, кадры снизу (Адильхан 10.10).
            Color.white.opacity(0.055)
                .aspectRatio(3 / 4, contentMode: .fit)
                .overlay { tileContent }
                .clipped()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var tileContent: some View {
        ZStack {
            if item.type == "video" {
                // Раньше плитка видео была чёрной: превью видео — это сетка
                // кадров для автопроверки, её не показывали. Теперь — обложка.
                PortfolioVideoTileCover(item: item)
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))
                    .shadow(color: .black.opacity(0.45), radius: 6)
            } else if let s = imageURLString, let url = URL(string: s) {
                CachedAsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    ProgressView().tint(.white.opacity(0.5))
                }
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white.opacity(0.42))
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.48)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack {
                HStack {
                    if item.needsModerationBadge {
                        PortfolioModerationBadge(item: item)
                    }
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 12, weight: .black))
                            .foregroundColor(.white)
                            .padding(6)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                    Spacer()
                    // Второй значок ▶ в углу убран (Адильхан 09.10): хватает
                    // одного большого по центру.
                }
                Spacer()
                if let title = item.title, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .shadow(color: .black.opacity(0.7), radius: 4, x: 0, y: 2)
                }
            }
            .padding(7)
        }
    }

    private var imageURLString: String? {
        if let thumbnail = item.displayThumbnailUrl, !thumbnail.isEmpty { return thumbnail }
        return item.displayMediaUrl
    }
}

// MARK: - Обложка видео

/// Обложка видео в сетке портфолио.
/// 1) Новое превью «…-cover.jpg»: сверху обложка 3:4, снизу кадры для автопроверки —
///    показываем только верх (scaledToFill + выравнивание по верху, низ обрезается).
/// 2) Старые видео: превью — только сетка кадров, как обложка не годится. Берём кадр
///    прямо из видео на телефоне (AVAssetImageGenerator) и кэшируем на сессию.
private struct PortfolioVideoTileCover: View {
    let item: PortfolioItem
    @State private var videoFrame: UIImage?

    var body: some View {
        ZStack {
            Color.black.opacity(0.42)
            if item.hasVideoCover, let s = item.signedThumbnailUrl, let url = URL(string: s) {
                CachedAsyncImage(url: url) { image in
                    PortfolioCoverTopCrop(image: image)
                } placeholder: {
                    Color.clear
                }
            } else if let videoFrame {
                Image(uiImage: videoFrame)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: item.id) {
            guard !item.hasVideoCover, videoFrame == nil,
                  let s = item.displayMediaUrl, let url = URL(string: s)
            else { return }
            videoFrame = await PortfolioVideoFrameCache.shared.frame(itemId: item.id, videoURL: url)
        }
    }
}

/// Верх склейки «обложка 3:4 + кадры» на весь размер рамки.
/// Зачем (Адильхан 10.10 18:01, скрин «тоже баг»): было `.scaledToFill()` +
/// `.frame(maxHeight: .infinity, alignment: .top)` — длинная картинка растягивала
/// рамку до своей высоты, и плитка показывала середину: низ обложки + кадры видео.
/// Color.clear берёт ровно размер плитки, картинка прижата к верху, низ обрезается.
struct PortfolioCoverTopCrop: View {
    let image: Image

    var body: some View {
        Color.clear
            .overlay(alignment: .top) {
                image
                    .resizable()
                    .scaledToFill()
            }
            .clipped()
    }
}

/// Кадр из видео для старых кейсов без обложки. Кэш живёт, пока открыто приложение.
@MainActor
private final class PortfolioVideoFrameCache {
    static let shared = PortfolioVideoFrameCache()
    private var frames: [String: UIImage] = [:]

    func frame(itemId: String, videoURL: URL) async -> UIImage? {
        if let cached = frames[itemId] { return cached }
        let image = await Task.detached(priority: .utility) { () -> UIImage? in
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 540, height: 540)
            // Не самый первый кадр: он часто чёрный.
            generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
            let time = CMTime(seconds: 0.5, preferredTimescale: 600)
            guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
            return UIImage(cgImage: cgImage)
        }.value
        if let image { frames[itemId] = image }
        return image
    }
}

/// Склейка превью видео: обложка 3:4 сверху + сетка кадров снизу.
/// Зачем одна картинка: автопроверка (moderate-portfolio) смотрит thumbnail_url —
/// так она видит и обложку, и кадры видео; новая колонка и миграция не нужны.
enum PortfolioVideoCover {
    static let width: CGFloat = 1200
    static var coverHeight: CGFloat { (width * 4 / 3).rounded() }

    static func compose(cover: UIImage, frameSheet: UIImage?) -> Data? {
        let sheetHeight: CGFloat
        if let frameSheet, frameSheet.size.width > 0 {
            sheetHeight = (frameSheet.size.height * width / frameSheet.size.width).rounded()
        } else {
            sheetHeight = 0
        }
        let size = CGSize(width: width, height: coverHeight + sheetHeight)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { context in
            context.cgContext.setFillColor(UIColor.black.cgColor)
            context.cgContext.fill(CGRect(origin: .zero, size: size))

            let coverRect = CGRect(x: 0, y: 0, width: width, height: coverHeight)
            let scale = max(
                coverRect.width / max(cover.size.width, 1),
                coverRect.height / max(cover.size.height, 1)
            )
            let drawSize = CGSize(width: cover.size.width * scale, height: cover.size.height * scale)
            let drawRect = CGRect(
                x: coverRect.midX - drawSize.width / 2,
                y: coverRect.midY - drawSize.height / 2,
                width: drawSize.width,
                height: drawSize.height
            )
            context.cgContext.saveGState()
            context.cgContext.clip(to: coverRect)
            cover.draw(in: drawRect)
            context.cgContext.restoreGState()

            if let frameSheet, sheetHeight > 0 {
                frameSheet.draw(in: CGRect(x: 0, y: coverHeight, width: width, height: sheetHeight))
            }
        }
        return rendered.jpegData(compressionQuality: 0.8)
    }

    /// Смена обложки: кадры берём из текущего превью (у новых — низ склейки,
    /// у старых — вся сетка кадров). Без кадров не склеиваем: иначе автопроверка
    /// увидела бы только обложку, а не само видео.
    static func recompose(cover: UIImage, currentThumbnail: Data, currentHasCover: Bool) -> Data? {
        guard let current = UIImage(data: currentThumbnail) else { return nil }
        let sheet: UIImage
        if currentHasCover {
            guard let cgImage = current.cgImage else { return nil }
            let pixelWidth = CGFloat(cgImage.width)
            let coverPixels = (pixelWidth * 4 / 3).rounded()
            let remaining = CGFloat(cgImage.height) - coverPixels
            guard remaining >= 1,
                  let cropped = cgImage.cropping(
                    to: CGRect(x: 0, y: coverPixels, width: pixelWidth, height: remaining)
                  )
            else { return nil }
            sheet = UIImage(cgImage: cropped)
        } else {
            sheet = current
        }
        return compose(cover: cover, frameSheet: sheet)
    }
}

private struct PortfolioModerationBadge: View {
    let item: PortfolioItem

    var body: some View {
        Label(item.moderationBadgeTitle, systemImage: symbol)
            .font(.system(size: 10, weight: .heavy))
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .foregroundColor(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(background)
            .clipShape(Capsule())
    }

    private var symbol: String {
        switch item.moderationStatus {
        case "rejected": return "xmark.octagon.fill"
        case "pending", "manual_review", "failed":
            return "arrow.clockwise.circle.fill"
        default: return "shield.checkered"
        }
    }

    private var foreground: Color {
        item.moderationStatus == "rejected" ? .white : .black
    }

    private var background: Color {
        switch item.moderationStatus {
        case "rejected": return .red
        case "pending", "manual_review", "failed": return .accentColor
        default: return Color(red: 0.38, green: 0.88, blue: 0.54)
        }
    }
}

private struct PortfolioInstagramViewer: View {
    let items: [PortfolioItem]
    let initialIndex: Int
    let canEdit: Bool
    let authorForItem: (PortfolioItem) -> PortfolioAuthor?
    let onDelete: (PortfolioItem) -> Void
    let onTogglePin: (PortfolioItem) -> Void
    /// Последний параметр — новая обложка видео (nil — не меняли).
    let onUpdateDetails: (PortfolioItem, String?, String?, UIImage?) async -> PortfolioItem?
    let isPinned: (PortfolioItem) -> Bool
    let onLoadLike: (PortfolioItem) async -> PortfolioLikeState
    let onSetLiked: (PortfolioItem, Bool) async -> Bool
    let onLoadSaved: (PortfolioItem) async -> PortfolioSaveState
    let onSetSaved: (PortfolioItem, Bool) async -> Bool
    let onLoadComments: (PortfolioItem) async -> [PortfolioComment]
    let onAddComment: (PortfolioItem, String) async -> PortfolioComment?
    /// Кто смотрит: свои комментарии можно изменить и удалить.
    let currentUserId: String?
    let onEditComment: (PortfolioComment, String) async -> PortfolioComment?
    let onDeleteComment: (PortfolioComment) async -> Bool

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            PortfolioInstagramPostPage(
                                item: item,
                                author: authorForItem(item),
                                canEdit: canEdit,
                                isPinned: isPinned(item),
                                onDelete: { onDelete(item) },
                                onTogglePin: { onTogglePin(item) },
                                onUpdateDetails: { title, description, newCover in
                                    await onUpdateDetails(item, title, description, newCover)
                                },
                                onLoadLike: { await onLoadLike(item) },
                                onSetLiked: { liked in await onSetLiked(item, liked) },
                                onLoadSaved: { await onLoadSaved(item) },
                                onSetSaved: { saved in await onSetSaved(item, saved) },
                                onLoadComments: { await onLoadComments(item) },
                                onAddComment: { text in await onAddComment(item, text) },
                                currentUserId: currentUserId,
                                onEditComment: onEditComment,
                                onDeleteComment: onDeleteComment
                            )
                            .id(item.id)
                            .frame(width: UIScreen.main.bounds.width)
                            .frame(minHeight: UIScreen.main.bounds.height)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .background(Color.black)
                .onAppear {
                    guard items.indices.contains(initialIndex) else { return }
                    proxy.scrollTo(items[initialIndex].id, anchor: .top)
                }
            }
            .navigationTitle("Портфолио")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Готово") {
                        X5Feedback.selection()
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct PortfolioInstagramPostPage: View {
    let item: PortfolioItem
    let author: PortfolioAuthor?
    let canEdit: Bool
    let isPinned: Bool
    let onDelete: () -> Void
    let onTogglePin: () -> Void
    let onUpdateDetails: (String?, String?, UIImage?) async -> PortfolioItem?
    let onLoadLike: () async -> PortfolioLikeState
    let onSetLiked: (Bool) async -> Bool
    let onLoadSaved: () async -> PortfolioSaveState
    let onSetSaved: (Bool) async -> Bool
    let onLoadComments: () async -> [PortfolioComment]
    let onAddComment: (String) async -> PortfolioComment?
    let currentUserId: String?
    let onEditComment: (PortfolioComment, String) async -> PortfolioComment?
    let onDeleteComment: (PortfolioComment) async -> Bool

    @State private var likeState = PortfolioLikeState(isLiked: false, count: 0)
    /// Свой комментарий, который сейчас правим в поле ввода (nil — пишем новый).
    @State private var editingComment: PortfolioComment?
    /// Свой комментарий, для которого открыт вопрос «Удалить?».
    @State private var commentToDelete: PortfolioComment?
    @State private var comments: [PortfolioComment] = []
    @State private var commentDraft = ""
    @State private var busyLike = false
    @State private var sendingComment = false
    @State private var isSaved = false
    @State private var busySave = false
    @State private var confirmDelete = false
    @State private var showingEdit = false
    // «Монтаж видео» и локальный «Лайк» комментария убраны (Адильхан 09.10:
    // «лишнее убрать»): монтажа нет, а лайк комментария никуда не сохранялся.
    @State private var player: AVPlayer?
    /// Тап по значку комментария ставит курсор в поле ввода.
    @FocusState private var commentFieldFocused: Bool
    /// Поделиться: ссылка на файл живёт 10 минут, поэтому делимся самим файлом.
    @State private var shareFileURL: URL?
    @State private var showingShare = false
    @State private var preparingShare = false
    @State private var shareError: String?
    @State private var showAllComments = false
    @State private var commentError: String?

    private var maxMediaHeight: CGFloat {
        let screen = UIScreen.main.bounds
        return min(screen.width * 1.06, screen.height * 0.54)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            authorHeader
            media
                .frame(maxWidth: .infinity)
                .frame(height: maxMediaHeight)
                .background(Color.white.opacity(0.04))
                .clipped()

            VStack(alignment: .leading, spacing: 12) {
                actionRow
                captionBlock
                commentsView
                commentInput
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 18)
        }
        .background(Color.black)
        .task {
            likeState = await onLoadLike()
            isSaved = (await onLoadSaved()).isSaved
            comments = await onLoadComments()
            if item.type == "video", let s = item.displayMediaUrl, let url = URL(string: s) {
                player = AVPlayer(url: url)
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
            if let shareFileURL {
                try? FileManager.default.removeItem(at: shareFileURL)
            }
            shareFileURL = nil
        }
        .confirmationDialog("Удалить кейс?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                X5Feedback.warning()
                onDelete()
            }
            Button("Отмена", role: .cancel) {}
        }
        .sheet(isPresented: $showingEdit) {
            EditPortfolioItemView(item: item, onSave: onUpdateDetails)
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showingShare) {
            if let shareFileURL {
                PortfolioShareSheet(activityItems: [shareFileURL])
            }
        }
        .alert(
            "Не удалось поделиться",
            isPresented: Binding(
                get: { shareError != nil },
                set: { if !$0 { shareError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(shareError ?? "")
        }
    }

    private var authorHeader: some View {
        HStack(spacing: 10) {
            Group {
                if let avatar = author?.avatar, let url = URL(string: avatar) {
                    CachedAsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: "person.fill").foregroundColor(.white.opacity(0.55))
                    }
                } else {
                    Image(systemName: "person.fill")
                        .foregroundColor(.white.opacity(0.55))
                }
            }
            .frame(width: 34, height: 34)
            .background(Color.white.opacity(0.1))
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(authorDisplayName)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                if let nickname = author?.nickname, !nickname.isEmpty {
                    Text("@\(nickname)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                }
            }
            Spacer()
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.accentColor)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var authorDisplayName: String {
        guard let name = author?.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty
        else { return "Xfive marketing" }
        return name
    }

    @ViewBuilder
    private var media: some View {
        if item.type == "video", let player {
            VideoPlayer(player: player)
        } else if let s = item.displayMediaUrl, let url = URL(string: s) {
            CachedAsyncImage(url: url) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                ProgressView().tint(.white)
            }
        } else {
            Image(systemName: "photo")
                .font(.system(size: 56, weight: .light))
                .foregroundColor(.white.opacity(0.45))
        }
    }

    private var actionRow: some View {
        HStack(spacing: 16) {
            Button {
                Task { await toggleLike() }
            } label: {
                Image(systemName: likeState.isLiked ? "heart.fill" : "heart")
                    .foregroundStyle(likeState.isLiked ? Color.red : Color.white)
            }
            .disabled(busyLike)

            // Раньше значок был просто картинкой — тап ничего не делал.
            Button {
                commentFieldFocused = true
            } label: {
                Image(systemName: "bubble.right")
            }

            if item.moderationStatus == "approved" {
                // Раньше делились подписанной ссылкой на файл — она умирает через
                // 10 минут. Теперь скачиваем файл и отдаём в системное «Поделиться».
                Button {
                    Task { await prepareShare() }
                } label: {
                    if preparingShare {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "paperplane")
                    }
                }
                .disabled(preparingShare)
            }

            Spacer()

            Button {
                Task { await toggleSaved() }
            } label: {
                Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
            }
            .disabled(busySave)

            if canEdit {
                Button {
                    showingEdit = true
                } label: {
                    Image(systemName: "pencil")
                }

                Menu {
                    Button {
                        X5Feedback.selection()
                        onTogglePin()
                    } label: {
                        Label(isPinned ? "Открепить" : "Закрепить", systemImage: isPinned ? "pin.slash" : "pin")
                    }
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("Удалить", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .font(.system(size: 25, weight: .semibold))
        .foregroundColor(.white)
    }

    private var captionBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Плашку «Автопроверка пройдена» больше не показываем (Адильхан 09.10):
            // она лишняя. Плашка остаётся, только если кейс ждёт проверку или отклонён.
            if item.needsModerationBadge {
                VStack(alignment: .leading, spacing: 4) {
                    PortfolioModerationBadge(item: item)
                    Text(item.moderationReason?.isEmpty == false ? item.moderationReason! : "Автоматическая проверка будет повторена.")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.62))
                }
                .padding(.bottom, 4)
            }
            if likeState.count > 0 {
                Text("\(likeState.count) отметок \"Нравится\"")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
            }
            if let title = item.title, !title.isEmpty {
                Text(title)
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundColor(.white)
            }
            if let description = item.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(.white.opacity(0.82))
            }
        }
    }

    private var commentsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Раньше надпись «Посмотреть все» была просто текстом, а показывались
            // только первые 6 — остальные комментарии нельзя было открыть.
            if comments.count > 6 && !showAllComments {
                Button("Посмотреть все комментарии: \(comments.count)") {
                    showAllComments = true
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.52))
            }
            ForEach(showAllComments ? Array(comments) : Array(comments.prefix(6))) { comment in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "person.crop.circle.fill")
                        .foregroundColor(.white.opacity(0.5))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(commentAuthorName(comment))
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white.opacity(0.65))
                        Text(comment.text)
                            .font(.system(size: 13))
                            .foregroundColor(.white)
                        HStack(spacing: 14) {
                            Button("Ответить") {
                                editingComment = nil
                                commentDraft = "@\(commentAuthorName(comment)) "
                                commentFieldFocused = true
                            }
                            // Свой комментарий: кнопки видно сразу, без долгого нажатия —
                            // Адильхан не нашёл, как изменить или удалить (10.10 18:03).
                            if isOwnComment(comment) {
                                Button("Изменить") { startEditing(comment) }
                                Button("Удалить") { commentToDelete = comment }
                            }
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.48))
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .contextMenu {
                    if isOwnComment(comment) {
                        Button {
                            startEditing(comment)
                        } label: {
                            Label("Изменить", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            commentToDelete = comment
                        } label: {
                            Label("Удалить", systemImage: "trash")
                        }
                    }
                }
            }
            if let commentError {
                Text(commentError)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.red.opacity(0.9))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog(
            "Удалить комментарий?",
            isPresented: Binding(
                get: { commentToDelete != nil },
                set: { if !$0 { commentToDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: commentToDelete
        ) { comment in
            Button("Удалить", role: .destructive) {
                Task { await deleteComment(comment) }
            }
            Button("Отмена", role: .cancel) {}
        }
    }

    private func isOwnComment(_ comment: PortfolioComment) -> Bool {
        guard let currentUserId else { return false }
        return comment.userId.lowercased() == currentUserId.lowercased()
    }

    private func startEditing(_ comment: PortfolioComment) {
        editingComment = comment
        commentDraft = comment.text
        commentError = nil
        commentFieldFocused = true
    }

    private func deleteComment(_ comment: PortfolioComment) async {
        commentError = nil
        if await onDeleteComment(comment) {
            comments.removeAll { $0.id == comment.id }
            if editingComment?.id == comment.id {
                editingComment = nil
                commentDraft = ""
            }
            X5Feedback.success()
        } else {
            commentError = "Не удалось удалить комментарий. Проверьте интернет и попробуйте ещё раз."
            X5Feedback.error()
        }
    }

    private func commentAuthorName(_ comment: PortfolioComment) -> String {
        if let name = comment.userName, !name.isEmpty { return name }
        return "Пользователь"
    }

    private var commentInput: some View {
        VStack(alignment: .leading, spacing: 6) {
            if editingComment != nil {
                HStack(spacing: 8) {
                    Label("Изменение комментария", systemImage: "pencil")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.6))
                    Spacer()
                    Button("Отмена") {
                        editingComment = nil
                        commentDraft = ""
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .bold))
                }
            }
            commentInputRow
        }
    }

    private var commentInputRow: some View {
        HStack(spacing: 8) {
            TextField("Комментарий...", text: $commentDraft)
                .focused($commentFieldFocused)
                .textFieldStyle(.plain)
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.10))
                .clipShape(Capsule())
            Button {
                Task { await sendComment() }
            } label: {
                Image(systemName: sendingComment
                      ? "hourglass"
                      : (editingComment == nil ? "arrow.up.circle.fill" : "checkmark.circle.fill"))
                    .font(.system(size: 28))
            }
            .disabled(commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sendingComment)
        }
        .foregroundColor(.accentColor)
    }

    private func toggleLike() async {
        guard !busyLike else { return }
        busyLike = true
        defer { busyLike = false }
        let next = !likeState.isLiked
        X5Feedback.selection()
        guard await onSetLiked(next) else { return }
        likeState = PortfolioLikeState(isLiked: next, count: max(0, likeState.count + (next ? 1 : -1)))
    }

    private func toggleSaved() async {
        guard !busySave else { return }
        busySave = true
        defer { busySave = false }
        let next = !isSaved
        X5Feedback.selection()
        guard await onSetSaved(next) else { return }
        isSaved = next
    }

    private func sendComment() async {
        let text = commentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sendingComment else { return }
        sendingComment = true
        defer { sendingComment = false }
        commentError = nil
        if let editing = editingComment {
            guard text != editing.text else {
                editingComment = nil
                commentDraft = ""
                return
            }
            if let updated = await onEditComment(editing, text) {
                // Сервер не умеет править на месте — новый комментарий встаёт в конец.
                comments.removeAll { $0.id == editing.id }
                comments.append(updated)
                editingComment = nil
                commentDraft = ""
                X5Feedback.success()
            } else {
                commentError = "Не удалось изменить комментарий. Проверьте интернет и попробуйте ещё раз."
                X5Feedback.error()
            }
            return
        }
        if let comment = await onAddComment(text) {
            comments.append(comment)
            commentDraft = ""
            X5Feedback.success()
        } else {
            // Раньше при ошибке ничего не происходило — казалось, что кнопка не работает.
            commentError = "Не удалось отправить комментарий. Проверьте интернет и попробуйте ещё раз."
            X5Feedback.error()
        }
    }

    /// Скачиваем фото/видео кейса во временный файл и открываем «Поделиться».
    private func prepareShare() async {
        guard !preparingShare,
              let s = item.displayMediaUrl, let remoteURL = URL(string: s)
        else { return }
        if let shareFileURL, FileManager.default.fileExists(atPath: shareFileURL.path) {
            showingShare = true
            return
        }
        preparingShare = true
        defer { preparingShare = false }
        do {
            let (tempURL, response) = try await URLSession.shared.download(from: remoteURL)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            // Расширение берём из пути хранилища, иначе «Поделиться» не поймёт тип файла.
            let ext = URL(string: item.mediaUrl ?? "")?.pathExtension ?? ""
            let fallbackExt = item.type == "video" ? "mov" : "jpg"
            let fileName = "Xfive-\(item.id.prefix(8)).\(ext.isEmpty ? fallbackExt : ext)"
            let target = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: tempURL, to: target)
            shareFileURL = target
            showingShare = true
        } catch {
            shareError = "Проверьте интернет и попробуйте ещё раз."
        }
    }
}

/// Системное окно «Поделиться» для файла кейса.
private struct PortfolioShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

private struct EditPortfolioItemView: View {
    let item: PortfolioItem
    /// Последний параметр — новая обложка видео (nil — не меняли).
    let onSave: (String?, String?, UIImage?) async -> PortfolioItem?

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var description: String
    @State private var newCover: UIImage?
    @State private var saving = false
    @State private var errorText: String?

    init(item: PortfolioItem, onSave: @escaping (String?, String?, UIImage?) async -> PortfolioItem?) {
        self.item = item
        self.onSave = onSave
        _title = State(initialValue: item.title ?? "")
        _description = State(initialValue: item.description ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Кейс") {
                    TextField("Название", text: $title)
                    TextField("Описание", text: $description, axis: .vertical)
                        .lineLimit(3...7)
                }
                if item.type == "video" {
                    // Вместо подсказки про «монтаж» (его нет) — смена обложки видео.
                    Section {
                        PortfolioCoverPickerRow(
                            cover: $newCover,
                            currentCoverURL: item.hasVideoCover
                                ? item.signedThumbnailUrl.flatMap { URL(string: $0) }
                                : nil,
                            fallbackFrame: nil
                        )
                    } header: {
                        Text("Обложка видео")
                    } footer: {
                        Text("Обложку видно в сетке портфолио. После смены кейс снова пройдёт автопроверку.")
                    }
                }
                if let errorText {
                    Section {
                        Text(errorText)
                            .foregroundColor(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(red: 0.04, green: 0.05, blue: 0.10))
            .navigationTitle("Редактировать")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if saving { ProgressView() } else { Text("Сохранить").bold() }
                    }
                    .disabled(saving)
                }
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if await onSave(cleanTitle.isEmpty ? nil : cleanTitle,
                        cleanDescription.isEmpty ? nil : cleanDescription,
                        newCover) != nil {
            X5Feedback.success()
            dismiss()
        } else {
            X5Feedback.error()
            errorText = newCover == nil
                ? "Не удалось сохранить."
                : "Не удалось сохранить обложку. Проверьте интернет и попробуйте ещё раз."
        }
    }
}

/// Выбор обложки видео из галереи (Адильхан 09.10: «ставить обложку для видео»).
/// Одна строка Form: обе кнопки .borderless и одна галерея на строку — иначе
/// в Form тап срабатывает на всех кнопках строки и галерея «моргает» (как было в CourseUP).
private struct PortfolioCoverPickerRow: View {
    @Binding var cover: UIImage?
    /// Обложка с сервера — показываем, пока не выбрали новую.
    let currentCoverURL: URL?
    /// Кадр из видео, который станет обложкой, если свою не выбрать.
    let fallbackFrame: UIImage?

    @State private var showingPicker = false
    @State private var loading = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                showingPicker = true
            } label: {
                ZStack {
                    Color.white.opacity(0.06)
                    if let cover {
                        Image(uiImage: cover).resizable().scaledToFill()
                    } else if let currentCoverURL {
                        CachedAsyncImage(url: currentCoverURL) { image in
                            PortfolioCoverTopCrop(image: image)
                        } placeholder: {
                            ProgressView().tint(.white)
                        }
                    } else if let fallbackFrame {
                        Image(uiImage: fallbackFrame).resizable().scaledToFill()
                    } else {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 28, weight: .light))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    if loading {
                        Color.black.opacity(0.4)
                        ProgressView().tint(.white)
                    }
                }
                .frame(width: 120, height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.borderless)
            .disabled(loading)
            .frame(maxWidth: .infinity)

            Button {
                showingPicker = true
            } label: {
                Label(cover == nil ? "Выбрать обложку из галереи" : "Заменить обложку",
                      systemImage: "photo.on.rectangle")
            }
            .buttonStyle(.borderless)
            .disabled(loading)

            if let errorText {
                Text(errorText)
                    .font(.footnote)
                    .foregroundColor(.red)
            }
        }
        // Галерея через UIKit: SwiftUI-шная перезапускалась при перерисовке (Адильхан 10.10).
        .x5SinglePhotoPicker(isPresented: $showingPicker) { provider in
            Task { await load(provider) }
        }
    }

    private func load(_ provider: NSItemProvider) async {
        loading = true
        errorText = nil
        do {
            let prepared = try await PickedPhotoLoader.loadPrepared(from: provider)
            cover = prepared.preview
        } catch {
            errorText = PickedPhotoLoader.errorText
        }
        loading = false
    }
}

// MARK: - Add item

/// Результат подготовки видео: сетка кадров для автопроверки + кадр для обложки.
private struct PortfolioVideoPreview: Sendable {
    let sheet: Data
    let coverFrameJPEG: Data?
}

struct AddPortfolioItemView: View {
    /// (файл, тип, mime, расширение, превью, «у превью есть обложка», название, описание)
    let onSave: (Data, String, String, String, Data?, Bool, String?, String?) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var mediaItem: PhotosPickerItem?
    @State private var mediaData: Data?
    @State private var videoThumbnailData: Data?
    /// Кадр из видео — обложка по умолчанию.
    @State private var videoCoverFrame: UIImage?
    /// Обложка, которую автор выбрал сам.
    @State private var pickedCover: UIImage?
    @State private var mediaType: String = "image"
    @State private var mime: String = "image/jpeg"
    @State private var ext: String = "jpg"
    @State private var title: String = ""
    @State private var description: String = ""
    @State private var saving = false
    @State private var preparingMedia = false
    @State private var mediaPreparationGeneration = 0
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PhotosPicker(selection: $mediaItem, matching: .any(of: [.images, .videos])) {
                        if preparingMedia {
                            VStack(spacing: 10) {
                                ProgressView()
                                Text("Подготавливаем медиа…")
                                    .font(.system(size: 15, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity, minHeight: 160)
                        } else if mediaType == "video", let image = pickedCover ?? videoCoverFrame {
                            // Показываем обложку, а не служебную сетку кадров.
                            ZStack {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxHeight: 220)
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 44, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .shadow(radius: 6)
                            }
                        } else if mediaType == "video", mediaData != nil {
                            VStack(spacing: 10) {
                                Image(systemName: "play.rectangle.fill")
                                    .font(.system(size: 44, weight: .semibold))
                                Text("Видео выбрано")
                                    .font(.system(size: 15, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity, minHeight: 160)
                        } else if let data = mediaData, let ui = UIImage(data: data) {
                            Image(uiImage: ui)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 220)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        } else {
                            HStack {
                                Image(systemName: "photo.on.rectangle.angled")
                                Text("Выбрать фото или видео")
                            }
                            .frame(maxWidth: .infinity, minHeight: 100)
                        }
                    }
                    .onChange(of: mediaItem) { newValue in
                        mediaPreparationGeneration += 1
                        let generation = mediaPreparationGeneration
                        preparingMedia = newValue != nil
                        mediaData = nil
                        videoThumbnailData = nil
                        videoCoverFrame = nil
                        pickedCover = nil
                        errorText = nil
                        Task { await loadMedia(newValue, generation: generation) }
                    }
                }

                if mediaType == "video", mediaData != nil {
                    Section {
                        PortfolioCoverPickerRow(
                            cover: $pickedCover,
                            currentCoverURL: nil,
                            fallbackFrame: videoCoverFrame
                        )
                    } header: {
                        Text("Обложка видео")
                    } footer: {
                        Text("Обложку видно в сетке портфолио. Если не выбрать — возьмём кадр из видео.")
                    }
                }

                Section("Описание") {
                    TextField("Название (опц.)", text: $title)
                    TextField("Кейс / описание (опц.)", text: $description, axis: .vertical)
                        .lineLimit(2...5)
                }

                if let err = errorText {
                    Section { Text(err).foregroundColor(.red) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(red: 0.04, green: 0.05, blue: 0.10))
            .navigationTitle("Добавить в портфолио")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if saving { ProgressView() } else { Text("Сохранить").bold() }
                    }
                    .disabled(saving || preparingMedia || mediaData == nil)
                }
            }
        }
    }

    private func save() async {
        guard !preparingMedia, let data = mediaData else { return }
        saving = true
        defer { saving = false }
        let titleTrim = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let descTrim = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let thumbnail = videoThumbnailForUpload()
        let ok = await onSave(
            data,
            mediaType,
            mime,
            ext,
            thumbnail.data,
            thumbnail.hasCover,
            titleTrim.isEmpty ? nil : titleTrim,
            descTrim.isEmpty ? nil : descTrim
        )
        if ok {
            dismiss()
        } else {
            errorText = "Не удалось сохранить. Попробуй ещё раз."
        }
    }

    /// Превью видео для загрузки: обложка (своя или кадр) сверху + сетка кадров
    /// снизу — автопроверка видит и то и другое (см. PortfolioVideoCover).
    private func videoThumbnailForUpload() -> (data: Data?, hasCover: Bool) {
        guard mediaType == "video", let sheetData = videoThumbnailData else {
            return (videoThumbnailData, false)
        }
        if let cover = pickedCover ?? videoCoverFrame,
           let composed = PortfolioVideoCover.compose(cover: cover, frameSheet: UIImage(data: sheetData)) {
            return (composed, true)
        }
        return (videoThumbnailData, false)
    }

    /// Re-encode picked image as JPEG ≤1.5MB to keep uploads fast.
    private func compress(_ data: Data) -> Data {
        guard let image = UIImage(data: data) else { return data }
        let maxSide: CGFloat = 1600
        let s = image.size
        let scale = min(maxSide / max(s.width, s.height), 1)
        let target = CGSize(width: s.width * scale, height: s.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        return resized.jpegData(compressionQuality: 0.82) ?? data
    }

    private func loadMedia(_ item: PhotosPickerItem?, generation: Int) async {
        guard let item else {
            guard generation == mediaPreparationGeneration else { return }
            preparingMedia = false
            return
        }
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            guard generation == mediaPreparationGeneration else { return }
            preparingMedia = false
            errorText = "Не удалось подготовить выбранный файл."
            return
        }
        guard generation == mediaPreparationGeneration else { return }

        let contentType = item.supportedContentTypes.first
        if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) || $0.conforms(to: .video) }) {
            let videoMime = contentType?.preferredMIMEType ?? "video/quicktime"
            let videoExtension = contentType?.preferredFilenameExtension ?? "mov"
            let thumbnail = await makeVideoThumbnail(from: data, fileExtension: videoExtension)
            guard generation == mediaPreparationGeneration else { return }
            mediaType = "video"
            mime = videoMime
            ext = videoExtension
            videoThumbnailData = thumbnail?.sheet
            videoCoverFrame = thumbnail?.coverFrameJPEG.flatMap { UIImage(data: $0) }
            mediaData = data
        } else {
            let compressed = compress(data)
            guard generation == mediaPreparationGeneration else { return }
            mediaType = "image"
            mime = "image/jpeg"
            ext = "jpg"
            videoThumbnailData = nil
            mediaData = compressed
        }
        preparingMedia = false
    }

    private func makeVideoThumbnail(from data: Data, fileExtension: String) async -> PortfolioVideoPreview? {
        await Task.detached(priority: .userInitiated) {
            await Self.generateVideoThumbnail(from: data, fileExtension: fileExtension)
        }.value
    }

    /// This pipeline owns every UIKit value inside one detached task and only
    /// crosses the actor boundary with immutable Data.
    nonisolated private static func generateVideoThumbnail(
        from data: Data,
        fileExtension: String
    ) async -> PortfolioVideoPreview? {
        let safeExtension = fileExtension.isEmpty ? "mov" : fileExtension
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("portfolio-preview-\(UUID().uuidString)")
            .appendingPathExtension(safeExtension)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        do {
            try data.write(to: fileURL, options: .atomic)
            let asset = AVURLAsset(url: fileURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1280, height: 1280)

            let duration = try await asset.load(.duration)
            let durationSeconds = duration.seconds
            let thumbnailSampleCount = 12
            let thumbnailFractions: [Double] = (0..<thumbnailSampleCount)
                .map { (Double($0) + 0.5) / Double(thumbnailSampleCount) }
            let requestedSeconds = durationSeconds.isFinite && durationSeconds > 0
                ? thumbnailFractions.map { min(max($0 * durationSeconds, 0), durationSeconds) }
                : [0.0]

            var frames: [UIImage] = []
            for seconds in requestedSeconds {
                let time = CMTime(seconds: seconds, preferredTimescale: 600)
                if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                    frames.append(UIImage(cgImage: cgImage))
                }
            }
            guard let sheet = makeVideoContactSheet(from: frames) else { return nil }
            // Первый кадр выборки (≈4% длины, не чёрный нулевой) — обложка по умолчанию.
            let coverFrameJPEG = frames.first?.jpegData(compressionQuality: 0.85)
            return PortfolioVideoPreview(sheet: sheet, coverFrameJPEG: coverFrameJPEG)
        } catch {
            return nil
        }
    }

    nonisolated private static func makeVideoContactSheet(from frames: [UIImage]) -> Data? {
        let previewFrames = Array(frames.prefix(12))
        guard !previewFrames.isEmpty else { return nil }

        let columns = 4
        let rows = Int(ceil(Double(previewFrames.count) / Double(columns)))
        let tileSize = CGSize(width: 300, height: 300)
        let sheetSize = CGSize(
            width: tileSize.width * CGFloat(columns),
            height: tileSize.height * CGFloat(rows)
        )
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: sheetSize, format: format)
        let contactSheet = renderer.image { context in
            context.cgContext.setFillColor(UIColor.black.cgColor)
            context.cgContext.fill(CGRect(origin: .zero, size: sheetSize))

            for (index, image) in previewFrames.enumerated() {
                let tile = CGRect(
                    x: CGFloat(index % columns) * tileSize.width,
                    y: CGFloat(index / columns) * tileSize.height,
                    width: tileSize.width,
                    height: tileSize.height
                )
                let scale = max(
                    tile.width / max(image.size.width, 1),
                    tile.height / max(image.size.height, 1)
                )
                let drawSize = CGSize(
                    width: image.size.width * scale,
                    height: image.size.height * scale
                )
                let drawRect = CGRect(
                    x: tile.midX - drawSize.width / 2,
                    y: tile.midY - drawSize.height / 2,
                    width: drawSize.width,
                    height: drawSize.height
                )

                context.cgContext.saveGState()
                context.cgContext.clip(to: tile)
                image.draw(in: drawRect)
                context.cgContext.restoreGState()
            }
        }
        return contactSheet.jpegData(compressionQuality: 0.78)
    }
}
