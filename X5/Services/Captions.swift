import Foundation

enum Tone: String, CaseIterable {
    case friendly
    case professional
    case funny

    var label: String {
        switch self {
        case .friendly: return "Friendly"
        case .professional: return "Pro"
        case .funny: return "Funny"
        }
    }
}

enum Platform: String, CaseIterable, Codable {
    case instagram
    case twitter
    case linkedin
    case tiktok

    var label: String {
        switch self {
        case .instagram: return "Instagram"
        case .twitter:   return "X / Twitter"
        case .linkedin:  return "LinkedIn"
        case .tiktok:    return "TikTok"
        }
    }

    /// Recommended length budget (per Apple-friendly rule of thumb).
    var recommendedLength: Int {
        switch self {
        case .instagram: return 220
        case .twitter:   return 240
        case .linkedin:  return 320
        case .tiktok:    return 180
        }
    }

    /// Platform-specific tail (hashtags / emoji style) appended to fit recommended length.
    var tail: String {
        switch self {
        case .instagram: return "\n\n#marketing #branding #smm"
        case .twitter:   return ""
        case .linkedin:  return "\n\n#marketing #strategy"
        case .tiktok:    return "\n\n#fyp #marketing #brand"
        }
    }
}

enum CaptionGenerator {
    static let templates: [Tone: [String]] = [
        .friendly: [
            "Hey friends! Just thinking about {topic} today and had to share. What do you think?",
            "Real talk about {topic} — would love to hear your take in the comments.",
            "Sometimes the best ideas come from {topic}. Tag someone who needs this today.",
            "A small reminder: {topic} matters more than we admit.",
            "Quick story about {topic} — and why it changes things for me.",
            "If {topic} resonates with you, drop a heart in the comments.",
            "There is something beautiful about {topic}. Keep going."
        ],
        .professional: [
            "Three lessons from working with {topic} that you can apply this week.",
            "A data-driven look at {topic} and what it means for your strategy.",
            "Why {topic} should be on every marketer's radar in 2026.",
            "Breaking down {topic}: a framework refined over years of practice.",
            "The hidden cost of ignoring {topic} — and how to turn it into an advantage.",
            "Most teams underestimate {topic}. Here is why that is changing.",
            "A short thread on {topic}, written for operators who need results."
        ],
        .funny: [
            "Me trying to explain {topic} to my mom for the fifth time this month.",
            "POV: you opened the app for a quick scroll and now you are deep into {topic}.",
            "{topic} but make it relatable. You are welcome.",
            "Plot twist: {topic} is actually personal development. Coping mechanism unlocked.",
            "Daily reminder that {topic} is a mood, a vibe, and possibly a personality trait.",
            "Nobody: literally nobody: me at 2am thinking about {topic}.",
            "I came here to talk about {topic} and frankly I am not okay."
        ]
    ]

    static func generate(
        topic: String,
        tone: Tone,
        platform: Platform = .instagram,
        brand: BrandProfileData = .empty
    ) -> [String] {
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let bank = templates[tone] else { return [] }
        let shuffled = bank.shuffled().prefix(5)
        let brandTokens = brand.vocabulary
            .split(whereSeparator: { ",;|".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return shuffled.enumerated().map { (idx, template) in
            var body = template.replacingOccurrences(of: "{topic}", with: trimmed)
            // Sprinkle one brand word per generation when available
            if !brandTokens.isEmpty {
                let token = brandTokens[idx % brandTokens.count]
                body = body.replacingOccurrences(of: " today", with: " today as we focus on \(token)")
            }
            // Audience aside on professional tone
            if tone == .professional, !brand.audience.isEmpty {
                body += " (Built for \(brand.audience).)"
            }
            let withTail = body + platform.tail
            return clamp(withTail, to: platform.recommendedLength)
        }
    }

    private static func clamp(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let cutoff = text.index(text.startIndex, offsetBy: max(0, limit - 1))
        return String(text[..<cutoff]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

// MARK: - History

struct CaptionHistoryItem: Codable, Identifiable {
    var id: String = UUID().uuidString
    let topic: String
    let tone: String
    let platform: String
    let captions: [String]
    let date: Date
}

@MainActor
final class CaptionHistory: ObservableObject {
    @Published private(set) var items: [CaptionHistoryItem] = []

    private let key = "x5.caption.history.v1"
    private let limit = 20

    init() { load() }

    func add(topic: String, tone: Tone, platform: Platform, captions: [String]) {
        let item = CaptionHistoryItem(
            topic: topic,
            tone: tone.label,
            platform: platform.label,
            captions: captions,
            date: Date()
        )
        items.insert(item, at: 0)
        if items.count > limit { items = Array(items.prefix(limit)) }
        save()
    }

    func clear() { items = []; save() }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([CaptionHistoryItem].self, from: data)
        else { return }
        items = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
