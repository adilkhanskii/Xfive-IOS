import Foundation
import SwiftUI

/// Storage prefix for App Store-safe home videos.
/// Only X5-owned Kling AI exports should be placed here.
let X5_HOME_VIDEO_BASE = "https://afwznqjpshybmqhlewmy.supabase.co/storage/v1/object/public/videos/home"

struct HomeBanner: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let subtitle: String
    let videoFile: String?
    let gradientStart: Color
    let gradientEnd: Color
    let toolID: String           // tool to navigate when tapped

    var videoURL: URL? {
        guard let videoFile else { return nil }
        return URL(string: "\(X5_HOME_VIDEO_BASE)/\(videoFile)")
    }
}

struct HomeTool: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String              // SF Symbol fallback
    let videoFile: String?
    let gradientStart: Color
    let gradientEnd: Color
    let tag: String?              // "AI" / "PRO" / "NEW" / "FREE"
    let tagColor: Color?

    var videoURL: URL? {
        guard let videoFile else { return nil }
        return URL(string: "\(X5_HOME_VIDEO_BASE)/\(videoFile)")
    }
}

enum ImageGenerationProvider: String, CaseIterable, Identifiable, Hashable {
    case gptImage2 = "gpt-image-2"
    case nanoBanana2 = "gemini-3.1-flash-image"
    case nanoBanana2Lite = "gemini-3.1-flash-lite-image"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gptImage2: return "GPT Image 2"
        case .nanoBanana2: return "Nano Banana 2"
        case .nanoBanana2Lite: return "Nano Banana 2 Lite"
        }
    }

    var provider: String {
        switch self {
        case .gptImage2:
            return "gpt"
        case .nanoBanana2, .nanoBanana2Lite:
            return "google"
        }
    }

    var subtitle: String {
        switch self {
        case .gptImage2: return "OpenAI · премиальная генерация"
        case .nanoBanana2: return "Google Gemini · Nano Banana 2"
        case .nanoBanana2Lite: return "Google Gemini · Nano Banana 2 Lite"
        }
    }

    var brandLabel: String {
        switch self {
        case .gptImage2: return "GPT"
        case .nanoBanana2: return "G"
        case .nanoBanana2Lite: return "G"
        }
    }

    var brandColor: Color {
        switch self {
        case .gptImage2: return Color(red: 0.76, green: 0.84, blue: 0.92)
        case .nanoBanana2: return Color(red: 0.26, green: 0.52, blue: 0.96)
        case .nanoBanana2Lite: return Color(red: 0.32, green: 0.69, blue: 0.98)
        }
    }
}

