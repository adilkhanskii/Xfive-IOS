import SwiftUI

enum HomeRoute: Hashable, Identifiable {
    case imageGeneration(ImageGenerationCategory)
    case aiStudio
    case startupChat
    case hub
    case videoGeneration
    case aiInfluencer
    case voiceGeneration
    case liveFruits

    var id: String {
        switch self {
        case .imageGeneration(let category): return "image_generation:\(category.id)"
        case .aiStudio: return "ai_studio"
        case .startupChat: return "startup_chat"
        case .hub: return "hub"
        case .videoGeneration: return "video_generation"
        case .aiInfluencer: return "ai_influencer"
        case .voiceGeneration: return "voice_generation"
        case .liveFruits: return "live_fruits"
        }
    }

    var isReleaseInDevelopment: Bool {
        switch self {
        case .imageGeneration, .aiStudio, .startupChat, .hub, .videoGeneration,
             .aiInfluencer, .voiceGeneration, .liveFruits:
            return false
        }
    }
}

private enum HomeLayout {
    static let heroHeight: CGFloat = 198
    static let promoHeight: CGFloat = 78
    static let trendCardSize = CGSize(width: 112, height: 178)
    static let trendMediaHeight: CGFloat = 146
    static let businessFeatureHeight: CGFloat = 198
    static let businessFeatureOverflow: CGFloat = 38
    static let businessTileHeight: CGFloat = 112
    /// Одна плитка во всю ширину («Обложки YouTube») — как карточка «Озвучка».
    static let businessSingleTileHeight: CGFloat = 148
    /// Обложка со своим текстом (YouTube 26.10) — пропорция картинки 1400×933.
    static let textCoverAspect: CGFloat = 3.0 / 2.0
    static let businessWideHeight: CGFloat = 184
    static let voicePromoHeight: CGFloat = 148
    static let sectionSpacing: CGFloat = 14
    static let cardSpacing: CGFloat = 8
}

/// One native type system for every card on Home. The hero title is the
/// reference: other feature cards must not switch to the rounded display face.
private enum HomeTypography {
    static let sectionTitle = Font.system(size: 23, weight: .bold)
    static let featureTitle = Font.system(size: 25, weight: .bold)
    static let cardTitle = Font.system(size: 17, weight: .bold)
    static let compactCardTitle = Font.system(size: 15, weight: .bold)
    static let trendTitle = Font.system(size: 11, weight: .semibold)
    static let featureSubtitle = Font.system(size: 11.5, weight: .semibold)
}

/// Native Home composition. Photography and video posters are content-only assets;
/// labels, controls, card chrome, navigation and layout are SwiftUI views.
struct HomeView: View {
    @EnvironmentObject private var loc: LocalizationService
    @EnvironmentObject private var auth: Auth

    @State private var activeRoute: HomeRoute?
    @State private var showingGeneratedGallery = false
    @State private var showingSearch = false
    @State private var pendingSearchRoute: HomeRoute?
    @State private var activeHeroPage = 0
    @State private var aiCapabilities: AIStudioCapabilities?

