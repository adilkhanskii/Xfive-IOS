import SwiftUI
import UIKit
import PencilKit
import PhotosUI

struct ImageGeneratorView: View {
    @EnvironmentObject private var auth: Auth
    @EnvironmentObject private var currentUser: CurrentUser
    @EnvironmentObject private var loc: LocalizationService

    let category: ImageGenerationCategory

    @State private var prompt: String
    @State private var selectedProvider: ImageGenerationProvider
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var generatedAsset: GeneratedImageAsset?
    @State private var generatedAssets: [GeneratedImageAsset] = []
    @State private var viewerAsset: GeneratedImageAsset?
    @State private var selectedQuantity = 1
    @State private var selectedSize: ImageGenerationSize = .square
    @State private var showingGallery = false
    // «Фото героя» / «Основная фотография» и логотип — через галерею UIKit
    // (SystemPhotoPicker): SwiftUI-шная перезапускалась при перерисовке экрана (Адильхан 10.10).
    @State private var showingMainPhotoPicker = false
    @State private var showingLogoPicker = false
    /// Номер последнего выбора по слоту: результат старой загрузки не ставим.
    @State private var mainPhotoPickID = 0
    @State private var logoPickID = 0
    @State private var referenceItems: [PhotosPickerItem] = []
    @State private var mainPhoto: ImageReferenceAsset?
    @State private var logoImage: ImageReferenceAsset?
    @State private var referenceImages: [ImageReferenceAsset] = []
    @State private var isLoadingReferences = false
    // Отдельные флаги для «Фото героя»/«Основная фотография» и логотипа:
    // раньше у них не было ни спиннера, ни ошибки — фото из iCloud грузилось
    // секунды или падало молча, и казалось, что выбор «не прикрепился».
    @State private var isLoadingMainPhoto = false
    @State private var isLoadingLogo = false
    @State private var photoLoadError: String?
    @State private var selectedSalesAngle: SalesAngle
    /// Layout recipe used by the previous sales creative, so the next one is
    /// never the same composition twice in a row.
    @State private var lastSalesVariationID: String?
    @State private var selectedYouTubeMode: YouTubeThumbnailMode
    @State private var selectedProductCardTypes: Set<String> = [ProductCardType.main.id]
    @State private var productName = ""
    @State private var productPrice = ""
    @State private var productCharacteristics = ""
    @State private var productBenefits = ""
    @State private var productPromotion = ""
    @State private var productLanguage = "Русский"
    @State private var productMarketplace = "Kaspi"
    @State private var productStyle = "Премиальный"
    @State private var showGenerationComplete = false
    @State private var studioCapabilities: AIStudioCapabilities?
    @StateObject private var gallery = GeneratedGalleryStore()
    private let studioService = AIStudioService()
    @FocusState private var promptFocused: Bool