enum ImageGenerationSize: String, CaseIterable, Identifiable, Hashable {
    case square = "square"
    case portrait = "portrait"
    case landscape = "landscape"
    case vertical23 = "vertical_2_3"
    case portrait34 = "portrait_3_4"
    case portrait45 = "portrait_4_5"
    case landscape32 = "landscape_3_2"
    case landscape43 = "landscape_4_3"
    case wide = "wide"
    case square2K = "square_2k"
    case portrait2K = "portrait_2k"
    case landscape2K = "landscape_2k"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .square: return "1:1"
        case .portrait: return "9:16"
        case .landscape: return "16:9"
        case .vertical23: return "2:3"
        case .portrait34: return "3:4"
        case .portrait45: return "4:5"
        case .landscape32: return "3:2"
        case .landscape43: return "4:3"
        case .wide: return "21:9"
        case .square2K: return "1:1 2K"
        case .portrait2K: return "9:16 2K"
        case .landscape2K: return "16:9 2K"
        }
    }

    var subtitle: String {
        switch self {
        case .square: return "1024 x 1024"
        case .portrait: return "1024 x 1536"
        case .landscape: return "1536 x 1024"
        case .vertical23: return "832 x 1248"
        case .portrait34: return "864 x 1184"
        case .portrait45: return "896 x 1152"
        case .landscape32: return "1248 x 832"
        case .landscape43: return "1184 x 864"
        case .wide: return "1536 x 672"
        case .square2K: return "2048 x 2048"
        case .portrait2K: return "1536 x 2752"
        case .landscape2K: return "2752 x 1536"
        }
    }

    var openAISize: String {
        switch self {
        case .square, .square2K:
            return "1024x1024"
        case .portrait, .vertical23, .portrait34, .portrait45, .portrait2K:
            return "1024x1536"
        case .landscape, .landscape32, .landscape43, .wide, .landscape2K:
            return "1536x1024"
        }
    }

    var googleAspectRatio: String {
        switch self {
        case .square, .square2K: return "1:1"
        case .portrait, .portrait2K: return "9:16"
        case .landscape, .landscape2K: return "16:9"
        case .vertical23: return "2:3"
        case .portrait34: return "3:4"
        case .portrait45: return "4:5"
        case .landscape32: return "3:2"
        case .landscape43: return "4:3"
        case .wide: return "21:9"
        }
    }

    var googleImageSize: String? {
        switch self {
        case .square2K, .portrait2K, .landscape2K: return "2K"
        default: return nil
        }
    }

    var isGoogleOnly: Bool {
        switch self {
        case .square, .portrait, .landscape:
            return false
        case .vertical23, .portrait34, .portrait45, .landscape32, .landscape43, .wide, .square2K, .portrait2K, .landscape2K:
            return true
        }
    }

    func isSupported(by provider: ImageGenerationProvider) -> Bool {
        switch provider {
        case .gptImage2:
            return !isGoogleOnly
        case .nanoBanana2:
            return true
        case .nanoBanana2Lite:
            return googleImageSize == nil
        }
    }

    func unavailableLabel(for provider: ImageGenerationProvider) -> String {
        switch provider {
        case .gptImage2:
            return "Nano Banana"
        case .nanoBanana2, .nanoBanana2Lite:
            return "Nano Banana 2"
        }
    }
}

struct ImageGenerationCategory: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let examplePrompt: String
    let gradientStart: Color
    let gradientEnd: Color
}

struct YouTubeThumbnailMode: Identifiable, Hashable {
    let id: String
    let title: String
    let summary: String
    let icon: String
    let promptGuidance: String
    let examples: [String]
    let isRecommended: Bool