    private let aiStudioService = AIStudioService()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HomeLayout.sectionSpacing) {
                    heroBanner
                    promoCards
                    // Карточку «Все AI-инструменты» убрали (Адильхан 09.10: «ненужная вещь»).
                    // Все инструменты и так есть на главной и в поиске.
                    trendsSection
                    businessSection
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 18)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .background { NativeHomeBackground() }
            .navigationTitle("Xfive marketing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // Кнопку поиска убрали (Адильхан 10.10 20:11: «раздел поиска можно убрать»;
                    // в поиске были дубли на английском — Post, Insta Pack, Product…).
                    // идея: вернуть — кнопка с showingSearch = true, окно HomeSearchSheet ниже осталось.
                    Button {
                        showingGeneratedGallery = true
                    } label: {
                        Image(systemName: "photo.stack")
                    }
                    .accessibilityIdentifier("x5.home.gallery")
                    .accessibilityLabel(loc.t("gen_gallery"))
                }
            }
            .sheet(item: $activeRoute) { route in
                sheetDestination(for: route)
            }
            .sheet(isPresented: $showingGeneratedGallery) {
                GeneratedGalleryView()
            }
            .sheet(isPresented: $showingSearch, onDismiss: completePendingSearchRoute) {
                HomeSearchSheet(capabilities: aiCapabilities) { route in
                    pendingSearchRoute = route
                    showingSearch = false
                }
            }
            .task { await loadAICapabilities() }
        }
    }

    private var heroBanner: some View {
        TabView(selection: $activeHeroPage) {
            ForEach(Array(heroSlides.enumerated()), id: \.element.id) { index, slide in
                NativeHomeHeroCard(
                    slide: slide,
                    pageIndex: index,
                    pageCount: heroSlides.count,
                    action: { handle(slide.action) }
                )
                .accessibilityIdentifier("x5.home.hero.\(slide.id)")
                .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(height: HomeLayout.heroHeight)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private var heroSlides: [NativeHomeHero] {
        var slides: [NativeHomeHero] = []
        // Адильхан 26.10 15:03: «Карточки товаров» и «Генерация изображений» поменяли местами —
        // карточки первым слайдом, генерация изображений — в «Дизайн для бизнеса» (imageGenerationCard).
        slides.append(NativeHomeHero(
            id: "product_cards",
            eyebrow: "X5 • AI STUDIO",
            title: "Карточки\nтоваров",
            subtitle: "Готовая инфографика для маркетплейсов",
            // Обложка — коллаж «Рекламные баннеры… Meta Ads» от Адильхана (WA 26.10 15:05).
            // Адильхан 26.10 16:26: «края срезались», наш текст и «Создать» зачеркнул —
            // коллаж целиком со своим заголовком, без оверлея; тап по любой точке слайда.
            // Тексты выше остаются только для VoiceOver.
            assetName: "HomeCoverSalesBanners",
            // ведёт туда же, куда вела большая карточка «Карточки товаров» (Адильхан 10.10)
            action: imageAction("target_ad"),
            fullCover: true
        ))
        if isToolAvailable("video") {
            slides.append(NativeHomeHero(
                id: "video",
                eyebrow: "X FIVE • AI VIDEO",
                title: "Генерация\nвидео",
                subtitle: "Текст в готовый ролик со звуком",
                assetName: "HomeUtilityVideo",
                action: .videoGeneration
            ))
        }
        // Адильхан 27.10 01:09: «живые продукты уберем, не нужная тема» — слайд убран из
        // карусели; сам генератор остался (тренд «Измена клубнички», AI Studio, поиск).
        return slides
    }

    /// Бывший первый слайд — теперь карточка в «Дизайн для бизнеса», вид тот же.
    private var imageGenerationCard: NativeHomeHero {
        NativeHomeHero(
            id: "image",
            eyebrow: "X FIVE • AI STUDIO",
            title: "Генерация\nизображений",
            subtitle: "Креативы, товары и посты за минуту",
            assetName: "HomeCoverTargetAds",
            action: .imageGeneration(ImageGenerationCatalog.custom)
        )
    }

    private var promoCards: some View {
        HStack(spacing: HomeLayout.cardSpacing) {
            NativeHomePromoCard(
                title: "Стартап чат",
                subtitle: "AI-наставник",
                icon: "message.badge",
                action: { handle(.startupChat) }
            )
            .accessibilityIdentifier("x5.home.promo.startup")

            NativeHomePromoCard(
                title: "Hub",
                subtitle: "Специалисты и задания",
                icon: "briefcase.fill",
                action: { handle(.hub) }
            )
            .accessibilityIdentifier("x5.home.promo.hub")
        }
    }

    private var trendsSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("Тренды")
                    .font(.title2.weight(.bold))
                    .foregroundColor(.white)

                Spacer()

                if isToolAvailable("video") {
                    Button {
                        handle(.videoGeneration)
                    } label: {
                        Label("Еще", systemImage: "chevron.right")
                            .labelStyle(.titleAndIcon)
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.white.opacity(0.68))
                    .accessibilityIdentifier("x5.home.trends.more")
                    .accessibilityHint("Открывает генератор видео")
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: HomeLayout.cardSpacing) {
                    ForEach(trendItems) { item in
                        NativeHomeTrendCard(
                            item: item,
                            onOpen: { handle(item.action) }
                        )
                        .accessibilityIdentifier("x5.home.trend.\(item.id)")
                    }
                }
                .padding(.horizontal, 1)
            }
            .accessibilityLabel("Тренды")
        }
    }

    @ViewBuilder
    private var businessSection: some View {
        if hasBusinessTools {
            VStack(alignment: .leading, spacing: HomeLayout.cardSpacing) {
                Text("Дизайн для бизнеса")
                    .font(HomeTypography.sectionTitle)
                    .foregroundColor(.white)
                    .tracking(-0.35)

                if isToolAvailable("ai_influencer") {
                    NativeHomeAIInfluencerFeatureCard(
                        action: { handle(.aiInfluencer) }
                    )
                    .accessibilityIdentifier("x5.home.business.ai_influencer")
                }

                // Адильхан 26.10: здесь была «Карточки товаров» — она ушла первым слайдом наверх,
                // а сюда встала «Генерация изображений» с тем же видом, что был у слайда.
                NativeHomeHeroCard(
                    slide: imageGenerationCard,
                    pageIndex: 0,
                    pageCount: 1,
                    action: { handle(imageGenerationCard.action) }
                )
                .frame(height: HomeLayout.heroHeight)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .accessibilityIdentifier("x5.home.business.image_generation")

                // Маленькую «Карточки товара» убрали (Адильхан 09.10): она дублировала
                // большую «Карточки товаров» выше. «Обложки YouTube» осталась одна —
                // во всю ширину, высотой как «Озвучка» ниже, чтобы ряд не выглядел пустым.
                ForEach(businessItems) { item in
                    NativeHomeBusinessCard(
                        title: item.title,
                        subtitle: item.subtitle,
                        assetName: item.assetName,
                        accent: item.accent,
                        actionTitle: nil,
                        heightOverride: HomeLayout.businessSingleTileHeight,
                        showsText: !item.coverHasText,
                        action: { handle(item.action) }
                    )
                    .accessibilityIdentifier("x5.home.business.\(item.id)")
                }

                if isToolAvailable("voice") {
                    NativeHomeVoiceCard(
                        action: { handle(.voiceGeneration) }
                    )
                    .accessibilityIdentifier("x5.home.business.voice")
                }
            }
        }
    }

    private var trendItems: [NativeHomeTrend] {
        var items: [NativeHomeTrend] = [
            NativeHomeTrend(
                id: "strawberry",
                title: "Измена клубнички",
                subtitle: "С бананом • мультсериал",
                assetName: "HomeTrendLiveVideo",
                motion: .video(.bundled(resourceName: "HomeTrendStrawberry")),
                action: .liveFruits
            )
        ]
        if isToolAvailable("video") {
            items.append(NativeHomeTrend(
                id: "tokayev",
                title: "С Токаевым",
                subtitle: "Видео с президентом",
                assetName: "HomeTrendPost",
                motion: .video(.bundled(resourceName: "HomeTrendTokayev")),
                action: .videoGeneration
            ))
        }
        items.append(NativeHomeTrend(
            id: "wildberries",
            title: "Карточки WB",
            subtitle: "Добавь свои товары",
            assetName: "HomeTrendNanoBanana",
            motion: .video(.bundled(resourceName: "HomeTrendAIStylist")),
            action: imageAction("product_cards")
        ))
        if isToolAvailable("video") {
            items.append(NativeHomeTrend(
                id: "celebrity",
                title: "Со знаменитостью",
                subtitle: "Добавь себя в сцену",
                assetName: "HomeTrendInfluencer",
                motion: .video(.bundled(resourceName: "HomeTrendFaceSwap")),
                action: .videoGeneration
            ))
        }
        return items
    }

    private var businessItems: [NativeHomeBusiness] {
        [
            NativeHomeBusiness(
                id: "youtube",
                title: "Обложки YouTube",
                subtitle: "Больше кликов",
                // HomeCoverYoutube — коллаж «Обложки для YouTube и Reels» от Адильхана (WA 26.10 15:07).
                // Заголовок и «Больше кликов» уже на картинке — свой текст поверх не рисуем.
                assetName: "HomeCoverYoutube",
                accent: .red,
                action: imageAction("youtube_cover"),
                coverHasText: true
            )
        ]
    }

    private var hasBusinessTools: Bool {
        true
    }

    private func isToolAvailable(
        _ capabilityID: String,
        defaultValue: Bool = false
    ) -> Bool {
        aiCapabilities?.tool(capabilityID).available ?? defaultValue
    }

    @MainActor
    private func loadAICapabilities() async {
        guard let token = await auth.freshAccessToken() else {
            aiCapabilities = nil
            activeHeroPage = 0
            return
        }
        do {
            aiCapabilities = try await aiStudioService.capabilities(accessToken: token)
        } catch {
            aiCapabilities = nil
        }
        activeHeroPage = 0
    }

    private func imageAction(_ categoryID: String) -> HomeRoute {
        let categories = Dictionary(
            uniqueKeysWithValues: ImageGenerationCatalog.categories.map { ($0.id, $0) }
        )
        return categories[categoryID].map(HomeRoute.imageGeneration)
            ?? .imageGeneration(ImageGenerationCatalog.custom)
    }

    private func handle(_ route: HomeRoute) {
        switch route {
        case .imageGeneration(let category):
            DiagnosticLogger.log(event: "home_studio_\(category.id)_tap")
            activeRoute = route
        case .aiStudio:
            DiagnosticLogger.log(event: "home_ai_studio_tap")
            activeRoute = route
        case .hub:
            DiagnosticLogger.log(event: "home_hub_promo_tap")
            NotificationCenter.default.post(name: .x5SwitchTab, object: nil, userInfo: ["tab": "hub"])
        case .videoGeneration:
            DiagnosticLogger.log(event: "home_studio_video_tap")
            activeRoute = route
        case .aiInfluencer:
            DiagnosticLogger.log(event: "home_ai_influencer_tap")
            activeRoute = route
        case .voiceGeneration:
            DiagnosticLogger.log(event: "home_studio_voice_tap")
            activeRoute = route
        case .liveFruits:
            DiagnosticLogger.log(event: "home_live_fruits_tap")
            activeRoute = route
        case .startupChat:
            DiagnosticLogger.log(event: "home_startup_chat_tap")
            activeRoute = route
        }
    }

    private func completePendingSearchRoute() {
        guard let route = pendingSearchRoute else { return }
        pendingSearchRoute = nil
        handle(route)
    }

    @ViewBuilder
    private func sheetDestination(for route: HomeRoute) -> some View {
        switch route {
        case .imageGeneration(let category):
            NavigationStack { ImageGeneratorView(category: category) }
        case .aiStudio:
            AIStudioHubView()
        case .videoGeneration:
            VideoGeneratorView()
        case .aiInfluencer:
            NavigationStack { AIInfluencerView() }
        case .voiceGeneration:
            VoiceGeneratorView()
        case .startupChat: StartupChatView()
        case .liveFruits: LiveFruitsView()
        case .hub: EmptyView()
        }
    }
}