    init(category: ImageGenerationCategory = ImageGenerationCatalog.custom, provider: ImageGenerationProvider = .gptImage2) {
        self.category = category
        let isSalesCreative = category.id == "product_cards" || category.id == "target_ad"
        let isYouTubeThumbnail = category.id == "youtube_cover"
        _prompt = State(initialValue: isSalesCreative || isYouTubeThumbnail ? "" : category.examplePrompt)
        _selectedProvider = State(initialValue: provider)
        _selectedSize = State(initialValue: category.id == "youtube_cover" ? .landscape : .square)
        _selectedSalesAngle = State(initialValue: SalesAngle.all[0])
        _selectedYouTubeMode = State(initialValue: YouTubeThumbnailMode.all[0])
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                providerPanel
                settingsPanel
                if isSalesCreativeCategory {
                    salesAnglePanel
                }
                if isProductCardsCategory {
                    productCardsPanel
                }
                if isYouTubeThumbnailCategory {
                    youtubeModePanel
                }
                promptPanel
                referencePanel
                generateButton

                if isGenerating {
                    GenerationAnimationView(provider: selectedProvider,
                                            category: category)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }

                if showGenerationComplete {
                    generationCompleteBanner
                        .transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.96)))
                }

                resultPanel
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 32)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(generatorBackdrop)
        .navigationTitle(categoryTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    X5Feedback.impact()
                    showingGallery = true
                } label: {
                    Image(systemName: "photo.stack")
                }
                .accessibilityLabel(loc.t("gen_gallery"))
            }
        }
        .task {
            await refreshProfileIfPossible()
            await refreshCapabilities()
        }
        .sheet(isPresented: $showingGallery) {
            GeneratedGalleryView()
        }
        .onChange(of: referenceItems) { newItems in
            Task { await loadReferenceImages(newItems) }
        }
        .x5SinglePhotoPicker(isPresented: $showingMainPhotoPicker) { provider in
            Task { await loadSinglePhoto(provider, slot: .main) }
        }
        .x5SinglePhotoPicker(isPresented: $showingLogoPicker) { provider in
            Task { await loadSinglePhoto(provider, slot: .logo) }
        }
        .onChange(of: selectedProvider) { provider in
            if !selectedSize.isSupported(by: provider) {
                selectedSize = .square
            }
        }
        .fullScreenCover(item: $viewerAsset) { asset in
            GeneratedImageViewer(asset: asset, onImageUpdated: { image in
                if var updated = generatedAsset {
                    updated.image = image
                    generatedAsset = updated
                }
                if let index = generatedAssets.firstIndex(where: { $0.id == asset.id }) {
                    generatedAssets[index].image = image
                }
            }, onSaveToGallery: { image in
                saveAssetToGallery(asset, image: image)
            }, onRegenerate: { editPrompt, image in
                let clean = editPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty, let reference = makeReference(from: image) else { return }
                prompt = clean
                Task { await generate(promptOverride: clean, referencesOverride: [reference]) }
            })
            .environmentObject(loc)
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(systemName: category.icon)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 46, height: 46)
                    .background(
                        LinearGradient(colors: [category.gradientStart, X5Style.blue.opacity(0.28)],
                                       startPoint: .topLeading,
                                       endPoint: .bottomTrailing)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Spacer()
                Text("\(totalCreditCost) \(loc.t("gen_credits"))")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundColor(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.88))
                    .clipShape(Capsule())
            }

            Text(categoryTitle)
                .font(.system(size: 30, weight: .heavy))
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)

            Text(categorySubtitle)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.62))
        }
        .padding(18)
        .x5ClearGlass(cornerRadius: 20, highlight: 0.13)
    }

    private var providerPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel(loc.t("gen_model"))

            Menu {
                ForEach(availableProviders) { model in
                    Button {
                        X5Feedback.selection()
                        selectedProvider = model
                    } label: {
                        menuChoiceLabel(model.title, isSelected: model == selectedProvider)
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    ProviderLogo(provider: selectedProvider)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedProvider.title)
                            .font(.system(size: 15, weight: .heavy))
                        Text(selectedProvider.subtitle)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.58))
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.52))
                }
                .foregroundColor(.white)
                .padding(12)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(isGenerating || category.id == "logo")

            HStack {
                Label("\(totalCreditCost)", systemImage: "creditcard")
                Spacer()
                Text(balanceText)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white.opacity(0.58))

            if studioCapabilities != nil && !imageCapability.available {
                Label(imageUnavailableMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .x5ClearGlass(cornerRadius: 18, highlight: 0.10)
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel(loc.t("gen_settings"))

            if !isProductCardsCategory && category.id != "content_pack" {
                Stepper(value: $selectedQuantity, in: 1...4) {
                    HStack(spacing: 10) {
                        Image(systemName: "number")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(loc.t("gen_quantity"))
                                .font(.system(size: 15, weight: .heavy))
                            Text("\(selectedQuantity) x \(ImageGenerationCatalog.creditCost) = \(totalCreditCost) \(loc.t("gen_credits"))")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white.opacity(0.58))
                        }
                    }
                    .foregroundColor(.white)
                }
                .disabled(isGenerating)
            }

            Menu {
                ForEach(ImageGenerationSize.allCases) { size in
                    if !size.isSupported(by: selectedProvider) {
                        Button {} label: {
                            Label("\(size.title) · \(size.unavailableLabel(for: selectedProvider))", systemImage: "lock")
                        }
                        .disabled(true)
                    } else {
                        Button {
                            X5Feedback.selection()
                            selectedSize = size
                        } label: {
                            menuChoiceLabel("\(size.title) · \(size.subtitle)", isSelected: size == selectedSize)
                        }
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "aspectratio")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(loc.t("gen_size"))
                            .font(.system(size: 15, weight: .heavy))
                        Text("\(selectedSize.title) · \(selectedSize.subtitle)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.58))
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.52))
                }
                .foregroundColor(.white)
                .padding(12)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(isGenerating)
        }
        .padding(14)
        .x5ClearGlass(cornerRadius: 18, highlight: 0.10)
    }

    private var salesAnglePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("Угол продаж")

            Menu {
                ForEach(SalesAngle.all) { angle in
                    Button {
                        X5Feedback.selection()
                        selectedSalesAngle = angle
                    } label: {
                        menuChoiceLabel(angle.title, isSelected: angle == selectedSalesAngle)
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "scope")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(X5Style.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedSalesAngle.title)
                            .font(.system(size: 15, weight: .heavy))
                            .foregroundColor(.white)
                        Text(selectedSalesAngle.summary)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.58))
                            .lineLimit(2)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.52))
                }
                .padding(12)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(isGenerating)

            VStack(alignment: .leading, spacing: 5) {
                Text("Примеры")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundColor(.white.opacity(0.52))
                ForEach(selectedSalesAngle.examples.prefix(2), id: \.self) { example in
                    Text("• \(example)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.72))
                }
            }
        }
        .padding(14)
        .x5ClearGlass(cornerRadius: 18, highlight: 0.11)
        .accessibilityIdentifier("x5.generator.sales_angle")
    }

    private var productCardsPanel: some View {
        VStack(alignment: .leading, spacing: 13) {
            sectionLabel("Набор карточек")

            ForEach(ProductCardType.all) { cardType in
                Button {
                    X5Feedback.selection()
                    if selectedProductCardTypes.contains(cardType.id) {
                        if selectedProductCardTypes.count > 1 {
                            selectedProductCardTypes.remove(cardType.id)
                        }
                    } else {
                        selectedProductCardTypes.insert(cardType.id)
                    }
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: selectedProductCardTypes.contains(cardType.id)
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(selectedProductCardTypes.contains(cardType.id)
                                             ? X5Style.blue : .white.opacity(0.42))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cardType.title)
                                .font(.system(size: 14, weight: .heavy))
                                .foregroundColor(.white)
                            Text(cardType.summary)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white.opacity(0.54))
                        }
                        Spacer()
                        Text("60 ₸")
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundColor(.white.opacity(0.66))
                    }
                    .padding(11)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isGenerating)
            }

            sectionLabel("Данные инфографики")
            productField("Название товара", text: $productName)
            productField("Цена", text: $productPrice)
            productField("Характеристики — только точные факты", text: $productCharacteristics, lines: 3)
            productField("Выгоды", text: $productBenefits, lines: 3)
            productField("Акция или условие", text: $productPromotion)

            HStack(spacing: 8) {
                productMenu(title: "Язык", value: $productLanguage, values: ["Русский", "Қазақша", "English"])
                productMenu(title: "Маркетплейс", value: $productMarketplace, values: ["Kaspi", "Wildberries", "Ozon", "Другое"])
            }
            productMenu(title: "Стиль", value: $productStyle, values: ["Премиальный", "Минимализм", "Яркий", "Технологичный", "Натуральный"])

            Text("Каждый выбранный кадр создаётся отдельным заданием. Ошибка одного кадра не списывает деньги за остальные.")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.50))
        }
        .padding(14)
        .x5ClearGlass(cornerRadius: 18, highlight: 0.11)
        .accessibilityIdentifier("x5.generator.product_cards")
    }

    private func productField(
        _ title: String,
        text: Binding<String>,
        lines: Int = 1
    ) -> some View {
        TextField(title, text: text, axis: lines > 1 ? .vertical : .horizontal)
            .lineLimit(lines...max(lines, lines + 2))
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .padding(11)
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Пункт меню выбора: у выбранного — галочка, у остальных — ничего.
    /// Зачем: раньше невыбранные пункты показывали свои иконки (квадрат, искры,
    /// зелёный кружок), и было непонятно, что выбрано (Адильхан 09.10, «галочки»).
    /// Замки у недоступных размеров остаются — это другой смысл.
    @ViewBuilder
    private func menuChoiceLabel(_ title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private func productMenu(
        title: String,
        value: Binding<String>,
        values: [String]
    ) -> some View {
        Menu {
            ForEach(values, id: \.self) { option in
                Button {
                    value.wrappedValue = option
                } label: {
                    menuChoiceLabel(option, isSelected: option == value.wrappedValue)
                }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundColor(.white.opacity(0.46))
                    Text(value.wrappedValue)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white.opacity(0.45))
            }
            .padding(10)
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var youtubeModePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("Стиль обложки")

            Menu {
                ForEach(YouTubeThumbnailMode.all) { mode in
                    Button {
                        X5Feedback.selection()
                        selectedYouTubeMode = mode
                    } label: {
                        menuChoiceLabel(mode.title, isSelected: mode == selectedYouTubeMode)
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: selectedYouTubeMode.icon)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.red)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(selectedYouTubeMode.title)
                                .font(.system(size: 15, weight: .heavy))
                                .foregroundColor(.white)

                            if selectedYouTubeMode.isRecommended {
                                Text("TOP")
                                    .font(.system(size: 8, weight: .black, design: .rounded))
                                    .foregroundColor(.black)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(X5Style.blue, in: Capsule())
                            }
                        }

                        Text(selectedYouTubeMode.summary)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.58))
                            .lineLimit(2)
                    }

                    Spacer()

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.52))
                }
                .padding(12)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(isGenerating)

        }
        .padding(14)
        .x5ClearGlass(cornerRadius: 18, highlight: 0.11)
        .accessibilityIdentifier("x5.generator.youtube_mode")
    }

    private var promptPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel(
                isSalesCreativeCategory
                    ? "Описание товара или услуги"
                    : (isYouTubeThumbnailCategory ? "Тема ролика" : loc.t("gen_prompt"))
            )

            TextField(promptPlaceholder, text: $prompt, axis: .vertical)
                .focused($promptFocused)
                .lineLimit(4...7)
                .font(.system(size: 15))
                .foregroundColor(.white)
                .padding(14)
                .background(Color.white.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            if isSalesCreativeCategory {
                Text("Укажите цену, город, акцию и важные условия. AI сам соберет продающий текст и впишет его в дизайн.")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.54))
            } else if isYouTubeThumbnailCategory {
                Text("Опишите сюжет, героя и главный смысл ролика. AI предложит короткий заголовок и соберёт обложку в выбранном режиме.")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.54))
            }
        }
        .padding(14)
        .x5ClearGlass(cornerRadius: 18, highlight: 0.11)
    }

    private var referencePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionLabel(
                    isSalesCreativeCategory
                        ? "Фотографии и логотип"
                        : (isYouTubeThumbnailCategory ? "Фото героя и референсы" : "Референсы")
                )
                Spacer()
                if isLoadingReferences {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.8)
                }
            }

            if isSalesCreativeCategory {
                Text("Добавьте основную фотографию, логотип, также можете использовать референс.")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.72))

                Button { showingMainPhotoPicker = true } label: {
                    uploadSlot(
                        title: "Основная фотография",
                        subtitle: mainPhoto == nil ? "Товар, услуга или человек" : "Фотография добавлена",
                        image: mainPhoto?.image,
                        systemImage: "photo",
                        isLoading: isLoadingMainPhoto
                    )
                }
                .buttonStyle(.plain)
                .disabled(isGenerating || isLoadingReferences || isLoadingMainPhoto)

                Button { showingLogoPicker = true } label: {
                    uploadSlot(
                        title: "Логотип",
                        subtitle: logoImage == nil ? "Разместим аккуратно в макете" : "Логотип добавлен",
                        image: logoImage?.image,
                        systemImage: "seal",
                        isLoading: isLoadingLogo
                    )
                }
                .buttonStyle(.plain)
                .disabled(isGenerating || isLoadingReferences || isLoadingLogo)

                PhotosPicker(selection: $referenceItems, maxSelectionCount: 4, matching: .images) {
                    uploadSlot(
                        title: "Референс",
                        subtitle: referenceImages.isEmpty ? "Пример желаемого оформления" : "Добавлено: \(referenceImages.count)",
                        image: referenceImages.first?.image,
                        systemImage: "rectangle.stack"
                    )
                }
                .buttonStyle(.plain)
                .disabled(isGenerating || isLoadingReferences)
            } else if isYouTubeThumbnailCategory {
                Text("Добавьте фото героя, чтобы сохранить внешность, и примеры понравившихся обложек для стиля.")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.72))

                Button { showingMainPhotoPicker = true } label: {
                    uploadSlot(
                        title: "Фото героя",
                        subtitle: mainPhoto == nil ? "Лицо или главный персонаж ролика" : "Фото героя добавлено",
                        image: mainPhoto?.image,
                        systemImage: "person.crop.rectangle",
                        isLoading: isLoadingMainPhoto
                    )
                }
                .buttonStyle(.plain)
                .disabled(isGenerating || isLoadingReferences || isLoadingMainPhoto)

                PhotosPicker(selection: $referenceItems, maxSelectionCount: 4, matching: .images) {
                    uploadSlot(
                        title: "Примеры обложек",
                        subtitle: referenceImages.isEmpty ? "До 4 референсов оформления" : "Добавлено: \(referenceImages.count)",
                        image: referenceImages.first?.image,
                        systemImage: "rectangle.stack"
                    )
                }
                .buttonStyle(.plain)
                .disabled(isGenerating || isLoadingReferences)
            } else {
                PhotosPicker(selection: $referenceItems, maxSelectionCount: 6, matching: .images) {
                    Label(referenceImages.isEmpty ? "Добавить фото" : "Изменить фото", systemImage: "photo.badge.plus")
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isGenerating || isLoadingReferences)
            }

            if !referenceImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(referenceImages) { item in
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: item.image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 76, height: 76)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                                    )

                                Button {
                                    // Drop it from the picker selection too:
                                    // otherwise the photo is still selected and
                                    // comes back on the next pick.
                                    referenceImages.removeAll { $0.id == item.id }
                                    referenceItems.removeAll {
                                        Self.referenceIdentity($0) == item.id
                                    }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 20, weight: .bold))
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.62))
                                }
                                .buttonStyle(.plain)
                                .offset(x: 7, y: -7)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                    .padding(.trailing, 8)
                }

                Text(isSalesCreativeCategory
                     ? "Референсы задают стиль. Основная фотография и логотип используются отдельно."
                     : (isYouTubeThumbnailCategory
                        ? "Примеры задают стиль обложки. Фото героя используется отдельно и сохраняет внешность."
                        : "AI будет использовать эти фото как референсы: изменить, добавить, убрать или сгенерировать похожую картинку."))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.54))
            }

            // Ошибку фото показываем прямо под слотами, а не молча.
            if let photoLoadError {
                Label(photoLoadError, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .x5ClearGlass(cornerRadius: 18, highlight: 0.10)
    }

    private func uploadSlot(
        title: String,
        subtitle: String,
        image: UIImage?,
        systemImage: String,
        isLoading: Bool = false
    ) -> some View {
        HStack(spacing: 12) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(X5Style.blue)
                    .frame(width: 52, height: 52)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundColor(.white)
                Text(isLoading ? "Загружаем фото…" : subtitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.54))
                    .lineLimit(1)
            }
            Spacer()
            if isLoading {
                // Видно, что фото принято и грузится (из iCloud это бывает долго).
                ProgressView()
                    .tint(.white)
                    .frame(width: 20, height: 20)
            } else {
                Image(systemName: image == nil ? "plus.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(image == nil ? .white.opacity(0.56) : X5Style.blue)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var generateButton: some View {
        Button {
            X5Feedback.impact(.medium)
            Task { await generate() }
        } label: {
            HStack(spacing: 8) {
                if isGenerating {
                    ProgressView().tint(.black)
                } else {
                    Image(systemName: "wand.and.stars")
                }
                Text(generateButtonTitle)
            }
            .font(.system(size: 16, weight: .heavy))
            .foregroundColor(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(canGenerate ? Color.white.opacity(0.92) : Color.gray.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!canGenerate || isGenerating)
    }

    @ViewBuilder
    private var resultPanel: some View {
        if let generatedAsset {
            VStack(alignment: .leading, spacing: 12) {
                if generatedAssets.count > 1 {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(generatedAssets) { asset in
                            generatedImageButton(asset, compact: true)
                        }
                    }
                } else {
                    generatedImageButton(generatedAsset, compact: false)
                }

                HStack {
                    Label(loc.t("gen_open_viewer"), systemImage: "arrow.up.left.and.arrow.down.right")
                    Spacer()
                    Text("\(generatedAssets.count) / \(generatedAsset.sizeLabel)")
                }
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white.opacity(0.82))
            }
            .padding(12)
            .x5ClearGlass(cornerRadius: 18, highlight: 0.10)
        } else if let errorMessage {
            Text(errorMessage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.red.opacity(0.95))
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var generatorBackdrop: some View {
        ZStack {
            X5Background()
            RadialGradient(colors: [category.gradientStart.opacity(0.45), Color.clear],
                           center: .topTrailing, startRadius: 10, endRadius: 280)
                .ignoresSafeArea()
            RadialGradient(colors: [Color(red: 0.13, green: 0.33, blue: 0.55).opacity(0.24), Color.clear],
                           center: .bottomLeading, startRadius: 20, endRadius: 320)
                .ignoresSafeArea()
        }
    }

    private var currentCredits: Int? {
        guard let profile = currentUser.profile else { return nil }
        return profile.credits ?? 0
    }

    private var hasEnoughCredits: Bool {
        guard let currentCredits else { return false }
        return currentCredits >= totalCreditCost
    }

    private var canGenerate: Bool {
        hasValidPromptOrReferences &&
        currentCredits != nil &&
        hasEnoughCredits &&
        imageCapability.available
    }

    private var hasValidPromptOrReferences: Bool {
        let hasDescription = prompt.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3
        if isProductCardsCategory {
            return hasDescription && !selectedProductCardTypes.isEmpty
                && (!productName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || mainPhoto != nil)
        }
        return (isSalesCreativeCategory || isYouTubeThumbnailCategory)
            ? hasDescription
            : (hasDescription || !roleAwareReferences.isEmpty)
    }

    private var balanceText: String {
        guard let currentCredits else { return loc.t("gen_loading_balance") }
        return "\(loc.t("gen_balance")): \(currentCredits)"
    }

    private var generateButtonTitle: String {
        if isGenerating { return loc.t("gen_generating") }
        if studioCapabilities != nil && !imageCapability.available { return "Сервис временно недоступен" }
        if currentCredits == nil { return loc.t("gen_loading_balance") }
        if !hasEnoughCredits { return "\(loc.t("gen_need")) \(totalCreditCost) \(loc.t("gen_credits"))" }
        if !hasValidPromptOrReferences { return loc.t("gen_prompt_required") }
        return loc.t("gen_generate")
    }

    private var totalCreditCost: Int {
        let frameCount: Int
        if isProductCardsCategory {
            frameCount = max(1, selectedProductCardTypes.count)
        } else if category.id == "content_pack" {
            frameCount = 3
        } else {
            frameCount = selectedQuantity
        }
        return ImageGenerationCatalog.creditCost * frameCount
    }

    private var isSalesCreativeCategory: Bool {
        category.id == "product_cards" || category.id == "target_ad"
    }

    private var isProductCardsCategory: Bool {
        category.id == "product_cards"
    }

    private var isYouTubeThumbnailCategory: Bool {
        category.id == "youtube_cover"
    }

    private var promptPlaceholder: String {
        if isSalesCreativeCategory {
            return "Опишите вашу услугу или товар. В конце укажите стоимость, город, акции и другие важные условия."
        }
        if isYouTubeThumbnailCategory {
            return "Например: почему малый бизнес теряет клиентов из-за слабой рекламы, в кадре владелец бизнеса и разбор ошибок"
        }
        return category.examplePrompt
    }

    private var roleAwareReferences: [ImageGenerationReference] {
        var references: [ImageGenerationReference] = []
        if let mainPhoto {
            let role: ImageGenerationReferenceRole
            if isProductCardsCategory || category.id == "product" || category.id == "packaging" {
                role = .mainProduct
            } else if isYouTubeThumbnailCategory {
                role = .heroFace
            } else if category.id == "ai_character" {
                role = .characterReference
            } else {
                role = .sourceImage
            }
            references.append(mainPhoto.reference(with: role))
        }
        if let logoImage {
            references.append(logoImage.reference(with: .logo))
        }
        references.append(contentsOf: referenceImages.map { $0.reference(with: .styleReference) })
        return references
    }

    private var availableProviders: [ImageGenerationProvider] {
        let categoryProviders: [ImageGenerationProvider] = category.id == "logo"
            ? [.gptImage2]
            : ImageGenerationProvider.allCases
        guard let studioCapabilities else { return categoryProviders }
        return categoryProviders.filter { studioCapabilities.supportsImageModel($0.rawValue) }
    }

    private var imageCapabilityID: String {
        switch category.id {
        case "logo": return "transparent_logo"
        case "product_cards": return "product_cards"
        case "youtube_cover": return "youtube_cover"
        case "edit_image": return "image_editor"
        case "moodboard": return "moodboard"
        case "content_pack": return "content_pack"
        default: return "image_generation"
        }
    }

    private var imageCapability: AIStudioToolCapability {
        studioCapabilities?.tool(imageCapabilityID)
            ?? AIStudioToolCapability(available: false, unavailableReason: "checking")
    }

    private var imageUnavailableMessage: String {
        switch imageCapability.unavailableReason {
        case "provider_balance_or_quota":
            return "У провайдера закончился баланс или квота. Кредиты не списываются."
        case "provider_auth_failed":
            return "Провайдер отклонил доступ. Кредиты не списываются."
        case "provider_model_unavailable":
            return "Выбранная модель временно недоступна. Кредиты не списываются."
        default:
            return "Провайдер не прошёл проверку. Кредиты не списываются."
        }
    }

    private func generatedImageButton(_ asset: GeneratedImageAsset, compact: Bool) -> some View {
        Button {
            X5Feedback.impact()
            viewerAsset = asset
        } label: {
            Image(uiImage: asset.image)
                .resizable()
                .scaledToFill()
                .aspectRatio(asset.aspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: compact ? 14 : 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: compact ? 14 : 18, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .heavy))
            .tracking(1.2)
            .foregroundColor(.white.opacity(0.45))
    }

    private func refreshProfileIfPossible() async {
        guard let uid = auth.userId, let token = await auth.freshAccessToken() else { return }
        await currentUser.load(userId: uid, accessToken: token)
    }

    private func generate(
        promptOverride: String? = nil,
        referencesOverride: [ImageGenerationReference]? = nil
    ) async {
        guard let profileOperation = currentUser.operationContext() else { return }
        let currentReferences = referencesOverride ?? roleAwareReferences
        let rawPrompt = promptOverride ?? prompt
        let cleanPrompt: String
        if isYouTubeThumbnailCategory && promptOverride == nil {
            guard rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else {
                errorMessage = "Опишите тему ролика"
                return
            }
            cleanPrompt = YouTubeThumbnailBriefBuilder.compose(
                topic: rawPrompt,
                mode: selectedYouTubeMode,
                hasHeroPhoto: mainPhoto != nil,
                referenceCount: referenceImages.count
            )
        } else if isProductCardsCategory && promptOverride == nil {
            guard rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else {
                errorMessage = "Опишите товар"
                return
            }
            cleanPrompt = productCardBrief(description: rawPrompt)
        } else if isSalesCreativeCategory && promptOverride == nil {
            guard rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else {
                errorMessage = "Опишите товар или услугу"
                return
            }
            let variation = SalesCreativeVariation.pick(excluding: lastSalesVariationID)
            lastSalesVariationID = variation.id
            cleanPrompt = SalesCreativeBriefBuilder.compose(
                description: rawPrompt,
                angle: selectedSalesAngle,
                hasMainPhoto: mainPhoto != nil,
                hasLogo: logoImage != nil,
                referenceCount: referenceImages.count,
                variation: variation
            )
        } else {
            cleanPrompt = effectivePrompt(rawPrompt, hasReferences: !currentReferences.isEmpty)
        }
        guard !cleanPrompt.isEmpty else {
            errorMessage = loc.t("gen_prompt_required")
            return
        }
        guard !isGenerating else { return }

        promptFocused = false
        isGenerating = true
        errorMessage = nil
        generatedAsset = nil
        generatedAssets = []
        showGenerationComplete = false
        defer {
            isGenerating = false
        }

        await refreshProfileIfPossible()
        guard let operationToken = await currentUser.accessTokenForOperation(profileOperation, refresh: {
            await auth.freshAccessToken(minimumValidity: 15 * 60)
        }) else { return }

        guard currentCredits != nil else {
            errorMessage = loc.t("gen_loading_balance")
            X5Feedback.warning()
            return
        }
        let creditsBefore = currentCredits ?? 0
        let isSeries = referencesOverride == nil
            && (isProductCardsCategory || category.id == "content_pack")
        let requestQuantity = referencesOverride == nil && !isSeries ? selectedQuantity : 1
        let requestCreditCost = isSeries
            ? totalCreditCost
            : ImageGenerationCatalog.creditCost * requestQuantity
        guard creditsBefore >= requestCreditCost else {
            errorMessage = loc.t("gen_not_enough_credits")
            X5Feedback.warning()
            return
        }

        do {
            if isSeries {
                let series = try await generateFrameSeries(
                    basePrompt: cleanPrompt,
                    references: currentReferences,
                    creditsBefore: creditsBefore,
                    operation: profileOperation,
                    accessToken: operationToken
                )
                guard currentUser.isCurrent(profileOperation) else { return }
                guard let firstAsset = series.assets.first else {
                    throw ImageGeneratorError.invalidImage
                }
                generatedAsset = firstAsset
                generatedAssets = series.assets
                series.assets.forEach { asset in
                    _ = saveAssetToGallery(asset, image: asset.image)
                }
                withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) {
                    showGenerationComplete = true
                }
                X5Feedback.successWithSound()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) {
                    withAnimation(.easeOut(duration: 0.25)) {
                        showGenerationComplete = false
                    }
                }
                currentUser.applyCreditsRemaining(series.creditsRemaining, for: profileOperation)
                if let partialFailure = series.partialFailure {
                    errorMessage = partialFailure
                }
                DiagnosticLogger.log(event: "image_series_generated", extra: [
                    "provider": selectedProvider.rawValue,
                    "category": category.id,
                    "quantity": "\(series.assets.count)"
                ])
                return
            }
            let response = try await auth.supabase.generateImageWithAccessToken(
                prompt: cleanPrompt,
                provider: selectedProvider,
                category: category,
                quantity: requestQuantity,
                size: selectedSize,
                referenceImages: currentReferences,
                accessToken: operationToken
            )
            guard currentUser.isCurrent(profileOperation) else { return }
            let encodedImages = response.imageBase64s?.isEmpty == false ? response.imageBase64s! : [response.imageBase64]
            let images = encodedImages.compactMap { encoded -> UIImage? in
                guard let data = Data(base64Encoded: encoded) else { return nil }
                return UIImage(data: data)
            }
            guard !images.isEmpty else {
                throw ImageGeneratorError.invalidImage
            }

            let costPerImage = max(1, (response.costCredits ?? requestCreditCost) / max(1, images.count))
            let assets = images.enumerated().map { index, image in
                GeneratedImageAsset(
                    image: image,
                    prompt: response.prompt,
                    provider: response.model ?? selectedProvider.rawValue,
                    category: response.category ?? category.id,
                    sizeLabel: response.size ?? "\(selectedSize.title) \(selectedSize.subtitle)",
                    costCredits: costPerImage,
                    creditsRemaining: response.creditsRemaining,
                    cloudAssetID: response.assetIds.flatMap {
                        $0.indices.contains(index) ? $0[index] : nil
                    }
                )
            }
            guard let firstAsset = assets.first else { throw ImageGeneratorError.invalidImage }
            generatedAsset = firstAsset
            generatedAssets = assets
            assets.forEach { asset in
                _ = saveAssetToGallery(asset, image: asset.image)
            }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) {
                showGenerationComplete = true
            }
            X5Feedback.successWithSound()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) {
                withAnimation(.easeOut(duration: 0.25)) {
                    showGenerationComplete = false
                }
            }
            let remainingCredits = response.creditsRemaining ?? max(creditsBefore - requestCreditCost, 0)
            currentUser.applyCreditsRemaining(remainingCredits, for: profileOperation)
            DiagnosticLogger.log(event: "image_generated", extra: [
                "provider": selectedProvider.rawValue,
                "category": category.id,
                "quantity": "\(assets.count)",
                "size": selectedSize.rawValue
            ])
        } catch {
            guard currentUser.isCurrent(profileOperation) else { return }
            DiagnosticLogger.log(event: "image_generation_failed", extra: [
                "summary": error.localizedDescription,
                "provider": selectedProvider.rawValue,
                "category": category.id
            ])
            X5Feedback.error()
            errorMessage = error.localizedDescription
        }
    }

    private func refreshCapabilities() async {
        guard let token = await auth.freshAccessToken() else { return }
        studioCapabilities = try? await studioService.capabilities(accessToken: token)
        if let first = availableProviders.first,
           !availableProviders.contains(selectedProvider) {
            selectedProvider = first
        }
    }

    private func generateFrameSeries(
        basePrompt: String,
        references: [ImageGenerationReference],
        creditsBefore: Int,
        operation: ProfileOperationContext,
        accessToken: String
    ) async throws -> ImageFrameSeriesResult {
        let specs: [ImageFrameSpec]
        if isProductCardsCategory {
            specs = ProductCardType.all
                .filter { selectedProductCardTypes.contains($0.id) }
                .map { type in
                    ImageFrameSpec(
                        title: type.title,
                        prompt: """
                        \(basePrompt)
                        Кадр набора: \(type.title).
                        Задача кадра: \(type.promptGuidance)
                        Это один кадр единого набора. Сохрани один товар, логотип, палитру, сетку и типографическую систему во всём наборе.
                        """,
                        size: selectedSize
                    )
                }
        } else {
            specs = [
                ImageFrameSpec(
                    title: "Пост",
                    prompt: "\(basePrompt)\nФормат комплекта: квадратный пост 1:1. Главный визуал и короткий оффер.",
                    size: .square
                ),
                ImageFrameSpec(
                    title: "Сторис",
                    prompt: "\(basePrompt)\nФормат комплекта: вертикальная сторис 9:16. Сохрани кампанию и адаптируй иерархию под телефон.",
                    size: .portrait
                ),
                ImageFrameSpec(
                    title: "Реклама",
                    prompt: "\(basePrompt)\nФормат комплекта: вертикальная реклама 9:16 с ясной выгодой и зоной действия. Не меняй продукт и фирменный стиль.",
                    size: .portrait
                )
            ]
        }

        var assets: [GeneratedImageAsset] = []
        var activeReferences = references
        var creditsRemaining = creditsBefore
        var lastError: Error?

        for spec in specs {
            guard currentUser.isCurrent(operation) else { throw CancellationError() }
            do {
                let response = try await auth.supabase.generateImageWithAccessToken(
                    prompt: spec.prompt,
                    provider: selectedProvider,
                    category: category,
                    quantity: 1,
                    size: spec.size,
                    referenceImages: activeReferences,
                    idempotencyKey: UUID().uuidString.lowercased(),
                    accessToken: accessToken
                )
                guard currentUser.isCurrent(operation) else { throw CancellationError() }
                let encoded = response.imageBase64s?.first ?? response.imageBase64
                guard let data = Data(base64Encoded: encoded),
                      let image = UIImage(data: data)
                else { throw ImageGeneratorError.invalidImage }
                let asset = GeneratedImageAsset(
                    image: image,
                    prompt: "\(spec.title): \(response.prompt)",
                    provider: response.model ?? selectedProvider.rawValue,
                    category: response.category ?? category.id,
                    sizeLabel: response.size ?? "\(spec.size.title) \(spec.size.subtitle)",
                    costCredits: response.costCredits ?? ImageGenerationCatalog.creditCost,
                    creditsRemaining: response.creditsRemaining,
                    cloudAssetID: response.assetIds?.first
                )
                assets.append(asset)
                creditsRemaining = response.creditsRemaining
                    ?? max(creditsRemaining - ImageGenerationCatalog.creditCost, 0)

                if assets.count == 1,
                   activeReferences.count < ImageGenerationReferencePolicy.maximumCount,
                   let anchorData = Self.uploadPayload(for: image) {
                    activeReferences.append(ImageGenerationReference(
                        mimeType: "image/jpeg",
                        base64: anchorData.base64EncodedString(),
                        role: .styleReference
                    ))
                }
            } catch {
                lastError = error
                break
            }
        }
        if assets.isEmpty { throw lastError ?? ImageGeneratorError.invalidImage }
        return ImageFrameSeriesResult(
            assets: assets,
            creditsRemaining: creditsRemaining,
            partialFailure: assets.count == specs.count
                ? nil
                : "Создано \(assets.count) из \(specs.count). Неудачный кадр не списан; можно повторить отдельно."
        )
    }

    private func productCardBrief(description: String) -> String {
        let exactFacts = [
            "Товар: \(productName.trimmingCharacters(in: .whitespacesAndNewlines))",
            "Описание: \(description.trimmingCharacters(in: .whitespacesAndNewlines))",
            "Цена: \(productPrice.trimmingCharacters(in: .whitespacesAndNewlines))",
            "Характеристики: \(productCharacteristics.trimmingCharacters(in: .whitespacesAndNewlines))",
            "Выгоды: \(productBenefits.trimmingCharacters(in: .whitespacesAndNewlines))",
            "Акция: \(productPromotion.trimmingCharacters(in: .whitespacesAndNewlines))",
            "Язык: \(productLanguage)",
            "Маркетплейс: \(productMarketplace)",
            "Стиль: \(productStyle)"
        ]
        return """
        Создай коммерческую карточку товара с настоящей инфографикой, а не текстом поверх случайного фото.
        \(exactFacts.joined(separator: "\n"))
        Используй только заполненные факты. Ничего не выдумывай. Весь текст должен быть крупным, контрастным и читаемым на телефоне, не перекрывать товар.
        """
    }

    private var generationCompleteBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 30, weight: .bold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.black, Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(localized("gen_ready", fallback: "Готово"))
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundColor(.white)
                Text(loc.t("gen_saved_gallery"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.58))
            }
            Spacer()
        }
        .padding(14)
        .x5ClearGlass(cornerRadius: 18, highlight: 0.15)
    }

    /// A picked photo keeps the same identity across reloads so the thumbnail
    /// strip is never rebuilt from scratch.
    private static func referenceIdentity(_ item: PhotosPickerItem) -> String {
        item.itemIdentifier ?? String(describing: item)
    }

    private func loadReferenceImages(_ items: [PhotosPickerItem]) async {
        let requested = Array(items.prefix(ImageReferenceSelection.maximumCount))
        let requestedIDs = requested.map(Self.referenceIdentity)
        let cached = Dictionary(
            referenceImages.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let plan = ImageReferenceSelection.plan(
            requested: requestedIDs,
            alreadyLoaded: referenceImages.map(\.id)
        )
        guard plan.needsWork else { return }

        if !plan.needsDecoding.isEmpty {
            isLoadingReferences = true
            photoLoadError = nil
        }
        defer { isLoadingReferences = false }

        var loaded: [ImageReferenceAsset] = []
        for (item, id) in zip(requested, requestedIDs) {
            if let existing = cached[id] {
                loaded.append(existing)
                continue
            }
            guard let asset = await loadReferenceImage(item) else { continue }
            loaded.append(asset)
        }
        referenceImages = loaded
    }

    private func loadReferenceImage(_ item: PhotosPickerItem) async -> ImageReferenceAsset? {
        // Общий загрузчик с CourseUP: Data → запасной путь через файл, ужатие
        // до 1536 px вне главного потока, HEIC/PNG → JPEG. Ошибку не глотаем.
        do {
            let prepared = try await PickedPhotoLoader.loadPrepared(from: item, maxPixelSize: 1536)
            return ImageReferenceAsset(
                id: Self.referenceIdentity(item),
                image: prepared.preview,
                reference: ImageGenerationReference(
                    mimeType: "image/jpeg",
                    base64: prepared.jpeg.base64EncodedString()
                )
            )
        } catch {
            photoLoadError = PickedPhotoLoader.errorText
            return nil
        }
    }

    private enum SinglePhotoSlot {
        case main
        case logo
    }

    /// «Фото героя» / «Основная фотография» / логотип.
    private func loadSinglePhoto(_ provider: NSItemProvider, slot: SinglePhotoSlot) async {
        photoLoadError = nil
        let pickID: Int
        switch slot {
        case .main:
            mainPhotoPickID += 1
            pickID = mainPhotoPickID
            isLoadingMainPhoto = true
        case .logo:
            logoPickID += 1
            pickID = logoPickID
            isLoadingLogo = true
        }

        var asset: ImageReferenceAsset?
        do {
            let prepared = try await PickedPhotoLoader.loadPrepared(from: provider, maxPixelSize: 1536)
            asset = ImageReferenceAsset(
                id: "picked-\(UUID().uuidString)",
                image: prepared.preview,
                reference: ImageGenerationReference(
                    mimeType: "image/jpeg",
                    base64: prepared.jpeg.base64EncodedString()
                )
            )
        } catch {
            photoLoadError = PickedPhotoLoader.errorText
        }

        // Пока грузилось, могли выбрать другое фото — старый результат не ставим.
        switch slot {
        case .main:
            guard pickID == mainPhotoPickID else { return }
            if let asset { mainPhoto = asset }
            isLoadingMainPhoto = false
        case .logo:
            guard pickID == logoPickID else { return }
            if let asset { logoImage = asset }
            isLoadingLogo = false
        }
    }

    /// A photo straight out of the camera roll is 4000 px wide and several
    /// megabytes; base64 inflates it by another third. A brief with a product
    /// photo, a logo and a few references then became a multi-megabyte upload
    /// that stalled or dropped on mobile data. Providers do not use more than
    /// ~1536 px of a reference anyway, so downscale before encoding.
    static func uploadPayload(for image: UIImage, maxDimension: CGFloat = 1536) -> Data? {
        let longestSide = max(image.size.width, image.size.height)
        guard longestSide > maxDimension, longestSide > 0 else {
            return image.jpegData(compressionQuality: 0.88)
        }
        let scale = maxDimension / longestSide
        let targetSize = CGSize(
            width: (image.size.width * scale).rounded(),
            height: (image.size.height * scale).rounded()
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let resized = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return resized.jpegData(compressionQuality: 0.88)
    }

    private func effectivePrompt(_ rawPrompt: String, hasReferences: Bool) -> String {
        let clean = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.count >= 3 { return clean }
        return hasReferences ? "Improve the provided image." : ""
    }

    private func makeReference(from image: UIImage) -> ImageGenerationReference? {
        guard let jpegData = Self.uploadPayload(for: image) else { return nil }
        return ImageGenerationReference(
            mimeType: "image/jpeg",
            base64: jpegData.base64EncodedString(),
            role: .sourceImage
        )
    }

    private var categoryTitle: String {
        localized("gen_category_\(category.id)_title", fallback: category.title)
    }

    private var categorySubtitle: String {
        localized("gen_category_\(category.id)_subtitle", fallback: category.subtitle)
    }

    private func localized(_ key: String, fallback: String) -> String {
        let value = loc.t(key)
        return value == key ? fallback : value
    }

    @discardableResult
    private func saveAssetToGallery(_ asset: GeneratedImageAsset, image: UIImage) -> Bool {
        gallery.save(
            image: image,
            prompt: asset.prompt,
            provider: asset.provider,
            category: asset.category,
            costCredits: asset.costCredits
        ) != nil
    }
}

private struct GeneratedImageAsset: Identifiable {
    let id = UUID()
    var image: UIImage
    let prompt: String
    let provider: String
    let category: String
    let sizeLabel: String
    let costCredits: Int
    let creditsRemaining: Int?
    let cloudAssetID: String?

    var aspectRatio: CGFloat {
        guard image.size.height > 0 else { return 1 }
        return image.size.width / image.size.height
    }
}

/// Reconciles the photos the picker reports against the ones already decoded.
///
/// Every pick used to rebuild the whole list: all previously chosen photos were
/// decoded and re-encoded again, so the spinner kept running, and each
/// thumbnail arrived with a brand new identity, which made SwiftUI rebuild the
/// strip and scroll it back to the start.
enum ImageReferenceSelection {
    static let maximumCount = 6

    struct Plan: Equatable {
        /// Photos that are genuinely new and have to be decoded.
        let needsDecoding: [String]
        /// False when the picker reports exactly what is already on screen, so
        /// nothing is reloaded and nothing is re-rendered.
        let needsWork: Bool
    }

    static func plan(requested: [String], alreadyLoaded: [String]) -> Plan {
        let loaded = Set(alreadyLoaded)
        let needsDecoding = requested.filter { !loaded.contains($0) }
        return Plan(
            needsDecoding: needsDecoding,
            needsWork: !needsDecoding.isEmpty || requested != alreadyLoaded
        )
    }
}

private struct ImageReferenceAsset: Identifiable {
    /// Identity comes from the picked photo, not from a fresh UUID. A new
    /// identity on every reload made SwiftUI tear the thumbnail strip down and
    /// scroll it back to the start each time another photo was added.
    let id: String
    let image: UIImage
    let reference: ImageGenerationReference

    func reference(with role: ImageGenerationReferenceRole) -> ImageGenerationReference {
        ImageGenerationReference(
            mimeType: reference.mimeType,
            base64: reference.base64,
            role: role
        )
    }
}

private struct ImageFrameSpec {
    let title: String
    let prompt: String
    let size: ImageGenerationSize
}

private struct ImageFrameSeriesResult {
    let assets: [GeneratedImageAsset]
    let creditsRemaining: Int
    let partialFailure: String?
}

private struct ProductCardType: Identifiable {
    let id: String
    let title: String
    let summary: String
    let promptGuidance: String

    static let main = ProductCardType(
        id: "main",
        title: "Главная",
        summary: "Товар, название, цена и главный оффер",
        promptGuidance: "Покажи товар крупно, добавь точное название, цену и одну главную выгоду."
    )

    static let all: [ProductCardType] = [
        main,
        .init(
            id: "benefits",
            title: "Преимущества",
            summary: "Короткие выгоды с визуальными акцентами",
            promptGuidance: "Покажи только указанные выгоды, максимум четыре коротких пункта с понятной иерархией."
        ),
        .init(
            id: "specifications",
            title: "Характеристики",
            summary: "Точные параметры без выдуманных данных",
            promptGuidance: "Собери читаемую таблицу или блок характеристик исключительно из введённых параметров."
        ),
        .init(
            id: "instructions",
            title: "Инструкция",
            summary: "Как пользоваться — по шагам",
            promptGuidance: "Покажи ясную пошаговую инструкцию. Если шаги не заданы, не выдумывай их и сделай акцент на товаре."
        ),
        .init(
            id: "contents",
            title: "Комплектация",
            summary: "Что входит в набор",
            promptGuidance: "Покажи комплектацию только по точным данным пользователя, без добавления несуществующих предметов."
        )
    ]
}

private struct ProviderLogo: View {
    let provider: ImageGenerationProvider

    var body: some View {
        Text(provider.brandLabel)
            .font(.system(size: provider == .gptImage2 ? 10 : 16, weight: .black, design: .rounded))
            .foregroundColor(provider == .gptImage2 ? .black : .white)
            .frame(width: 34, height: 34)
            .background(
                Circle()
                    .fill(provider.brandColor)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.26), lineWidth: 1)
                    )
            )
            .accessibilityLabel(provider.title)
    }
}