    static let all: [YouTubeThumbnailMode] = [
        .init(
            id: "entertainment",
            title: "Развлекательная",
            summary: "Эмоция, движение и яркий контраст.",
            icon: "theatermasks.fill",
            promptGuidance: "Динамичная развлекательная подача: сильная эмоция, живой сюжет, яркие контрастные цвета и крупный визуальный акцент.",
            examples: [
                "Проверил 10 вирусных лайфхаков — работают ли они на самом деле?",
                "24 часа живу только по советам подписчиков",
                "Кто последний выйдет из комнаты — заберёт приз",
                "Самый странный день моей жизни"
            ],
            isRecommended: true
        ),
        .init(
            id: "serious",
            title: "Серьёзная",
            summary: "Сдержанно, убедительно и без визуального шума.",
            icon: "building.columns.fill",
            promptGuidance: "Серьёзная авторитетная подача: чистая композиция, спокойные глубокие цвета, уверенный герой или предмет, минимум декоративного шума.",
            examples: [
                "Почему рынок жилья меняется и что делать покупателю",
                "Куда движется экономика Казахстана в 2026 году",
                "Разбор главных ошибок при запуске бизнеса",
                "Что на самом деле происходит с ценами"
            ],
            isRecommended: false
        ),
        .init(
            id: "expert",
            title: "Экспертная",
            summary: "Знания, польза и доверие к автору.",
            icon: "graduationcap.fill",
            promptGuidance: "Экспертная образовательная подача: компетентный герой, понятный предмет разговора, визуальные намёки на анализ, схему или результат.",
            examples: [
                "5 ошибок в рекламе, которые съедают бюджет",
                "Как настроить продажи без постоянных скидок",
                "Пошаговый разбор успешного запуска",
                "Как экспертно упаковать личный бренд"
            ],
            isRecommended: true
        ),
        .init(
            id: "news",
            title: "Новостная",
            summary: "Актуальность и ощущение важного события.",
            icon: "newspaper.fill",
            promptGuidance: "Новостная подача: ощущение актуального события, чёткая иерархия, редакционная композиция и сильный информационный акцент без ложной срочности.",
            examples: [
                "Главные новости недели за 10 минут",
                "Новый закон: что изменится для бизнеса",
                "Большое обновление YouTube — полный разбор",
                "Что произошло на рынке сегодня"
            ],
            isRecommended: false
        ),
        .init(
            id: "provocative",
            title: "Провокационная",
            summary: "Контраст и интрига без обмана зрителя.",
            icon: "bolt.fill",
            promptGuidance: "Провокационная, но честная подача: визуальный конфликт, неожиданный контраст и интрига без ложных обещаний, шокирующих манипуляций и вводящего в заблуждение кликбейта.",
            examples: [
                "Почему большинство советов по продвижению не работают",
                "Я перестал делать это — результаты удивили",
                "Вам лгут о быстром успехе",
                "Главная ошибка, о которой все молчат"
            ],
            isRecommended: false
        ),
        .init(
            id: "minimal",
            title: "Минималистичная",
            summary: "Один герой, короткий текст и много воздуха.",
            icon: "circle.lefthalf.filled",
            promptGuidance: "Минималистичная подача: один главный объект или человек, короткий заголовок, много свободного пространства, точный свет и премиальная типографика.",
            examples: [
                "Одна привычка изменила всё",
                "До и после: честный результат",
                "Как начать с нуля",
                "Главный урок года"
            ],
            isRecommended: false
        ),
        .init(
            id: "interview",
            title: "Интервью",
            summary: "Сильный герой, цитата и ощущение живого разговора.",
            icon: "mic.fill",
            promptGuidance: "Интервью-подача: крупный выразительный портрет гостя, студийный свет, короткая сильная цитата и визуальное ощущение честного разговора.",
            examples: [
                "Как я построил бизнес с нуля — честный разговор",
                "Что остаётся за кадром большого успеха",
                "Предприниматель отвечает на неудобные вопросы",
                "История человека, который изменил индустрию"
            ],
            isRecommended: true
        ),
        .init(
            id: "review",
            title: "Обзор",
            summary: "Продукт крупно, ясная оценка и заметная деталь.",
            icon: "star.fill",
            promptGuidance: "Обзорная подача: продукт или предмет крупным планом, наглядная ключевая особенность, честная оценка и чистая технологичная композиция.",
            examples: [
                "Честный обзор нового MacBook после месяца использования",
                "Стоит ли покупать этот смартфон в 2026 году",
                "Тестируем бюджетную камеру в реальных условиях",
                "Лучший микрофон для видео — подробный обзор"
            ],
            isRecommended: true
        ),
        .init(
            id: "comparison",
            title: "Сравнение",
            summary: "Два варианта, визуальный конфликт и понятный выбор.",
            icon: "arrow.left.arrow.right",
            promptGuidance: "Сравнительная подача: два конкурирующих объекта или подхода по разные стороны кадра, понятный контраст и визуальный вопрос выбора.",
            examples: [
                "iPhone против Android: что лучше в 2026 году",
                "Дорогая реклама против дешёвой — где результат",
                "Новичок и эксперт: чем отличается их подход",
                "Снимаем на телефон и камеру — заметна ли разница"
            ],
            isRecommended: false
        ),
        .init(
            id: "story",
            title: "История",
            summary: "Драма, поворот и эмоциональный путь героя.",
            icon: "book.closed.fill",
            promptGuidance: "Сюжетная подача: герой в эмоциональном моменте, ощущение пути или переломного события, кинематографичный свет и интригующий заголовок.",
            examples: [
                "Как я потерял всё и начал заново",
                "Один звонок полностью изменил мою жизнь",
                "Путь от первой ошибки до большого результата",
                "Почему я ушёл из стабильной работы"
            ],
            isRecommended: false
        )
    ]
}

