import Foundation
import SwiftUI

struct BrandProfileData: Codable, Equatable {
    var name: String
    var niche: String
    var audience: String
    var vocabulary: String   // comma-separated brand words

    static let empty = BrandProfileData(name: "", niche: "", audience: "", vocabulary: "")
}

@MainActor
final class BrandProfile: ObservableObject {
    @Published var data: BrandProfileData = .empty {
        didSet { save() }
    }

    private let key = "x5.brand.profile.v1"

    init() { load() }

    var isFilled: Bool {
        !(data.name + data.niche + data.audience + data.vocabulary)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func load() {
        if let raw = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(BrandProfileData.self, from: raw) {
            data = decoded
        }
    }

    private func save() {
        if let raw = try? JSONEncoder().encode(data) {
            UserDefaults.standard.set(raw, forKey: key)
        }
    }
}
