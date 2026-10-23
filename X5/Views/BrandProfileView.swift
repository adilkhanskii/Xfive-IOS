import SwiftUI

struct BrandProfileView: View {
    @EnvironmentObject private var brand: BrandProfile
    @EnvironmentObject private var loc: LocalizationService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(loc.t("brand_name_field"), text: $brand.data.name)
                    TextField(loc.t("brand_niche_field"), text: $brand.data.niche)
                    TextField(loc.t("brand_audience_field"), text: $brand.data.audience)
                    TextField(loc.t("brand_words_field"), text: $brand.data.vocabulary, axis: .vertical)
                        .lineLimit(2...4)
                } header: {
                    Text(loc.t("brand_voice_title"))
                } footer: {
                    Text(loc.t("brand_voice_sub"))
                }

                Section {
                    Button(loc.t("brand_reset"), role: .destructive) {
                        brand.data = .empty
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(red: 0.04, green: 0.05, blue: 0.10))
            .navigationTitle(loc.t("brand_voice_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(loc.t("common_done")) { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