enum YouTubeThumbnailBriefBuilder {
    static func compose(
        topic: String,
        mode: YouTubeThumbnailMode,
        hasHeroPhoto: Bool,
        referenceCount: Int
    ) -> String {
        let cleanTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts = [
            "Создай профессиональную кликабельную обложку YouTube строго в формате 16:9.",
            "Тема ролика: \(cleanTopic)",
            "Режим: \(mode.title). \(mode.promptGuidance)",
            "Самостоятельно предложи короткий читаемый заголовок на русском из 2-5 слов. Заголовок должен поддерживать тему ролика и не обещать того, чего нет в описании.",
            "Главный объект, лицо или продукт должны хорошо читаться на маленьком превью. Сохрани безопасные отступы, высокий контраст и цельную композицию. Не добавляй интерфейс YouTube, логотип YouTube, водяные знаки или мелкий текст."
        ]
        var imageIndex = 1
        if hasHeroPhoto {
            parts.append("Изображение 1 — основное фото героя. Сохрани узнаваемые черты, эмоцию и естественную внешность человека.")
            imageIndex += 1
        }
        if referenceCount > 0 {
            let range = referenceCount == 1
                ? "Изображение \(imageIndex) — референс желаемого оформления."
                : "Изображения \(imageIndex)-\(imageIndex + referenceCount - 1) — референсы желаемого оформления."
            parts.append("\(range) Возьми из них композицию, цвет и визуальную динамику, но не копируй чужие логотипы или водяные знаки.")
        }
        return parts.joined(separator: "\n")
    }
}

struct SalesAngle: Identifiable, Hashable {
    let id: String
    let title: String
    let summary: String
    let examples: [String]
    let isRecommended: Bool

    static let all: [SalesAngle] = [
        .init(
            id: "pain",
            title: "Через боль клиента",
            summary: "Покажите проблему, которую человек хочет решить.",
            examples: ["Надоело каждое утро рисовать брови?", "Устали искать клиентов?", "Замучили боли в спине?"],
            isRecommended: true
        ),
        .init(
            id: "desired_result",
            title: "Через желаемый результат",
            summary: "Покажите конечный результат, ради которого покупают товар или услугу.",
            examples: ["Просыпайтесь красивой каждый день.", "Получите первых клиентов уже через месяц.", "Дом, которым будете гордиться."],
            isRecommended: true
        ),
        .init(
            id: "benefit",
            title: "Через выгоду",
            summary: "Сразу объясните, что именно получает клиент.",
            examples: ["До конца месяца скидка 30%.", "Обучение и материалы уже включены.", "Бесплатная доставка."],
            isRecommended: true
        ),
        .init(
            id: "scarcity",
            title: "Через ограниченность",
            summary: "Покажите, что предложение ограничено по времени или количеству.",
            examples: ["Осталось всего 5 мест.", "Цена действует до конца недели.", "Только для первых 20 клиентов."],
            isRecommended: true
        ),
        .init(
            id: "expertise",
            title: "Через экспертность и доверие",
            summary: "Объясните, почему клиент может доверять именно вам.",
            examples: ["17 лет опыта.", "Более 2 000 довольных клиентов.", "Сертифицированный преподаватель."],
            isRecommended: true
        ),
        .init(
            id: "transformation",
            title: "Через трансформацию",
            summary: "Покажите понятное изменение до и после.",
            examples: ["Из офисного сотрудника в мастера с высоким доходом.", "До и после процедуры.", "До рекламы и после запуска."],
            isRecommended: true
        ),
        .init(
            id: "social_proof",
            title: "Через социальное доказательство",
            summary: "Используйте отзывы, оценки и количество клиентов.",
            examples: ["Более 1 500 клиентов.", "Нас рекомендуют знакомым.", "4,9 по отзывам."],
            isRecommended: false
        ),
        .init(
            id: "saving",
            title: "Через экономию времени или денег",
            summary: "Покажите, сколько времени или денег сэкономит клиент.",
            examples: ["Экономьте час каждое утро.", "Перестаньте переплачивать.", "Один раз сделали и забыли."],
            isRecommended: false
        ),
        .init(
            id: "curiosity",
            title: "Через любопытство",
            summary: "Дайте причину остановиться и узнать больше.",
            examples: ["Почему 9 из 10 девушек выбирают эту технику?", "Ошибка, которую совершают почти все.", "Секрет идеальных бровей."],
            isRecommended: false
        ),
        .init(
            id: "loss_aversion",
            title: "Через страх потери",
            summary: "Покажите, что человек может потерять, если отложит решение.",
            examples: ["После окончания акции цена станет выше.", "Не откладывайте, пока есть свободные даты.", "Чем раньше начнете, тем быстрее получите результат."],
            isRecommended: false
        )
    ]
}

