import AVKit
import SwiftUI

struct AICloudGalleryView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var auth: Auth

    @State private var assets: [AIStudioAsset] = []
    @State private var selectedAsset: AIStudioAsset?
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let service = AIStudioService()
    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Загружаем результаты…")
                        .tint(Color.accentColor)
                        .foregroundStyle(.white)
                } else if assets.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(assets) { asset in
                                Button {
                                    selectedAsset = asset
                                } label: {
                                    assetCell(asset)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(16)
                    }
                    .refreshable { await load() }
                }
            }
            .background { X5Background() }
            .navigationTitle("Облачная галерея")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Обновить") { Task { await load() } }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
            .overlay(alignment: .bottom) {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(Color.red.opacity(0.82), in: Capsule())
                        .padding(.bottom, 12)
                }
            }
            .fullScreenCover(item: $selectedAsset) { asset in
                AICloudAssetPreview(asset: asset)
            }
            .task { await load() }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func assetCell(_ asset: AIStudioAsset) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                if asset.assetType == "image" {
                    AsyncImage(url: asset.url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else if phase.error != nil {
                            Image(systemName: "photo.badge.exclamationmark")
                                .font(.system(size: 30))
                                .foregroundStyle(.white.opacity(0.5))
                        } else {
                            ProgressView().tint(Color.accentColor)
                        }
                    }
                } else {
                    Image(systemName: asset.assetType == "video" ? "play.rectangle.fill" : "waveform")
                        .font(.system(size: 38, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(height: 158)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            Text(asset.title?.isEmpty == false ? asset.title! : displayType(asset.assetType))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
            Text([asset.provider, asset.model].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.44))
                .lineLimit(1)
        }
        .padding(10)
        .x5ClearGlass(cornerRadius: 18, highlight: 0.08)
    }

    private var emptyState: some View {
        VStack(spacing: 13) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 45, weight: .light))
                .foregroundStyle(.white.opacity(0.48))
            Text("Результатов пока нет")
                .font(.title3.bold())
                .foregroundStyle(.white)
            Text("Созданные изображения, озвучки и видео появятся здесь автоматически.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.56))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
        }
    }

    private func load() async {
        isLoading = assets.isEmpty
        errorMessage = nil
        defer { isLoading = false }
        guard let token = await auth.freshAccessToken() else {
            errorMessage = "Войдите в аккаунт."
            return
        }
        do {
            assets = try await service.assets(accessToken: token)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func displayType(_ type: String) -> String {
        switch type {
        case "video": return "Видео"
        case "audio": return "Озвучка"
        default: return "Изображение"
        }
    }
}

struct AIAssetPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var auth: Auth

    let assetType: String
    let title: String
    let onSelect: (AIStudioAsset) -> Void

    @State private var assets: [AIStudioAsset] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    private let service = AIStudioService()

    var body: some View {
        NavigationStack {
            List {
                if isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if assets.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: assetType == "video" ? "video.slash" : "waveform.slash")
                            .font(.system(size: 34))
                            .foregroundStyle(.white.opacity(0.48))
                        Text("Нет подходящих файлов")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text("Сначала создайте результат в AI Studio.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(assets) { asset in
                        Button {
                            onSelect(asset)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: assetType == "video" ? "play.rectangle.fill" : "waveform")
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 42, height: 42)
                                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(asset.title?.isEmpty == false ? asset.title! : (assetType == "video" ? "Видео" : "Озвучка"))
                                        .font(.headline)
                                        .foregroundStyle(.white)
                                    Text([asset.provider, asset.model].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.5))
                                }
                            }
                        }
                    }
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .scrollContentBackground(.hidden)
            .background { X5Background() }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Отмена") { dismiss() }
                }
            }
            .task { await load() }
        }
        .preferredColorScheme(.dark)
    }

    private func load() async {
        guard let token = await auth.freshAccessToken() else {
            errorMessage = "Войдите в аккаунт."
            isLoading = false
            return
        }
        do {
            assets = try await service.assets(type: assetType, accessToken: token)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct AICloudAssetPreview: View {
    @Environment(\.dismiss) private var dismiss
    let asset: AIStudioAsset

    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if asset.assetType == "image" {
                    AsyncImage(url: asset.url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFit()
                        } else {
                            ProgressView().tint(Color.accentColor)
                        }
                    }
                    .padding(14)
                } else if asset.assetType == "video" {
                    if let player {
                        VideoPlayer(player: player)
                            .onAppear { player.play() }
                    }
                } else {
                    VStack(spacing: 22) {
                        Image(systemName: "waveform.circle.fill")
                            .font(.system(size: 90))
                            .foregroundStyle(Color.accentColor)
                        Button {
                            if player == nil { player = AVPlayer(url: asset.url) }
                            player?.play()
                        } label: {
                            Label("Слушать", systemImage: "play.fill")
                                .font(.headline)
                                .foregroundStyle(.black)
                                .padding(.horizontal, 28)
                                .frame(height: 50)
                                .background(Color.accentColor, in: Capsule())
                        }
                    }
                }
            }
            .navigationTitle(asset.title ?? "Результат")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Готово") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: asset.url) { Image(systemName: "square.and.arrow.up") }
                }
            }
            .onAppear {
                if asset.assetType == "video" { player = AVPlayer(url: asset.url) }
            }
            .onDisappear { player?.pause() }
        }
    }
}
