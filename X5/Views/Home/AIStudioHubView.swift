import SwiftUI

private enum AIStudioRoute: Hashable {
    case image(String)
    case voice
    case video(VideoStudioMode)
    case influencer
    case lipsync
    case presets
    case gallery
    case liveProducts
}

private struct AIStudioToolItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let capabilityID: String
    let route: AIStudioRoute
}

struct AIStudioHubView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var auth: Auth

    @State private var capabilities: AIStudioCapabilities?
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let service = AIStudioService()
    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    header
                    if !availableProviderChips.isEmpty {
                        providerSummary
                    }
                    Text("ВСЕ AI-ИНСТРУМЕНТЫ")
                        .font(.system(size: 11, weight: .black))
                        .tracking(1.5)
                        .foregroundStyle(.white.opacity(0.46))

                    if isLoading {
                        HStack { Spacer(); ProgressView().tint(Color.accentColor); Spacer() }
                            .padding(28)
                    } else {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(tools) { tool in
                                let state = toolState(tool)
                                NavigationLink(value: tool.route) {
                                    toolCard(tool, state: state)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(0.14), in: RoundedRectangle(cornerRadius: 16))
                    }
                }
                .padding(16)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .background { X5Background() }
            .navigationTitle("AI Studio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Закрыть") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await loadCapabilities() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .navigationDestination(for: AIStudioRoute.self) { route in
                destination(route)
            }
            .task { await loadCapabilities() }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 54, height: 54)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 17))
                Spacer()
                Text("X FIVE · AI STUDIO")
                    .font(.system(size: 10, weight: .black))
                    .tracking(1.3)
                    .foregroundStyle(Color.accentColor)
            }
            Text("Создавайте настоящий контент")
                .font(.system(size: 29, weight: .black))
                .foregroundStyle(.white)
            Text("Все инструменты остаются на месте. Статус провайдера показан на карточке; при временном сбое запуск блокируется без списания кредитов. Результаты сохраняются в приватной облачной галерее.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
        }
        .padding(18)
        .x5ClearGlass(cornerRadius: 22, highlight: 0.13)
    }

    private var providerSummary: some View {
        HStack(spacing: 8) {
            ForEach(Array(availableProviderChips.enumerated()), id: \.offset) { _, chip in
                statusChip(chip.title, capability: chip.capability)
            }
        }
    }

    private var availableProviderChips: [(title: String, capability: String)] {
        [
            ("Изображения", "image_generation"),
            ("MiniMax", "voice"),
            ("Seedance", "video"),
            ("Lipsync", "lipsync")
        ]
    }

    private func statusChip(_ title: String, capability: String) -> some View {
        let active = capabilities?.tool(capability).available == true
        return HStack(spacing: 5) {
            Circle().fill(active ? Color.green : Color.orange).frame(width: 7, height: 7)
            Text(title).lineLimit(1).minimumScaleFactor(0.72)
        }
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(.white.opacity(0.76))
        .padding(.horizontal, 9)
        .frame(height: 30)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.06), in: Capsule())
    }

    private func toolCard(_ tool: AIStudioToolItem, state: AIStudioToolCapability) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Image(systemName: tool.icon)
                    .font(.system(size: 23, weight: .bold))
                    .foregroundStyle(state.available ? Color.accentColor : Color.white.opacity(0.34))
                    .frame(width: 48, height: 48)
                    .background(
                        (state.available ? Color.accentColor.opacity(0.13) : Color.white.opacity(0.05)),
                        in: RoundedRectangle(cornerRadius: 14)
                    )
                Spacer()
                Image(systemName: state.available ? "arrow.up.right" : "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(state.available ? Color.white.opacity(0.34) : Color.orange)
            }
            Text(tool.title)
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(state.available ? Color.white : Color.white.opacity(0.48))
                .lineLimit(2)
            Text(state.available ? tool.subtitle : unavailableLabel(state.unavailableReason))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(state.available ? Color.white.opacity(0.52) : Color.orange.opacity(0.78))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(minHeight: 164, alignment: .topLeading)
        .x5ClearGlass(cornerRadius: 20, highlight: state.available ? 0.08 : 0.03)
        .opacity(state.available ? 1 : 0.74)
    }

    @ViewBuilder
    private func destination(_ route: AIStudioRoute) -> some View {
        switch route {
        case .image(let id):
            ImageGeneratorView(category: imageCategory(id))
        case .voice:
            VoiceGeneratorView()
        case .video(let mode):
            VideoGeneratorView(studioMode: mode)
        case .influencer:
            AIInfluencerView()
        case .lipsync:
            LipsyncView()
        case .presets:
            AIPresetsView()
        case .gallery:
            AICloudGalleryView()
        case .liveProducts:
            LiveFruitsView()
        }
    }

    private func imageCategory(_ id: String) -> ImageGenerationCategory {
        if id == "custom" { return ImageGenerationCatalog.custom }
        return ImageGenerationCatalog.categories.first(where: { $0.id == id })
            ?? ImageGenerationCatalog.custom
    }

    private func toolState(_ tool: AIStudioToolItem) -> AIStudioToolCapability {
        if ["presets", "live_products"].contains(tool.capabilityID) {
            return capabilities?.tool(tool.capabilityID)
                ?? AIStudioToolCapability(available: true, unavailableReason: nil)
        }
        return capabilities?.tool(tool.capabilityID)
            ?? AIStudioToolCapability(available: false, unavailableReason: "checking")
    }

    private func unavailableLabel(_ reason: String?) -> String {
        switch reason {
        case "provider_balance_or_quota": return "Нет баланса или квоты провайдера"
        case "provider_auth_failed": return "Провайдер отклонил доступ"
        case "provider_model_unavailable": return "Модель временно недоступна"
        case "lipsync_not_configured", "provider_not_configured": return "Провайдер не подключён"
        case "checking": return "Проверяем доступность…"
        default: return "Сервис временно недоступен"
        }
    }

    private func loadCapabilities() async {
        isLoading = capabilities == nil
        errorMessage = nil
        defer { isLoading = false }
        guard let token = await auth.freshAccessToken() else {
            errorMessage = "Войдите в аккаунт."
            return
        }
        do { capabilities = try await service.capabilities(accessToken: token) }
        catch { errorMessage = error.localizedDescription }
    }

    private var tools: [AIStudioToolItem] {
        [
            .init(id: "image", title: "Генерация изображений", subtitle: "Креатив по точному описанию", icon: "photo.badge.plus", capabilityID: "image_generation", route: .image("custom")),
            .init(id: "edit", title: "Редактор изображения", subtitle: "Изменить загруженное фото", icon: "wand.and.stars.inverse", capabilityID: "image_editor", route: .image("edit_image")),
            .init(id: "cards", title: "Карточки товаров", subtitle: "Набор читаемой инфографики", icon: "rectangle.grid.2x2.fill", capabilityID: "product_cards", route: .image("product_cards")),
            .init(id: "youtube", title: "Обложки YouTube", subtitle: "Режимы и четыре референса", icon: "play.rectangle.fill", capabilityID: "youtube_cover", route: .image("youtube_cover")),
            .init(id: "logo", title: "Логотип PNG", subtitle: "Прозрачный фон", icon: "seal.fill", capabilityID: "transparent_logo", route: .image("logo")),
            .init(id: "target", title: "Рекламный баннер", subtitle: "Оффер как часть дизайна", icon: "megaphone.fill", capabilityID: "image_generation", route: .image("target_ad")),
            .init(id: "post", title: "Пост", subtitle: "Квадратный контент для ленты", icon: "square.grid.2x2.fill", capabilityID: "image_generation", route: .image("post")),
            .init(id: "story", title: "Сторис", subtitle: "Вертикальный креатив", icon: "rectangle.portrait.fill", capabilityID: "image_generation", route: .image("story")),
            .init(id: "packaging", title: "Упаковка", subtitle: "Концепт коробки и этикетки", icon: "cube.box.fill", capabilityID: "image_generation", route: .image("packaging")),
            .init(id: "content", title: "Контент-пак", subtitle: "Пост, сторис и реклама в одном стиле", icon: "square.stack.3d.up.fill", capabilityID: "content_pack", route: .image("content_pack")),
            .init(id: "moodboard", title: "Moodboard", subtitle: "Палитра, свет и визуальный язык", icon: "rectangle.3.group.fill", capabilityID: "moodboard", route: .image("moodboard")),
            .init(id: "voice", title: "Озвучка MiniMax", subtitle: "Русский, қазақша и English", icon: "waveform.badge.mic", capabilityID: "voice", route: .voice),
            .init(id: "video", title: "Video Studio", subtitle: "Текст или фото → видео", icon: "video.badge.waveform", capabilityID: "video", route: .video(.standard)),
            .init(id: "cinema", title: "Cinema Studio", subtitle: "Сцена, камера, стиль и свет", icon: "film.stack.fill", capabilityID: "cinema", route: .video(.cinema)),
            .init(id: "vfx", title: "VFX", subtitle: "Фотография → видеоэффект", icon: "wand.and.rays", capabilityID: "vfx", route: .video(.vfx)),
            .init(id: "influencer", title: "AI-инфлюенсер", subtitle: "Персонаж → голос → Lipsync‑видео", icon: "person.crop.rectangle.stack.fill", capabilityID: "ai_influencer", route: .influencer),
            .init(id: "lipsync", title: "Lipsync", subtitle: "Видео + MiniMax или аудиофайл", icon: "mouth.fill", capabilityID: "lipsync", route: .lipsync),
            .init(id: "presets", title: "Presets", subtitle: "Сохранённые настройки", icon: "bookmark.square.fill", capabilityID: "presets", route: .presets),
            .init(id: "gallery", title: "Облачная галерея", subtitle: "Изображения, MP3 и MP4", icon: "icloud.and.arrow.down.fill", capabilityID: "presets", route: .gallery),
            .init(id: "live", title: "Живые продукты", subtitle: "Анимированные товарные истории", icon: "sparkles.tv.fill", capabilityID: "live_products", route: .liveProducts)
        ]
    }
}