/// One layout recipe. Two generations of the same product must not come back
/// as the same picture, so every request picks a different recipe: without
/// this the model keeps re-drawing its favourite composition and the creative
/// looks unchanged even after the seller switches the angle.
struct SalesCreativeVariation: Hashable {
    let id: String
    let directive: String

    static let all: [SalesCreativeVariation] = [
        .init(
            id: "hero_bottom_text",
            directive: "Композиция: крупный герой-визуал сверху, заголовок и оффер плотным блоком внизу."
        ),
        .init(
            id: "left_text_right_product",
            directive: "Композиция: текстовый блок слева, товар справа, между ними воздух и чёткая вертикальная сетка."
        ),
        .init(
            id: "diagonal_accent",
            directive: "Композиция: диагональная динамика, акцентная плашка под заголовком, товар смещён от центра."
        ),
        .init(
            id: "top_headline_frame",
            directive: "Композиция: заголовок крупно сверху во всю ширину, товар в рамке по центру, условия мелко снизу."
        ),
        .init(
            id: "split_contrast",
            directive: "Композиция: кадр поделён на два контрастных поля, в одном визуал, в другом текст."
        ),
        .init(
            id: "closeup_overlay",
            directive: "Композиция: макро-кадр товара на весь фон, текст поверх на затемнении, минимум элементов."
        )
    ]

    static func pick(excluding previousID: String?) -> SalesCreativeVariation {
        let pool = all.filter { $0.id != previousID }
        return pool.randomElement() ?? all[0]
    }
}

enum SalesCreativeBriefBuilder {
    static func compose(
        description: String,
        angle: SalesAngle,
        hasMainPhoto: Bool,
        hasLogo: Bool,
        referenceCount: Int,
        variation: SalesCreativeVariation? = nil
    ) -> String {
        // The backend caps the whole prompt, so a very long description must
        // never be able to push the angle, the composition rules or the roles
        // of the uploaded images out of the brief.
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDescription = trimmedDescription.count > 900
            ? String(trimmedDescription.prefix(900))
            : trimmedDescription
        let toneExamples = angle.examples.prefix(3).joined(separator: " | ")
        var parts = [
            "Создай профессиональный рекламный баннер или карточку товара на русском языке.",
            // The angle leads the brief: when it was one line in the middle the
            // model ignored it and every angle produced the same headline.
            "Главное требование — угол продаж: \(angle.title). \(angle.summary)",
            "Заголовок обязан быть написан именно в этой логике. Интонация примерно такая: \(toneExamples)",
            "Не пиши универсальный заголовок, который подошёл бы к любому другому углу продаж. Смени угол — меняется и заголовок, и акцент композиции.",
            "Товар или услуга: \(cleanDescription)",
            "Самостоятельно напиши короткий продающий заголовок, понятный оффер и только нужный текст. Не копируй примеры дословно, если они не подходят к описанию.",
            "Сделай цельную профессиональную композицию. Текст должен быть частью дизайна, а не случайной надписью поверх изображения."
        ]

        if let variation {
            parts.append(variation.directive)
        }

        var imageRoles: [String] = []
        var imageIndex = 1
        if hasMainPhoto {
            imageRoles.append("изображение \(imageIndex) является основной фотографией товара или услуги")
            imageIndex += 1
        }
        if hasLogo {
            imageRoles.append("изображение \(imageIndex) является логотипом, сохрани его написание и размести аккуратно")
            imageIndex += 1
        }
        if referenceCount > 0 {
            let range = referenceCount == 1
                ? "изображение \(imageIndex) является референсом стиля"
                : "изображения \(imageIndex)-\(imageIndex + referenceCount - 1) являются референсами стиля"
            imageRoles.append(range)
        }
        if !imageRoles.isEmpty {
            parts.append("Роли загруженных материалов: \(imageRoles.joined(separator: "; ")).")
        }

        return parts.joined(separator: "\n")
    }
}

