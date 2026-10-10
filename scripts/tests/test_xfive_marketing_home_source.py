from pathlib import Path
import plistlib
import unittest


ROOT = Path(__file__).resolve().parents[2]
HOME = ROOT / "X5" / "Views" / "Home" / "HomeView.swift"
LOOPING_VIDEO = ROOT / "X5" / "Views" / "Home" / "LoopingVideo.swift"
TAB_VIEW = ROOT / "X5" / "Views" / "AppTabView.swift"
class XFiveMarketingHomeSourceTests(unittest.TestCase):
    def test_visible_brand_uses_exact_client_name(self):
        home = HOME.read_text(encoding="utf-8")
        main = (ROOT / "X5" / "Views" / "MainView.swift").read_text(
            encoding="utf-8"
        )
        with (ROOT / "X5" / "Info.plist").open("rb") as plist_file:
            info = plistlib.load(plist_file)
        project = (ROOT / "project.yml").read_text(encoding="utf-8")
        store_name = (
            ROOT / "fastlane" / "metadata" / "en-US" / "name.txt"
        ).read_text(encoding="utf-8").strip()
        russian_store_name = (
            ROOT / "fastlane" / "metadata" / "ru" / "name.txt"
        ).read_text(encoding="utf-8").strip()

        self.assertIn('.navigationTitle("Xfive marketing")', home)
        self.assertIn('.navigationTitle("Xfive marketing")', main)
        self.assertNotIn("X Five AI Studio", home)
        self.assertNotIn("X5 AI", home)
        self.assertEqual(info["CFBundleDisplayName"], "Xfive marketing")
        self.assertIn("CFBundleDisplayName: Xfive marketing", project)
        self.assertIn("PRODUCT_NAME: Xfive marketing", project)
        self.assertEqual(store_name, "Xfive marketing")
        self.assertEqual(russian_store_name, "Xfive marketing")

    def test_home_rejects_full_screen_raster_mockups_and_crop_layouts(self):
        home = HOME.read_text(encoding="utf-8")

        for forbidden in (
            "HomeApprovedReference",
            "ApprovedHomeCrop",
            "HomeApprovedLayout",
            "ApprovedArtworkButton",
            "TrendArtworkCard",
            "BusinessArtworkButton",
            "CGRect(x:",
        ):
            self.assertNotIn(forbidden, home)

        for required in (
            "struct NativeHomeHeroCard",
            "struct NativeHomePromoCard",
            "struct NativeHomeTrendCard",
            "struct NativeHomeBusinessCard",
            "Image(slide.assetName)",
            "Text(slide.title)",
            "Text(slide.subtitle)",
            'Text("Создать")',
        ):
            self.assertIn(required, home)

    def test_primary_hero_opens_the_real_image_generator(self):
        home = HOME.read_text(encoding="utf-8")

        self.assertIn('accessibilityIdentifier("x5.home.hero.\\(slide.id).create")', home)
        self.assertIn(
            "action: .imageGeneration(ImageGenerationCatalog.custom)",
            home,
        )
        self.assertIn("ImageGeneratorView(category: category", home)
        self.assertRegex(
            home,
            r"case \.imageGeneration\(let category\):\s+NavigationStack \{ ImageGeneratorView\(category: category\) \}",
        )

    def test_home_routes_are_explicit_and_hub_uses_existing_tab_switch(self):
        home = HOME.read_text(encoding="utf-8")

        self.assertIn("enum HomeRoute: Hashable, Identifiable", home)
        for route in (
            "case imageGeneration(ImageGenerationCategory)",
            "case aiStudio",
            "case startupChat",
            "case hub",
            "case videoGeneration",
            "case aiInfluencer",
            "case voiceGeneration",
            "case liveFruits",
        ):
            self.assertIn(route, home)
        self.assertIn(
            'NotificationCenter.default.post(name: .x5SwitchTab, '
            'object: nil, userInfo: ["tab": "hub"])',
            home,
        )
        self.assertRegex(home, r"case \.startupChat:\s+StartupChatView\(\)")
        self.assertRegex(home, r"case \.liveFruits:\s+LiveFruitsView\(\)")
        self.assertRegex(home, r"case \.videoGeneration:\s+VideoGeneratorView\(\)")
        self.assertRegex(home, r"case \.aiInfluencer:\s+NavigationStack \{ AIInfluencerView\(\) \}")
        self.assertRegex(home, r"case \.voiceGeneration:\s+VoiceGeneratorView\(\)")
        self.assertIn(
            "case .imageGeneration, .aiStudio, .startupChat, .hub, .videoGeneration,",
            home,
        )
        self.assertIn(".aiInfluencer, .voiceGeneration, .liveFruits:", home)

    def test_home_no_longer_contains_the_fake_in_development_sheet(self):
        home = HOME.read_text(encoding="utf-8")
        self.assertNotIn("private struct HomeFeatureInDevelopmentView", home)
        # 09.10 (Адильхан): карточку «Все AI-инструменты» убрали с главной,
        # сам хаб остаётся доступен через поиск.
        self.assertNotIn('Text("Все AI-инструменты")', home)
        self.assertNotIn("aiStudioLauncher", home)
        self.assertIn("AIStudioHubView()", home)

    def test_home_keeps_image_interfaces_visible_and_gates_provider_execution(self):
        home = HOME.read_text(encoding="utf-8")
        self.assertIn("aiStudioService.capabilities(accessToken: token)", home)
        self.assertNotIn('if isToolAvailable("image_generation")', home)
        self.assertIn('action: .imageGeneration(ImageGenerationCatalog.custom)', home)
        self.assertIn('action: imageAction("product_cards")', home)
        self.assertIn('if isToolAvailable("ai_influencer")', home)
        self.assertIn('if isToolAvailable("voice")', home)
        self.assertIn('if isToolAvailable("video")', home)
        self.assertIn("HomeSearchSheet(capabilities: aiCapabilities)", home)

    def test_native_promos_trends_and_business_cards_are_complete(self):
        home = HOME.read_text(encoding="utf-8")

        for text in (
            "Стартап чат",
            "Hub",
            "Измена клубнички",
            "С Токаевым",
            "Карточки WB",
            "Со знаменитостью",
            "Обложки YouTube",
            "AI-инфлюенсер",
        ):
            self.assertIn(text, home)
        # 09.10: маленькая плитка «Карточки товара» дублировала большую — убрана.
        self.assertNotIn('title: "Карточки товара"', home)

        self.assertIn("ScrollView(.horizontal, showsIndicators: false)", home)
        self.assertIn("LazyHStack", home)
        self.assertIn("NativeHomeBusinessCard", home)
        self.assertIn("NativeHomeTrendCard", home)

    def test_ai_influencer_feature_is_a_native_overflow_card_after_trends(self):
        home = HOME.read_text(encoding="utf-8")
        artwork = (
            ROOT
            / "X5"
            / "Assets.xcassets"
            / "HomeAIInfluencerFeature.imageset"
            / "HomeAIInfluencerFeature.png"
        )

        self.assertIn("struct NativeHomeAIInfluencerFeatureCard", home)
        self.assertIn('Image("HomeAIInfluencerFeature")', home)
        self.assertIn('Text("AI-\\nинфлюенсер")', home)
        self.assertIn('Text("X5")', home)
        self.assertIn("static let businessFeatureHeight: CGFloat = 198", home)
        self.assertIn("static let businessFeatureOverflow: CGFloat = 38", home)
        self.assertIn('.accessibilityIdentifier("x5.home.business.ai_influencer")', home)
        self.assertLess(home.index("trendsSection"), home.index("businessSection"))
        self.assertTrue(artwork.exists(), "The AI feature must keep its content artwork")

    def test_sales_banner_is_native_and_opens_the_product_cards_tool(self):
        home = HOME.read_text(encoding="utf-8")

        self.assertIn("struct NativeHomeSalesBannerCard", home)
        for asset_name in (
            "ClientProductStepper",
            "ClientProductHeadphones",
            "ClientProductGamepad",
        ):
            self.assertIn(f'"{asset_name}"', home)
            imageset = ROOT / "X5" / "Assets.xcassets" / f"{asset_name}.imageset"
            self.assertTrue((imageset / "Contents.json").exists(), asset_name)
            self.assertTrue((imageset / f"{asset_name}.jpg").exists(), asset_name)
        self.assertNotIn('Image("HomeSalesBannerFeature")', home)
        self.assertNotIn("salesLabel(", home)
        self.assertIn('Text("Карточки\\nтоваров")', home)
        # 10.10 (Адильхан): большая «Карточки товаров» снова ведёт в «Продающие баннеры».
        self.assertIn('handle(imageAction("target_ad"))', home)

    def test_sales_banner_is_immediately_after_ai_influencer_before_tiles(self):
        home = HOME.read_text(encoding="utf-8")
        business = home.split("private var businessSection", 1)[1].split(
            "private var trendItems", 1
        )[0]

        influencer = business.index("NativeHomeAIInfluencerFeatureCard(")
        banner = business.index("NativeHomeSalesBannerCard(")
        # 09.10: сетки больше нет — одна плитка «Обложки YouTube» во всю ширину.
        tiles = business.index("ForEach(businessItems)")
        self.assertLess(influencer, banner)
        self.assertLess(banner, tiles)

    def test_ai_feature_keeps_copy_and_action_as_native_elements(self):
        home = HOME.read_text(encoding="utf-8")
        ai_card = home.split(
            "private struct NativeHomeAIInfluencerFeatureCard", 1
        )[1].split("private struct NativeHomeInstagramBackdrop", 1)[0]

        self.assertIn('Text("AI-\\nинфлюенсер")', ai_card)
        self.assertIn("LinearGradient(", ai_card)
        self.assertIn('Text("X5")', ai_card)
        self.assertIn("Button(action: action)", ai_card)

    def test_home_uses_compact_reference_proportions_instead_of_oversized_cards(self):
        home = HOME.read_text(encoding="utf-8")

        for required in (
            "private enum HomeLayout",
            "static let heroHeight: CGFloat = 198",
            "static let promoHeight: CGFloat = 78",
            "static let trendCardSize = CGSize(width: 112, height: 178)",
            "static let trendMediaHeight: CGFloat = 146",
            ".font(HomeTypography.trendTitle)",
            ".minimumScaleFactor(0.76)",
            ".allowsTightening(true)",
            "static let businessFeatureHeight: CGFloat = 198",
            "static let businessTileHeight: CGFloat = 112",
            ".frame(height: HomeLayout.heroHeight)",
            ".frame(height: HomeLayout.promoHeight)",
            "width: HomeLayout.trendCardSize.width",
        ):
            self.assertIn(required, home)

        self.assertNotIn("minHeight: 130", home)
        self.assertNotIn("width: 164, height: 238", home)

    def test_new_business_artwork_cannot_expand_home_past_the_phone_width(self):
        home = HOME.read_text(encoding="utf-8")
        ai_card = home.split(
            "private struct NativeHomeAIInfluencerFeatureCard", 1
        )[1].split("private struct NativeHomeInstagramBackdrop", 1)[0]
        sales_card = home.split(
            "private struct NativeHomeSalesBannerCard", 1
        )[1].split("private struct NativeHomePageDots", 1)[0]

        for card in (ai_card, sales_card):
            self.assertIn("GeometryReader { proxy in", card)
            self.assertIn("width: proxy.size.width", card)
            self.assertIn("height: proxy.size.height", card)

    def test_compact_promo_buttons_do_not_force_bad_wraps_on_small_iphones(self):
        home = HOME.read_text(encoding="utf-8")

        self.assertIn('subtitle: "Специалисты и задания"', home)
        self.assertIn(".frame(width: 34, height: 34)", home)
        self.assertIn(".font(.system(size: 14, weight: .bold))", home)
        self.assertIn(".font(.system(size: 11, weight: .medium))", home)
        self.assertNotIn('subtitle: "Специалисты\\nи задания"', home)

    def test_header_search_gallery_and_more_are_working_surfaces(self):
        home = HOME.read_text(encoding="utf-8")

        self.assertIn("HomeSearchSheet", home)
        self.assertIn("searchable(text: $query", home)
        self.assertIn("GeneratedGalleryView()", home)
        self.assertIn('accessibilityLabel("Поиск инструментов")', home)
        self.assertIn('accessibilityLabel(loc.t("gen_gallery"))', home)
        self.assertIn('Label("Еще", systemImage: "chevron.right")', home)
        self.assertIn("handle(.videoGeneration)", home)
        self.assertIn('HomeSearchItem(title: "Озвучка"', home)

    def test_hero_is_native_and_has_functional_pages(self):
        home = HOME.read_text(encoding="utf-8")

        self.assertIn("TabView(selection: $activeHeroPage)", home)
        self.assertIn(".tabViewStyle(.page(indexDisplayMode: .never))", home)
        self.assertIn('accessibilityIdentifier("x5.home.hero.\\(slide.id)")', home)
        self.assertIn('assetName: "HomeCoverTargetAds"', home)
        self.assertIn('assetName: "HomeUtilityVideo"', home)
        self.assertIn('assetName: "HomeTrendFruitVideo"', home)
        self.assertIn("action: .videoGeneration", home)
        self.assertIn("action: .liveFruits", home)

    def test_every_trend_autoplays_video_and_opens_a_real_route(self):
        home = HOME.read_text(encoding="utf-8")

        self.assertIn("handle(item.action)", home)
        self.assertIn('accessibilityIdentifier("x5.home.trend.\\(item.id)")', home)
        self.assertNotIn('accessibilityIdentifier("x5.home.trend.\\(item.id).preview")', home)
        self.assertIn('id: "strawberry"', home)
        self.assertIn("action: .liveFruits", home)
        self.assertIn('id: "wildberries"', home)
        self.assertIn('action: imageAction("product_cards")', home)

    def test_trends_autoplay_clean_video_with_only_a_caption_below(self):
        home = HOME.read_text(encoding="utf-8")
        card = home.split("private struct NativeHomeTrendCard", 1)[1].split(
            "private struct NativeHomeAIInfluencerFeatureCard", 1
        )[0]

        self.assertIn("LoopingVideo(", card)
        self.assertIn("isActive: true", card)
        self.assertIn("Text(item.title)", card)
        self.assertNotIn("if isPlaying", card)
        self.assertNotIn("Text(item.subtitle)", card)
        self.assertNotIn('Text("VIDEO")', card)
        self.assertNotIn('Image(systemName: isPlaying ? "pause.fill" : "play.fill")', card)
        self.assertNotIn("LinearGradient(", card)

    def test_ai_influencer_title_is_explicitly_complete(self):
        home = HOME.read_text(encoding="utf-8")
        card = home.split(
            "private struct NativeHomeAIInfluencerFeatureCard", 1
        )[1].split("private struct NativeHomeInstagramBackdrop", 1)[0]

        self.assertIn('Text("AI-\\nинфлюенсер")', card)
        self.assertIn(".lineLimit(2)", card)
        self.assertIn(".minimumScaleFactor(0.8)", card)

    def test_business_section_and_sales_banner_use_clean_native_chrome(self):
        home = HOME.read_text(encoding="utf-8")
        sales = home.split("private struct NativeHomeSalesBannerCard", 1)[1].split(
            "private struct NativeHomePageDots", 1
        )[0]

        self.assertIn("private enum HomeTypography", home)
        self.assertIn(".font(HomeTypography.featureTitle)", home)
        self.assertNotIn("design: .rounded", home)
        self.assertNotIn("salesLabel(", sales)
        self.assertIn("LinearGradient(", sales)
        self.assertIn("ZStack(alignment: .trailing)", sales)
        self.assertNotIn("ForEach(clientDesigns", sales)
        self.assertIn('Text("Карточки\\nтоваров")', sales)
        self.assertIn('Text("Создать")', sales)
        self.assertIn("clientProductArt(\"ClientProductStepper\")", sales)
        self.assertIn("clientProductArt(\"ClientProductHeadphones\")", sales)
        self.assertIn("clientProductArt(\"ClientProductGamepad\")", sales)
        self.assertIn(".rotationEffect(.degrees(-8))", sales)
        self.assertIn(".rotationEffect(.degrees(9))", sales)
        self.assertIn(".scaledToFit()", sales)
        self.assertNotIn('Image("HomeSalesBannerFeature")', sales)

    def test_search_waits_for_sheet_dismissal_before_routing(self):
        home = HOME.read_text(encoding="utf-8")

        self.assertIn("@State private var pendingSearchRoute: HomeRoute?", home)
        self.assertIn("onDismiss: completePendingSearchRoute", home)
        self.assertIn("pendingSearchRoute = route", home)
        self.assertIn("showingSearch = false", home)

    def test_automatic_trend_playback_uses_live_visibility_state(self):
        home = HOME.read_text(encoding="utf-8")
        looping_video = LOOPING_VIDEO.read_text(encoding="utf-8")

        self.assertNotIn("activeTrendVideoID", home)
        self.assertIn("isUserInitiated: false", home)
        self.assertNotIn("motionPreviewAllowed", home)
        self.assertIn("isUserInitiated || (!reduceMotion && !lowPowerMode)", looping_video)
        self.assertIn(".onGeometryChange(for: Bool.self)", looping_video)

    def test_system_tab_bar_is_native_and_never_replaced(self):
        source = TAB_VIEW.read_text(encoding="utf-8")

        self.assertIn("TabView(selection: $selectedTab)", source)
        self.assertIn(".tint(X5Style.blue)", source)
        self.assertNotIn("X5BottomTabBar", source)
        self.assertNotIn(".toolbar(.hidden, for: .tabBar)", source)
        self.assertNotIn(".safeAreaInset(edge: .bottom", source)
        self.assertNotIn("itemCenters", source)
        self.assertNotIn("GeometryReader", source)
        for key in ("tab_home", "tab_courses", "tab_chats", "tab_hub", "tab_profile"):
            self.assertIn(f'return "{key}"', source)
        self.assertEqual(source.count(".tabItem"), 5)
        self.assertIn("enum X5AppTab: Int, CaseIterable, Identifiable", source)
        self.assertNotIn("private var selectedContent", source)


if __name__ == "__main__":
    unittest.main()
