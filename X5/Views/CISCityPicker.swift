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

// MARK: - Несколько стран / городов / категорий (задания Hub, Адильхан 30.10)

struct MultiSelectOption: Identifiable, Hashable {
    let id: String
    let title: String
    var icon: String? = nil
}

/// Строка формы → лист с галочками. allLabel != nil: пустой выбор = «Все …»;
/// allLabel == nil: минимум один пункт (категории).
struct MultiSelectPickerButton: View {
    @EnvironmentObject private var loc: LocalizationService
    let title: String
    let icon: String
    let options: [MultiSelectOption]
    @Binding var selection: [String]
    let summary: String
    var allLabel: String? = nil

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            MultiSelectRowLabel(title: title, icon: icon, summary: summary, enabled: true)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $isPresented) {
            MultiSelectSheet(title: title, options: options, selection: $selection, allLabel: allLabel)
                .environmentObject(loc)
        }
    }
}

private struct MultiSelectRowLabel: View {
    let title: String
    let icon: String
    let summary: String
    let enabled: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
            Text(title)
                .foregroundColor(enabled ? .white : .white.opacity(0.35))
            Spacer(minLength: 6)
            Text(summary)
                .foregroundColor(.white.opacity(enabled ? 0.62 : 0.35))
                .lineLimit(1)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white.opacity(0.42))
        }
        .contentShape(Rectangle())
    }
}

private struct MultiSelectRow: View {
    let title: String
    let icon: String?
    let checked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let icon {
                    Image(systemName: icon)
                        .foregroundColor(.accentColor)
                        .frame(width: 22)
                }
                Text(title)
                    .foregroundColor(.primary)
                Spacer()
                if checked {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
    }
}

/// Выбор не закрывает лист: отметил сколько нужно → «Готово».
private func toggleItem(_ id: String, in selection: inout [String], keepAtLeastOne: Bool) {
    if let index = selection.firstIndex(of: id) {
        if keepAtLeastOne && selection.count == 1 { return }
        selection.remove(at: index)
    } else {
        selection.append(id)
    }
}

private struct MultiSelectSheet: View {
    @EnvironmentObject private var loc: LocalizationService
    @Environment(\.dismiss) private var dismiss
    let title: String
    let options: [MultiSelectOption]
    @Binding var selection: [String]
    let allLabel: String?

    var body: some View {
        NavigationStack {
            List {
                if let allLabel {
                    Section {
                        // «Все» снимает остальные; выбор пункта снимает «Все» (пустой массив = все).
                        MultiSelectRow(title: allLabel, icon: "globe.europe.africa.fill", checked: selection.isEmpty) {
                            selection = []
                        }
                    }
                }
                Section {
                    ForEach(options) { option in
                        MultiSelectRow(title: option.title, icon: option.icon, checked: selection.contains(option.id)) {
                            toggleItem(option.id, in: &selection, keepAtLeastOne: allLabel == nil)
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(loc.t("common_done")) { dismiss() }.bold()
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// Несколько городов из выбранных стран. Нет стран («Все страны») → неактивна.
struct CISMultiCityPickerButton: View {
    @EnvironmentObject private var loc: LocalizationService
    @Binding var cities: [String]
    let countryCodes: [String]

    @State private var isPresented = false

    var body: some View {
        Button {
            guard !countryCodes.isEmpty else { return }
            isPresented = true
        } label: {
            MultiSelectRowLabel(
                title: loc.t("task_cities"),
                icon: "building.2.fill",
                summary: CISLocations.compactLabel(cities, allLabel: loc.t("location_all_cities")),
                enabled: !countryCodes.isEmpty
            )
        }
        .buttonStyle(.plain)
        .disabled(countryCodes.isEmpty)
        .sheet(isPresented: $isPresented) {
            CISMultiCityPickerView(cities: $cities, countryCodes: countryCodes)
                .environmentObject(loc)
        }
    }
}

private struct CISMultiCityPickerView: View {
    @EnvironmentObject private var loc: LocalizationService
    @Environment(\.dismiss) private var dismiss
    @Binding var cities: [String]
    let countryCodes: [String]

    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section(loc.t("location_search_results")) {
                        ForEach(searchResults) { item in
                            cityRow(item.city)
                        }
                    }
                } else {
                    Section {
                        MultiSelectRow(title: loc.t("location_all_cities"), icon: "globe.europe.africa.fill", checked: cities.isEmpty) {
                            cities = []
                        }
                        // Уже выбранные сверху — снять галочку, не ища город заново.
                        ForEach(cities, id: \.self) { name in
                            cityRow(name)
                        }
                    }
                    ForEach(countryCodes, id: \.self) { code in
                        Section(CISLocations.countryName(for: code) ?? code) {
                            ForEach(CISLocations.popularCities(country: code)) { item in
                                cityRow(item.city, icon: "mappin.and.ellipse")
                            }
                            ForEach(CISLocations.regions(country: code)) { region in
                                NavigationLink {
                                    CISMultiRegionCitiesView(cities: $cities, countryCode: code, region: region)
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
            }
            .navigationTitle(loc.t("task_cities"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: loc.t("location_search_city"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(loc.t("common_done")) { dismiss() }.bold()
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var searchResults: [CISCity] {
        countryCodes.flatMap { CISLocations.search(country: $0, query: query, limit: 100) }
    }

    private func cityRow(_ name: String, icon: String = "mappin") -> some View {
        MultiSelectRow(title: name, icon: icon, checked: cities.contains(name)) {
            toggleItem(name, in: &cities, keepAtLeastOne: false)
        }
    }
}

private struct CISMultiRegionCitiesView: View {
    @Binding var cities: [String]
    let countryCode: String
    let region: CISRegion

    var body: some View {
        List(CISLocations.cities(country: countryCode, regionCode: region.code)) { item in
            MultiSelectRow(title: item.city, icon: nil, checked: cities.contains(item.city)) {
                toggleItem(item.city, in: &cities, keepAtLeastOne: false)
            }
        }
        .navigationTitle(region.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Страны задания: «Все страны» + несколько стран.
struct TaskCountriesPickerButton: View {
    @EnvironmentObject private var loc: LocalizationService
    @Binding var countryCodes: [String]

    var body: some View {
        MultiSelectPickerButton(
            title: loc.t("onb_country"),
            icon: "globe",
            options: CISLocations.countries.map { MultiSelectOption(id: $0.code, title: $0.name) },
            selection: $countryCodes,
            summary: CISLocations.compactLabel(
                CISLocations.countryNames(countryCodes),
                allLabel: loc.t("hub_all_countries")
            ),
            allLabel: loc.t("hub_all_countries")
        )
    }
}

/// Категории задания: несколько, минимум одна.
struct TaskCategoriesPickerButton: View {
    @EnvironmentObject private var loc: LocalizationService
    @Binding var categories: [String]

    var body: some View {
        MultiSelectPickerButton(
            title: loc.t("task_categories"),
            icon: "square.grid.2x2.fill",
            options: HubCategories.all.map {
                MultiSelectOption(
                    id: $0.id,
                    title: HubCategories.label(for: $0.id, language: loc.current),
                    icon: HubCategories.symbol(for: $0.id)
                )
            },
            selection: $categories,
            summary: HubCategories.label(for: categories, language: loc.current)
        )
    }
}