private struct NativeHomeHero: Identifiable {
    let id: String
    let eyebrow: String
    let title: String
    let subtitle: String
    let assetName: String
    let action: HomeRoute
    /// Обложка — готовый баннер со своим текстом: показать целиком (aspect-fit на белом,
    /// края коллажа белые), без нашего текста и кнопки; нажатие — по всему слайду.
    var fullCover = false
}

private struct NativeHomeTrend: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let assetName: String
    let motion: NativeHomeTrendMotion
    let action: HomeRoute
}

private enum NativeHomeTrendMotion {
    case video(HomeMotionSource)
}

private struct NativeHomeBusiness: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let assetName: String
    let accent: Color
    let action: HomeRoute
    /// Текст уже нарисован на обложке — заголовок карточки поверх не нужен.
    var coverHasText = false
}

private struct NativeHomeBackground: View {
    var body: some View {
        ZStack {
            Color(red: 0.016, green: 0.020, blue: 0.045)
            RadialGradient(
                colors: [Color(red: 0.40, green: 0.10, blue: 0.72).opacity(0.42), .clear],
                center: .init(x: -0.10, y: 0.62),
                startRadius: 8,
                endRadius: 340
            )
            RadialGradient(
                colors: [Color(red: 0.04, green: 0.22, blue: 0.38).opacity(0.34), .clear],
                center: .init(x: 0.62, y: 0.04),
                startRadius: 8,
                endRadius: 390
            )
        }
        .ignoresSafeArea()
    }
}