enum ImageGenerationCatalog {
    static let creditCost: Int = 60

    static let custom = ImageGenerationCategory(
        id: "custom",
        title: "Image generation",
        subtitle: "Flexible prompt generation",
        icon: "sparkles",
        examplePrompt: "Премиальная реклама кофейни для Instagram, темная студийная сцена, синие стеклянные детали",
        gradientStart: X5Style.blue.opacity(0.34),
        gradientEnd: .black
    )

    static let categories: [ImageGenerationCategory] = [
        .init(
            id: "square_1_1",
            title: "1:1 Creative",
            subtitle: "Square ad creative",
            icon: "square.fill",
            examplePrompt: "Квадратный рекламный креатив 1:1 для бизнеса в Казахстане, понятный оффер, премиальный черный стиль с ярким акцентом",
            gradientStart: Color(red: 0.43, green: 0.95, blue: 0.12).opacity(0.36),
            gradientEnd: .black
        ),
        .init(
            id: "logo",
            title: "Logo",
            subtitle: "Brand mark",
            icon: "seal.fill",
            examplePrompt: "Минималистичный премиальный логотип для кофейного бренда, серебро и циан, черный фон",
            gradientStart: Color(red: 0.62, green: 0.70, blue: 0.82).opacity(0.42),
            gradientEnd: .black
        ),
        .init(
            id: "story",
            title: "Story",
            subtitle: "Vertical creative",
            icon: "rectangle.portrait.fill",
            examplePrompt: "Сторис для запуска премиальной косметики, сияющий продукт, чистое место под текст",
            gradientStart: X5Style.blue.opacity(0.40),
            gradientEnd: .black
        ),
        .init(
            id: "target_ad",
            title: "Target Ad",
            subtitle: "Ads for launch",
            icon: "scope",
            examplePrompt: "Продающий креатив для таргета в Instagram и TikTok, четкая выгода продукта, премиальная мобильная композиция",
            gradientStart: Color(red: 0.43, green: 0.95, blue: 0.12).opacity(0.38),
            gradientEnd: .black
        ),
        .init(
            id: "youtube_cover",
            title: "YouTube Cover",
            subtitle: "Clickable thumbnail",
            icon: "play.rectangle.fill",
            examplePrompt: "Кликабельная обложка YouTube с крупным читаемым заголовком на русском, фокус на лице или продукте, высокий контраст",
            gradientStart: X5Style.blue.opacity(0.34),
            gradientEnd: .black
        ),
        .init(
            id: "post",
            title: "Post",
            subtitle: "Square feed post",
            icon: "square.grid.2x2.fill",
            examplePrompt: "Квадратный пост Instagram для открытия ресторана, кинематографичная сервировка, премиальный свет",
            gradientStart: Color(red: 0.39, green: 0.40, blue: 0.94).opacity(0.42),
            gradientEnd: .black
        ),
        .init(
            id: "insta_pack",
            title: "Insta Pack",
            subtitle: "Post + story mood",
            icon: "square.stack.3d.up.fill",
            examplePrompt: "Единый визуальный пакет Instagram для fashion-бренда: обложка поста, настроение сторис, фирменная текстура",
            gradientStart: X5Style.blueSoft.opacity(0.42),
            gradientEnd: .black
        ),
        .init(
            id: "product",
            title: "Product",
            subtitle: "Ad-ready shot",
            icon: "shippingbox.fill",
            examplePrompt: "Премиальная реклама беспроводных наушников, черный акриловый стол, циановый контровой свет",
            gradientStart: Color(red: 0.23, green: 0.51, blue: 0.96).opacity(0.42),
            gradientEnd: .black
        ),
        .init(
            id: "product_cards",
            title: "Product Cards",
            subtitle: "Marketplace cards",
            icon: "rectangle.grid.2x2.fill",
            examplePrompt: "Премиальная карточка товара для маркетплейса: beauty-продукт, чистый блок цены, короткие выгоды, черно-белый стиль с серебром и цианом",
            gradientStart: Color(red: 0.56, green: 0.72, blue: 0.92).opacity(0.38),
            gradientEnd: .black
        ),
        .init(
            id: "packaging",
            title: "Packaging",
            subtitle: "Box and label",
            icon: "cube.box.fill",
            examplePrompt: "Концепт люксовой упаковки для крафтового шоколада, матовая черная коробка, серебряная этикетка, студийный рендер",
            gradientStart: Color(red: 0.52, green: 0.57, blue: 0.68).opacity(0.42),
            gradientEnd: .black
        ),
        .init(
            id: "moodboard",
            title: "Moodboard",
            subtitle: "Единое визуальное направление",
            icon: "rectangle.3.group.fill",
            examplePrompt: "Мудборд премиального бренда: палитра, свет, материалы, типографика и примеры композиции",
            gradientStart: Color.purple.opacity(0.40),
            gradientEnd: .black
        ),
        .init(
            id: "edit_image",
            title: "Редактор изображения",
            subtitle: "Точное изменение загруженного фото",
            icon: "wand.and.stars.inverse",
            examplePrompt: "Уберите лишний объект, улучшите свет и сохраните лицо, товар и остальные детали без изменений",
            gradientStart: X5Style.blue.opacity(0.42),
            gradientEnd: .black
        ),
        .init(
            id: "content_pack",
            title: "Контент-пак",
            subtitle: "Пост, сторис и реклама в одном стиле",
            icon: "square.stack.3d.up.fill",
            examplePrompt: "Запуск нового продукта: единый оффер, фирменные цвета и согласованный стиль для трёх форматов",
            gradientStart: Color(red: 0.36, green: 0.66, blue: 0.98).opacity(0.42),
            gradientEnd: .black
        ),
        .init(
            id: "ai_character",
            title: "Персонаж AI",
            subtitle: "Синтетический образ для инфлюенсера",
            icon: "person.crop.square.filled.and.at.rectangle",
            examplePrompt: "Оригинальный синтетический персонаж, реалистичный портрет, нейтральный фон, естественная анатомия",
            gradientStart: Color(red: 0.58, green: 0.30, blue: 0.92).opacity(0.42),
            gradientEnd: .black
        )
    ]
}

