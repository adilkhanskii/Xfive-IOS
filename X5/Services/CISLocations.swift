import Foundation

struct CISCity: Decodable, Identifiable, Hashable {
    let country: String
    let city: String
    let ascii: String
    let population: Int
    let regionCode: String?
    let region: String?
    let regionAscii: String?
    var id: String { "\(country):\(city)" }
}

struct CISRegion: Identifiable, Hashable {
    let code: String
    let name: String
    let cityCount: Int
    var id: String { code }
}

enum CISLocations {
    static let countries: [(code: String, name: String)] = [
        ("KZ", "Казахстан"), ("RU", "Россия"), ("UZ", "Узбекистан"),
        ("KG", "Кыргызстан"), ("TJ", "Таджикистан"), ("TM", "Туркменистан"),
        ("AZ", "Азербайджан"), ("AM", "Армения"), ("BY", "Беларусь"),
        ("MD", "Молдова"), ("GE", "Грузия"), ("UA", "Украина")
    ]

    static let cities: [CISCity] = {
        guard let url = Bundle.main.url(forResource: "cis-cities", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let rows = try? JSONDecoder().decode([CISCity].self, from: data)
        else { return [] }
        return rows
    }()

    static func countryName(for code: String) -> String? {
        countries.first(where: { $0.code == code })?.name
    }

    /// Строка для профиля: «Город, Страна». Пустые части пропускаем;
    /// оба пустые — nil (строку в профиле тогда не показываем).
    static func profileLocationText(city: String?, countryCode: String?) -> String? {
        let cleanCity = (city ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let code = (countryCode ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let country = code.isEmpty ? "" : (countryName(for: code) ?? code)
        let parts = [cleanCity, country].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    static func search(country: String, query: String, limit: Int = 12) -> [CISCity] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        guard !country.isEmpty else { return [] }
        return cities.lazy.filter { row in
            guard row.country == country else { return false }
            if needle.isEmpty { return true }
            return row.city.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).contains(needle)
                || row.ascii.lowercased().contains(needle.lowercased())
        }.prefix(limit).map { $0 }
    }

    static func popularCities(country: String, limit: Int = 8) -> [CISCity] {
        guard !country.isEmpty else { return [] }
        return cities.lazy
            .filter { $0.country == country }
            .prefix(limit)
            .map { $0 }
    }

    static func regions(country: String) -> [CISRegion] {
        guard !country.isEmpty else { return [] }
        let grouped = Dictionary(grouping: cities.filter { $0.country == country }) { $0.regionCode ?? "" }
        return grouped.compactMap { code, rows in
            guard !code.isEmpty, let row = rows.first else { return nil }
            return CISRegion(
                code: code,
                name: localizedRegionName(country: country, code: code, fallback: row.region ?? row.regionAscii ?? code),
                cityCount: rows.count
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func cities(country: String, regionCode: String) -> [CISCity] {
        cities.filter { $0.country == country && $0.regionCode == regionCode }
    }

    static func localizedRegionName(country: String, code: String, fallback: String) -> String {
        guard country == "KZ" else { return fallback }
        return kazakhstanRegionNames[code] ?? fallback
    }

    private static let kazakhstanRegionNames: [String: String] = [
        "01": "Алматинская область",
        "02": "Алматы",
        "03": "Акмолинская область",
        "04": "Актюбинская область",
        "05": "Астана",
        "06": "Атырауская область",
        "07": "Западно-Казахстанская область",
        "08": "Байконур",
        "09": "Мангистауская область",
        "10": "Туркестанская область",
        "11": "Павлодарская область",
        "12": "Карагандинская область",
        "13": "Костанайская область",
        "14": "Кызылординская область",
        "15": "Восточно-Казахстанская область",
        "16": "Северо-Казахстанская область",
        "17": "Жамбылская область",
        "12510143": "Абайская область",
        "12510144": "Область Жетысу",
        "12510145": "Область Улытау",
        "1537272": "Шымкент"
    ]
}