private struct NativeHomeHeroCard: View {
    let slide: NativeHomeHero
    let pageIndex: Int
    let pageCount: Int
    let action: () -> Void

    var body: some View {
        if slide.fullCover {
            fullCoverBody
        } else {
            overlayBody
        }
    }

    private var fullCoverBody: some View {
        Button(action: action) {
            ZStack(alignment: .bottomTrailing) {
                // цвет краёв коллажа — поля по бокам сливаются с картинкой
                Color(white: 0.996)

                Image(slide.assetName)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if pageCount > 1 {
                    NativeHomePageDots(active: pageIndex, count: pageCount, onLight: true)
                        .padding(14)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("x5.home.hero.\(slide.id).create")
        .accessibilityLabel("\(slide.title.replacingOccurrences(of: "\n", with: " ")). \(slide.subtitle)")
    }

    private var overlayBody: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                Image(slide.assetName)
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()

                LinearGradient(
                    colors: [Color.black.opacity(0.04), Color.black.opacity(0.30), Color.black.opacity(0.88)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 5) {
                    Text(slide.eyebrow)
                        .font(.caption2.weight(.bold))
                        .tracking(1.4)
                        .foregroundColor(X5Style.blue)

                    Text(slide.title)
                        .font(HomeTypography.featureTitle)
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.78)

                    Text(slide.subtitle)
                        .font(.caption.weight(.medium))
                        .foregroundColor(.white.opacity(0.76))
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)

                    Button(action: action) {
                        Text("Создать")
                            .font(.caption.weight(.bold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 18)
                            .frame(minHeight: 38)
                            .background(X5Style.blue, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("x5.home.hero.\(slide.id).create")
                    .accessibilityLabel("\(slide.title.replacingOccurrences(of: "\n", with: " ")). Создать")
                }
                .padding(16)
                .padding(.trailing, 48)

                // одна карточка вне карусели («Генерация изображений» в бизнес-разделе) — без точек
                if pageCount > 1 {
                    NativeHomePageDots(active: pageIndex, count: pageCount)
                        .padding(14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
        }
        .background(.black)
        .accessibilityElement(children: .contain)
    }
}

private struct NativeHomePromoCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.black)
                    .frame(width: 34, height: 34)
                    .background(
                        Color.black.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.black)
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)

                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.black.opacity(0.56))
                        .lineLimit(2)
                        .minimumScaleFactor(0.68)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundColor(X5Style.blue)
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity)
            .frame(height: HomeLayout.promoHeight)
            .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title). \(subtitle)")
    }
}

