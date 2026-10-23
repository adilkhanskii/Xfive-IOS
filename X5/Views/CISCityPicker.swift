import SwiftUI

struct CISCityPickerButton: View {
    @EnvironmentObject private var loc: LocalizationService
    @Binding var city: String
    let countryCode: String
    var allowsAllCities = false
    var compact = false

    @State private var isPresented = false

    var body: some View {
        Button {
            guard !countryCode.isEmpty else { return }
            isPresented = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "building.2.fill")
                    .foregroundColor(.accentColor)
                Text(label)
                    .font(.system(size: compact ? 13 : 16, weight: .semibold))
                    .foregroundColor(countryCode.isEmpty ? .white.opacity(0.35) : .white)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white.opacity(0.42))
            }
            .padding(.horizontal, compact ? 12 : 4)
            .padding(.vertical, compact ? 8 : 2)
            .background(compact ? Color.white.opacity(0.10) : Color.clear)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(countryCode.isEmpty)
        .sheet(isPresented: $isPresented) {
            CISCityPickerView(
                city: $city,
                countryCode: countryCode,
                allowsAllCities: allowsAllCities
            )
            .environmentObject(loc)
        }
    }

    private var label: String {
        if city.isEmpty {
            return allowsAllCities ? loc.t("location_all_cities") : loc.t("location_choose_city")
        }
        return city
    }
}

private struct CISCityPickerView: View {
    @EnvironmentObject private var loc: LocalizationService
    @Environment(\.dismiss) private var dismiss
    @Binding var city: String
    let countryCode: String
    let allowsAllCities: Bool

    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section(loc.t("location_search_results")) {
                        ForEach(CISLocations.search(country: countryCode, query: query, limit: 100)) { item in
                            cityRow(item.city)
                        }
                    }
                } else {
                    if allowsAllCities {
                        Section {
                            cityRow(loc.t("location_all_cities"), value: "", icon: "globe.europe.africa.fill")
                        }
                    }

                    Section(loc.t("location_popular_cities")) {
                        ForEach(CISLocations.popularCities(country: countryCode)) { item in
                            cityRow(item.city, icon: "mappin.and.ellipse")
                        }
                    }

                    Section(loc.t("location_regions")) {
                        ForEach(CISLocations.regions(country: countryCode)) { region in
                            NavigationLink {
                                CISRegionCitiesView(city: $city, countryCode: countryCode, region: region) {
                                    dismiss()
                                }
                                .environmentObject(loc)
                            } label: {
                                HStack {
                                    Text(region.name)
                                    Spacer()
                                    Text("\(region.cityCount)")
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(CISLocations.countryName(for: countryCode) ?? loc.t("location_choose_city"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: loc.t("location_search_city"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc.t("btn_cancel")) { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func cityRow(_ title: String, value: String? = nil, icon: String = "mappin") -> some View {
        Button {
            city = value ?? title
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundColor(.accentColor)
                    .frame(width: 22)
                Text(title)
                    .foregroundColor(.primary)
                Spacer()
                if city == (value ?? title) {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                }
            }
        }
    }
}

private struct CISRegionCitiesView: View {
    @EnvironmentObject private var loc: LocalizationService
    @Binding var city: String
    let countryCode: String
    let region: CISRegion
    let onSelected: () -> Void

    var body: some View {
        List(CISLocations.cities(country: countryCode, regionCode: region.code)) { item in
            Button {
                city = item.city
                onSelected()
            } label: {
                HStack {
                    Text(item.city)
                        .foregroundColor(.primary)
                    Spacer()
                    if city == item.city {
                        Image(systemName: "checkmark")
                            .foregroundColor(.accentColor)
                    }
                }
            }
        }
        .navigationTitle(region.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