private struct GenerationAnimationView: View {
    @EnvironmentObject private var loc: LocalizationService

    let provider: ImageGenerationProvider
    let category: ImageGenerationCategory

    @State private var rotating = false
    @State private var pulsing = false
    @State private var scanning = false

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.10), lineWidth: 8)
                Circle()
                    .trim(from: 0.08, to: 0.72)
                    .stroke(
                        LinearGradient(colors: [Color.white, X5Style.blue],
                                       startPoint: .leading,
                                       endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .rotationEffect(.degrees(rotating ? 360 : 0))
                Image(systemName: category.icon)
                    .font(.system(size: pulsing ? 24 : 20, weight: .bold))
                    .foregroundColor(.white)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulsing)
            }
            .frame(width: 74, height: 74)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("\(provider.title) \(loc.t("gen_is_generating"))")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundColor(.white)
                    Spacer()
                    Text("Обработка")
                        .font(.system(size: 15, weight: .black))
                        .foregroundColor(Color.accentColor)
                }
                Text("\(loc.t("gen_building")) \(localizedCategoryTitle.lowercased())")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.58))
                ProgressView()
                    .tint(Color.accentColor)
                    .scaleEffect(x: 1, y: 1.3, anchor: .center)
                    .padding(.top, 3)
                generationPulseBars
                    .padding(.top, 4)
            }
            Spacer()
        }
        .padding(16)
        .x5ClearGlass(cornerRadius: 18, highlight: 0.12)
        .onAppear {
            rotating = true
            pulsing = true
            scanning = true
        }
        .animation(.linear(duration: 1.25).repeatForever(autoreverses: false), value: rotating)
    }

    private var generationPulseBars: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(0..<7, id: \.self) { index in
                Capsule()
                    .fill(
                        LinearGradient(colors: [Color.white.opacity(0.92), X5Style.blue.opacity(0.85)],
                                       startPoint: .top,
                                       endPoint: .bottom)
                    )
                    .frame(width: 8, height: scanning ? CGFloat(8 + (index % 4) * 5) : 6)
                    .opacity(scanning ? 0.95 : 0.35)
                    .animation(
                        .easeInOut(duration: 0.55)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.07),
                        value: scanning
                    )
            }
        }
        .frame(height: 28, alignment: .bottom)
    }

    private var localizedCategoryTitle: String {
        let key = "gen_category_\(category.id)_title"
        let value = loc.t(key)
        return value == key ? category.title : value
    }
}