private struct NativeHomeTrendCard: View {
    let item: NativeHomeTrend
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 7) {
                trendMedia
                .frame(
                    width: HomeLayout.trendCardSize.width,
                    height: HomeLayout.trendMediaHeight
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                        .allowsHitTesting(false)
                }

                Text(item.title)
                    .font(HomeTypography.trendTitle)
                    .foregroundColor(.white.opacity(0.88))
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
                    .allowsTightening(true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 2)
            }
            .frame(
                width: HomeLayout.trendCardSize.width,
                height: HomeLayout.trendCardSize.height,
                alignment: .topLeading
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityHint("Открывает соответствующий инструмент")
    }

    @ViewBuilder
    private var trendMedia: some View {
        switch item.motion {
        case .video(let source):
            LoopingVideo(
                source: source,
                posterAssetName: item.assetName,
                isActive: true,
                isUserInitiated: false
            )
        }
    }

}

private struct NativeHomeAIInfluencerFeatureCard: View {
    let action: () -> Void

    private let cornerRadius: CGFloat = 20

    var body: some View {
        Button(action: action) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Image("HomeAIInfluencerFeature")
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()

                    LinearGradient(
                        colors: [Color.black.opacity(0.88), Color.black.opacity(0.42), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )

                    VStack(alignment: .leading, spacing: 7) {
                        Text("AI-\nинфлюенсер")
                            .font(HomeTypography.featureTitle)
                            .foregroundColor(.white)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                            .allowsTightening(true)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("Виртуальный персонаж, который ведет соцсети, рекламирует товары и общается с аудиторией как реальный человек")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.78))
                            .lineSpacing(2)
                            .lineLimit(5)

                        Text("X5")
                            .font(.caption.weight(.bold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 17)
                            .frame(minHeight: 30)
                            .background(X5Style.blue, in: Capsule())
                            .padding(.top, 5)
                    }
                    .padding(18)
                    .frame(
                        width: min(236, proxy.size.width * 0.68),
                        height: proxy.size.height,
                        alignment: .leading
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: HomeLayout.businessFeatureHeight + HomeLayout.businessFeatureOverflow)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.22), lineWidth: 1)
        }
        .shadow(color: Color(red: 0.49, green: 0.23, blue: 0.82).opacity(0.30), radius: 16, y: 8)
        .accessibilityLabel("AI-инфлюенсер. Виртуальный персонаж для ведения соцсетей и рекламы")
        .accessibilityHint("Открывает инструменты создания AI-персонажа")
    }
}