enum HomeContent {
    static let banners: [HomeBanner] = [
        .init(title: "AI Influencer", subtitle: "Create your virtual influencer",
              videoFile: nil,
              gradientStart: Color(red: 0.1, green: 0.04, blue: 0.16),
              gradientEnd: Color(red: 0.06, green: 0.20, blue: 0.38),
              toolID: "ai_influencer"),
        .init(title: "Create Video", subtitle: "AI video generation — Kling 3.0",
              videoFile: nil,
              gradientStart: Color(red: 0.06, green: 0.05, blue: 0.16),
              gradientEnd: Color(red: 0.09, green: 0.13, blue: 0.24),
              toolID: "video_gen"),
        .init(title: "Face Swap", subtitle: "Swap faces in photos & videos",
              videoFile: nil,
              gradientStart: Color(red: 0.10, green: 0.10, blue: 0.18),
              gradientEnd: Color(red: 0.06, green: 0.20, blue: 0.38),
              toolID: "edit_image"),
        .init(title: "Transitions", subtitle: "Cinematic scene transitions",
              videoFile: nil,
              gradientStart: Color(red: 0.06, green: 0.05, blue: 0.16),
              gradientEnd: Color(red: 0.14, green: 0.14, blue: 0.24),
              toolID: "vfx_library"),
        .init(title: "Lipsync Studio", subtitle: "Lip sync with audio",
              videoFile: nil,
              gradientStart: Color(red: 0.10, green: 0.10, blue: 0.18),
              gradientEnd: Color(red: 0.18, green: 0.10, blue: 0.30),
              toolID: "lipsync")
    ]