private struct GeneratedImageViewer: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var loc: LocalizationService

    let asset: GeneratedImageAsset
    let onImageUpdated: (UIImage) -> Void
    let onSaveToGallery: (UIImage) -> Bool
    let onRegenerate: (String, UIImage) -> Void

    @State private var image: UIImage
    @State private var showingShare = false
    @State private var showingEditor = false
    @State private var regeneratePrompt = ""
    @State private var saveMessage: String?

    init(
        asset: GeneratedImageAsset,
        onImageUpdated: @escaping (UIImage) -> Void,
        onSaveToGallery: @escaping (UIImage) -> Bool,
        onRegenerate: @escaping (String, UIImage) -> Void
    ) {
        self.asset = asset
        self.onImageUpdated = onImageUpdated
        self.onSaveToGallery = onSaveToGallery
        self.onRegenerate = onRegenerate
        _image = State(initialValue: asset.image)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 18) {
                    Spacer(minLength: 0)
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .padding(.horizontal, 14)
                    metaBar
                    regenerateBar
                    Spacer(minLength: 0)
                }

                if let saveMessage {
                    Text(saveMessage)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.9))
                        .clipShape(Capsule())
                        .transition(.opacity)
                        .padding(.bottom, 30)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .navigationTitle(loc.t("gen_result"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(loc.t("btn_done")) {
                        X5Feedback.selection()
                        dismiss()
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { saveToPhotos() } label: {
                        Image(systemName: "arrow.down.circle")
                    }
                    .accessibilityLabel(loc.t("common_save"))
                    Button { saveToGallery() } label: {
                        Image(systemName: "photo.stack")
                    }
                    .accessibilityLabel(loc.t("gen_gallery"))
                    Button {
                        X5Feedback.impact()
                        showingShare = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel(loc.t("gen_action_share"))
                    Button {
                        X5Feedback.impact()
                        showingEditor = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .accessibilityLabel(loc.t("gen_action_edit"))
                    Button {
                        X5Feedback.impact()
                        showingEditor = true
                    } label: {
                        Image(systemName: "paintbrush")
                    }
                    .accessibilityLabel(loc.t("gen_action_draw"))
                }
            }
            .sheet(isPresented: $showingShare) {
                ImageActivityViewController(image: image)
            }
            .fullScreenCover(isPresented: $showingEditor) {
                ImageMarkupEditorView(source: image) { edited in
                    image = edited
                    onImageUpdated(edited)
                }
                .environmentObject(loc)
            }
        }
    }

    private var metaBar: some View {
        HStack(spacing: 10) {
            Label(asset.provider.uppercased(), systemImage: "cpu")
            Label(asset.sizeLabel, systemImage: "aspectratio")
            Label("\(asset.costCredits)", systemImage: "creditcard")
            if let credits = asset.creditsRemaining {
                Label("\(credits)", systemImage: "banknote")
            }
        }
        .font(.system(size: 12, weight: .bold))
        .foregroundColor(.white.opacity(0.62))
        .padding(.horizontal, 14)
    }

    private var regenerateBar: some View {
        VStack(spacing: 10) {
            TextField("Что изменить? Например: улучши текст на коробке", text: $regeneratePrompt, axis: .vertical)
                .lineLimit(2...4)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .padding(12)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            HStack(spacing: 10) {
                Button {
                    showingEditor = true
                } label: {
                    Label("Отметить", systemImage: "pencil.tip.crop.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    let clean = regeneratePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !clean.isEmpty else { return }
                    onRegenerate(clean, image)
                    dismiss()
                } label: {
                    Label("Перегенерировать", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(regeneratePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.regular)
        }
        .padding(12)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 14)
    }

    private func saveToPhotos() {
        X5Feedback.success()
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        withAnimation { saveMessage = loc.t("gen_saved_photos") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation { saveMessage = nil }
        }
    }

    private func saveToGallery() {
        let saved = onSaveToGallery(image)
        saved ? X5Feedback.success() : X5Feedback.error()
        withAnimation { saveMessage = saved ? loc.t("gen_saved_gallery") : loc.t("gen_save_failed") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation { saveMessage = nil }
        }
    }
}

private final class DrawingCanvasState: ObservableObject {
    let canvasView = PKCanvasView()
}

struct ImageMarkupEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var loc: LocalizationService

    let source: UIImage
    let onDone: (UIImage) -> Void

    @StateObject private var canvas = DrawingCanvasState()

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let side = max(180, min(proxy.size.width - 24, proxy.size.height - 48))
                ZStack {
                    Color.black.ignoresSafeArea()

                    ZStack {
                        Image(uiImage: source)
                            .resizable()
                            .scaledToFit()
                            .frame(width: side, height: side)

                        PencilCanvasRepresentable(canvasView: canvas.canvasView)
                            .frame(width: side, height: side)
                    }
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.16), lineWidth: 1)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(loc.t("gen_draw"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(loc.t("btn_cancel")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(loc.t("btn_done")) {
                        onDone(renderEditedImage())
                        dismiss()
                    }
                }
            }
        }
    }

    private func renderEditedImage() -> UIImage {
        let bounds = canvas.canvasView.bounds
        guard bounds.width > 1, bounds.height > 1 else { return source }

        let renderer = UIGraphicsImageRenderer(size: bounds.size)
        return renderer.image { context in
            UIColor.black.setFill()
            context.cgContext.fill(bounds)

            source.draw(in: aspectFitRect(imageSize: source.size, bounds: bounds))
            let drawing = canvas.canvasView.drawing.image(from: bounds, scale: UIScreen.main.scale)
            drawing.draw(in: bounds)
        }
    }

    private func aspectFitRect(imageSize: CGSize, bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

private struct PencilCanvasRepresentable: UIViewRepresentable {
    let canvasView: PKCanvasView

    func makeUIView(context: Context) -> PKCanvasView {
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.drawingPolicy = .anyInput
        canvasView.tool = PKInkingTool(.pen, color: .white, width: 6)
        return canvasView
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {}
}

private struct ImageActivityViewController: UIViewControllerRepresentable {
    let image: UIImage

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [image], applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

private enum ImageGeneratorError: LocalizedError {
    case invalidImage

    var errorDescription: String? {
        "Image generation returned invalid image data."
    }
}