private struct NativeHomeInstagramBackdrop: View {
    private let lightPanelFraction: CGFloat = 0.42

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                LinearGradient(
                    colors: [
                        Color(red: 0.29, green: 0.12, blue: 0.47),
                        Color(red: 0.16, green: 0.06, blue: 0.29),
                        Color(red: 0.07, green: 0.03, blue: 0.13)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 0.76, green: 0.54, blue: 1.00).opacity(0.72),
                                .clear
                            ],
                            center: .center,
                            startRadius: 2,
                            endRadius: 104
                        )
                    )
                    .frame(width: 208, height: 208)
                    .offset(x: proxy.size.width * 0.49, y: -28)

                ZStack(alignment: .bottomLeading) {
                    LinearGradient(
                        colors: [
                            Color(red: 0.99, green: 0.98, blue: 1.00),
                            Color(red: 0.91, green: 0.84, blue: 0.99)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    Capsule()
                        .fill(Color(red: 0.57, green: 0.35, blue: 0.86).opacity(0.18))
                        .frame(width: 210, height: 54)
                        .rotationEffect(.degrees(-13))
                        .offset(x: 16, y: 34)
                }
                .frame(width: proxy.size.width * lightPanelFraction)

                NativeHomeInstagramPostStack()
                    .frame(width: 150, height: 164)
                    .offset(x: proxy.size.width * 0.52, y: 10)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct NativeHomeInstagramPostStack: View {
    var body: some View {
        ZStack {
            postCard(
                colors: [
                    Color(red: 0.76, green: 0.55, blue: 1.00),
                    Color(red: 0.37, green: 0.18, blue: 0.64)
                ]
            )
            .frame(width: 78, height: 126)
            .rotationEffect(.degrees(-8))
            .offset(x: -31, y: 14)
            .opacity(0.82)

            postCard(
                colors: [
                    Color(red: 0.98, green: 0.66, blue: 0.85),
                    Color(red: 0.48, green: 0.28, blue: 0.78)
                ]
            )
            .frame(width: 86, height: 138)
            .rotationEffect(.degrees(7))
            .offset(x: 38, y: -4)
        }
    }

    private func postCard(colors: [Color]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.white.opacity(0.92))
                    .frame(width: 11, height: 11)
                Capsule()
                    .fill(Color.white.opacity(0.72))
                    .frame(width: 26, height: 4)
                Spacer(minLength: 0)
                Image(systemName: "ellipsis")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(.white.opacity(0.80))
            }

            LinearGradient(
                colors: colors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay {
                Circle()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 42, height: 42)
                    .offset(x: 14, y: -10)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack(spacing: 7) {
                Image(systemName: "heart.fill")
                Image(systemName: "bubble.right.fill")
                Image(systemName: "paperplane.fill")
            }
            .font(.system(size: 8, weight: .semibold))
            .foregroundColor(.white.opacity(0.92))

            Capsule()
                .fill(Color.white.opacity(0.58))
                .frame(width: 42, height: 3)
        }
        .padding(7)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.white.opacity(0.34), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.28), radius: 8, y: 5)
    }
}