    /// 14 tools matching web `toolCards` array.
    static let tools: [HomeTool] = [
        .init(id: "photo", title: "Create Image", subtitle: "AI generation",
              icon: "photo", videoFile: nil,
              gradientStart: .indigo, gradientEnd: .black,
              tag: "AI", tagColor: Color(red: 0.39, green: 0.40, blue: 0.94)),

        .init(id: "video_gen", title: "Kling Video", subtitle: "Text/Image to video",
              icon: "video", videoFile: nil,
              gradientStart: X5Style.blue.opacity(0.42), gradientEnd: .black,
              tag: "PRO", tagColor: Color.white.opacity(0.88)),

        .init(id: "outfit_swap", title: "Outfit Swap", subtitle: "Swap outfits",
              icon: "tshirt", videoFile: nil,
              gradientStart: .purple, gradientEnd: .black,
              tag: "NEW", tagColor: Color(red: 0.51, green: 0.55, blue: 0.97)),

        .init(id: "lipsync", title: "Lip Sync", subtitle: "Talking video",
              icon: "mouth", videoFile: nil,
              gradientStart: X5Style.blue.opacity(0.36), gradientEnd: .black,
              tag: "NEW", tagColor: X5Style.blueSoft),

        .init(id: "design", title: "Design", subtitle: "Banners & creatives",
              icon: "paintbrush", videoFile: nil,
              gradientStart: Color(red: 0.39, green: 0.40, blue: 0.94).opacity(0.4),
              gradientEnd: .black,
              tag: "AI", tagColor: X5Style.blue),

        .init(id: "voice_tts", title: "Voice TTS", subtitle: "Text to speech",
              icon: "speaker.wave.2.fill", videoFile: nil,
              gradientStart: .pink, gradientEnd: .black,
              tag: "AI", tagColor: Color(red: 0.66, green: 0.55, blue: 0.98)),

        .init(id: "whatsapp_bot", title: "WhatsApp Bot", subtitle: "Auto-responder",
              icon: "bubble.left.and.bubble.right.fill", videoFile: nil,
              gradientStart: X5Style.blueSoft.opacity(0.34),
              gradientEnd: .black,
              tag: "NEW", tagColor: X5Style.blueSoft),

        .init(id: "instagram", title: "Instagram AI", subtitle: "Content plan",
              icon: "camera.fill", videoFile: nil,
              gradientStart: X5Style.blue.opacity(0.28),
              gradientEnd: .black,
              tag: "AI", tagColor: X5Style.blue),

        .init(id: "video_creative", title: "Motion Control", subtitle: "Camera moves",
              icon: "film", videoFile: nil,
              gradientStart: .purple, gradientEnd: .black,
              tag: "AI", tagColor: Color(red: 0.66, green: 0.55, blue: 0.98)),

        .init(id: "lawyer", title: "Lawyer AI", subtitle: "Contracts & docs",
              icon: "doc.text.fill", videoFile: nil,
              gradientStart: X5Style.blueSoft.opacity(0.32),
              gradientEnd: .black,
              tag: "AI", tagColor: X5Style.blueSoft),

        .init(id: "academy", title: "Academy", subtitle: "Courses & training",
              icon: "graduationcap.fill", videoFile: nil,
              gradientStart: X5Style.blue.opacity(0.22),
              gradientEnd: .black,
              tag: nil, tagColor: nil),

        .init(id: "crm", title: "CRM", subtitle: "Client management",
              icon: "person.3.fill", videoFile: nil,
              gradientStart: Color(red: 0.23, green: 0.51, blue: 0.96).opacity(0.4),
              gradientEnd: .black,
              tag: "NEW", tagColor: Color(red: 0.23, green: 0.51, blue: 0.96)),

        .init(id: "analytics", title: "Analytics", subtitle: "KPI & statistics",
              icon: "chart.bar.fill", videoFile: nil,
              gradientStart: X5Style.blue.opacity(0.26),
              gradientEnd: .black,
              tag: "AI", tagColor: X5Style.blue),

        .init(id: "captions", title: "Captions", subtitle: "Caption templates (live)",
              icon: "text.alignleft", videoFile: nil,
              gradientStart: X5Style.blue.opacity(0.30),
              gradientEnd: .black,
              tag: "LIVE", tagColor: X5Style.blue),

        .init(id: "startup_chat", title: "Startup Chat", subtitle: "Business AI assistant",
              icon: "sparkles.rectangle.stack.fill", videoFile: nil,
              gradientStart: X5Style.backgroundBlue.opacity(0.44),
              gradientEnd: .black,
              tag: "SOON", tagColor: X5Style.blue)
    ]
}