private struct NativeHomeBusinessCard: View {
    let title: String
    let subtitle: String
    let assetName: String
    let accent: Color
    let actionTitle: String?
    var compact = false
    /// Своя высота для плитки во всю ширину; nil — как раньше.
    var heightOverride: CGFloat? = nil
    /// false — обложка уже с текстом (YouTube 26.10): без своего заголовка и затемнения.
    var showsText = true
    let action: () -> Void

    private var cardHeight: CGFloat {
        if let heightOverride { return heightOverride }
        if compact { return HomeLayout.businessWideHeight }
        if actionTitle != nil { return HomeLayout.businessFeatureHeight }
        return HomeLayout.businessTileHeight
    }

    var body: some View {
        Button(action: action) {
            sized(ZStack(alignment: .bottomLeading) {
                Image(assetName)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: showsText ? cardHeight : nil)
                    .clipped()

                if showsText {
                    LinearGradient(
                        colors: [Color.black.opacity(0.03), Color.black.opacity(0.83)],
                        startPoint: .center,
                        endPoint: .bottom
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(compact ? HomeTypography.compactCardTitle : HomeTypography.cardTitle)
                            .foregroundColor(.white)
                            .lineLimit(2)
                            .minimumScaleFactor(0.78)
                        Text(subtitle)
                            .font(.caption2.weight(.medium))
                            .foregroundColor(.white.opacity(0.76))
                            .lineLimit(2)
                        if let actionTitle {
                            Text(actionTitle)
                                .font(.caption.weight(.bold))
                                .foregroundColor(.black)
                                .padding(.horizontal, 14)
                                .frame(minHeight: 28)
                                .background(accent, in: Capsule())
                                .padding(.top, 4)
                        }
                    }
                    .padding(11)
                }

                Image(systemName: "arrow.right")
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(.black)
                    .frame(width: 30, height: 30)
                    .background(accent, in: Circle())
                    .padding(9)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            .frame(maxWidth: .infinity))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            // Зона нажатия = видимая карточка. clipShape обрезает только картинку,
            // а нажатия ловит вся растянутая scaledToFill-картинка. Широкая «Обложки YouTube»
            // перекрывала «Карточки товаров» сверху, и тап открывал обложки (Адильхан 10.10).
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title). \(subtitle)")
        .accessibilityHint("Открывает соответствующий инструмент")
    }

    /// Обычная плитка — своя высота. Обложка со своим текстом — целиком, в пропорции
    /// картинки 3:2: на iPhone у «Обложки YouTube» срезался верх заголовка (Адильхан 26.10 16:26).
    @ViewBuilder
    private func sized<Content: View>(_ content: Content) -> some View {
        if showsText {
            content.frame(height: cardHeight)
        } else {
            content.aspectRatio(HomeLayout.textCoverAspect, contentMode: .fit)
        }
    }
}

private struct NativeHomeVoiceCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                Image("HomeMotionStudioPoster")
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: HomeLayout.voicePromoHeight)
                    .clipped()

                LinearGradient(
                    colors: [
                        Color.black.opacity(0.88),
                        Color.black.opacity(0.48),
                        Color.black.opacity(0.12)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )

                LinearGradient(
                    colors: [.clear, Color.black.opacity(0.72)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 7) {
                    Text("AI VOICE")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1.2)
                        .foregroundColor(X5Style.blue)

                    Text("Озвучка")
                        .font(HomeTypography.featureTitle)
                        .foregroundColor(.white)

                    Text("Живые голоса для видео, рекламы и подкастов")
                        .font(HomeTypography.featureSubtitle)
                        .foregroundColor(.white.opacity(0.74))
                        .lineLimit(2)
                        .frame(maxWidth: 220, alignment: .leading)

                    HStack(spacing: 6) {
                        Text("Озвучить текст")
                            .font(.system(size: 10.5, weight: .bold))

                        Image(systemName: "arrow.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundColor(.black)
                    .padding(.horizontal, 12)
                    .frame(height: 29)
                    .background(X5Style.blue, in: Capsule())
                }
                .padding(16)

                Image(systemName: "waveform")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [X5Style.blue, .white.opacity(0.82)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .shadow(color: X5Style.blue.opacity(0.42), radius: 10)
                    .padding(.trailing, 25)
                    .padding(.bottom, 49)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            .frame(maxWidth: .infinity)
            .frame(height: HomeLayout.voicePromoHeight)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            // Та же причина, что у плиток выше: нажатия только по видимой карточке.
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Озвучка. Естественные голоса, эмоции и языки")
        .accessibilityHint("Открывает генератор озвучки")
    }
}

private struct NativeHomePageDots: View {
    let active: Int
    let count: Int
    /// На белом коллаже белые точки не видны — тёмные.
    var onLight = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(onLight
                          ? (index == active ? Color.black.opacity(0.78) : Color.black.opacity(0.24))
                          : (index == active ? .white : .white.opacity(0.42)))
                    .frame(width: index == active ? 22 : 7, height: 7)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct HomeSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    let capabilities: AIStudioCapabilities?
    let onSelect: (HomeRoute) -> Void

    private var allItems: [HomeSearchItem] {
        var items = [
            HomeSearchItem(title: "Стартап чат", subtitle: "AI-наставник для бизнеса", icon: "sparkles.rectangle.stack", route: .startupChat),
            HomeSearchItem(title: "Hub", subtitle: "Специалисты и задания", icon: "briefcase.fill", route: .hub)
        ]

        if isAvailable("video") {
            items.append(HomeSearchItem(title: "Генерация видео", subtitle: "AI-ролики для соцсетей", icon: "video.fill", route: .videoGeneration))
        }
        if isAvailable("voice") {
            items.append(HomeSearchItem(title: "Озвучка", subtitle: "Текст в естественный голос", icon: "waveform", route: .voiceGeneration))
        }
        if isAvailable("live_products", defaultValue: true) {
            items.append(HomeSearchItem(title: "Живые фрукты", subtitle: "Сценарий и ролик для Reels", icon: "play.tv.fill", route: .liveFruits))
        }
        items.append(HomeSearchItem(title: "Генерация изображений", subtitle: "Креативы, товары и посты", icon: "photo.badge.plus", route: .imageGeneration(ImageGenerationCatalog.custom)))
        items.append(contentsOf: ImageGenerationCatalog.categories.map { category in
            HomeSearchItem(title: category.title, subtitle: category.subtitle, icon: category.icon, route: .imageGeneration(category))
        })
        return items
    }

    private func isAvailable(
        _ capabilityID: String,
        defaultValue: Bool = false
    ) -> Bool {
        capabilities?.tool(capabilityID).available ?? defaultValue
    }

    private var filteredItems: [HomeSearchItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return allItems }
        return allItems.filter {
            $0.title.localizedCaseInsensitiveContains(needle)
                || $0.subtitle.localizedCaseInsensitiveContains(needle)
        }
    }

    var body: some View {
        NavigationStack {
            List(filteredItems) { item in
                Button { onSelect(item.route) } label: {
                    HStack(spacing: 13) {
                        Image(systemName: item.icon)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(X5Style.blue)
                            .frame(width: 38, height: 38)
                            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.body.weight(.semibold)).foregroundColor(.white)
                            Text(item.subtitle).font(.caption).foregroundColor(.white.opacity(0.58))
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundColor(.white.opacity(0.28))
                    }
                    .frame(minHeight: 48)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
            }
            .scrollContentBackground(.hidden)
            .background { X5Background() }
            .searchable(text: $query, prompt: "Инструмент или формат")
            .navigationTitle("Поиск")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }.foregroundColor(X5Style.blue)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct HomeSearchItem: Identifiable {
    let title: String
    let subtitle: String
    let icon: String
    let route: HomeRoute

    var id: String { "\(route.id):\(title)" }
}
