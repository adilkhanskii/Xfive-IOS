import SwiftUI

/// Telegram-style cache management screen.
/// Lists each cache category with its on-disk size, lets the user multi-select,
/// then deletes only the selected categories.
struct CacheView: View {
    @EnvironmentObject private var loc: LocalizationService
    @Environment(\.dismiss) private var dismiss

    @State private var sizes: [ImageCache.Category: Int64] = [:]
    @State private var selected: Set<ImageCache.Category> = []
    @State private var clearing = false

    private let cache = ImageCache.shared

    var body: some View {
        List {
            Section {
                HStack {
                    Text(loc.t("cache_total"))
                        .foregroundColor(.white)
                    Spacer()
                    Text(formatBytes(totalSize))
                        .foregroundColor(.white.opacity(0.7))
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                }
            }

            Section {
                ForEach(ImageCache.Category.allCases) { category in
                    Button {
                        toggle(category)
                    } label: {
                        row(for: category)
                    }
                    .disabled((sizes[category] ?? 0) == 0)
                }
            } header: {
                Text(loc.t("cache_pick"))
            } footer: {
                Text(loc.t("cache_pick_hint"))
            }

            Section {
                Button(role: .destructive) {
                    Task { await clearSelected() }
                } label: {
                    HStack {
                        Spacer()
                        if clearing {
                            ProgressView().tint(.red)
                        } else {
                            Text(selected.isEmpty
                                 ? loc.t("cache_clear_all")
                                 : "\(loc.t("cache_clear_selected")) · \(formatBytes(selectedSize))")
                                .fontWeight(.semibold)
                        }
                        Spacer()
                    }
                }
                .disabled(clearing || totalSize == 0)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(red: 0.04, green: 0.05, blue: 0.10))
        .navigationTitle(loc.t("cache_title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await refresh() }
    }

    // MARK: - Components

    @ViewBuilder
    private func row(for category: ImageCache.Category) -> some View {
        let size = sizes[category] ?? 0
        let isOn = selected.contains(category)
        HStack(spacing: 12) {
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isOn ? .accentColor : .white.opacity(0.3))
                .font(.system(size: 20))
            VStack(alignment: .leading, spacing: 2) {
                Text(loc.t(category.localizationKey))
                    .foregroundColor(.white)
                if size == 0 {
                    Text(loc.t("cache_empty"))
                        .font(.caption).foregroundColor(.white.opacity(0.4))
                }
            }
            Spacer()
            Text(formatBytes(size))
                .font(.system(size: 14, weight: .medium).monospacedDigit())
                .foregroundColor(size == 0 ? .white.opacity(0.3) : .white.opacity(0.6))
        }
    }

    // MARK: - State

    private var totalSize: Int64 {
        sizes.values.reduce(0, +)
    }

    private var selectedSize: Int64 {
        selected.reduce(0) { $0 + (sizes[$1] ?? 0) }
    }

    private func toggle(_ category: ImageCache.Category) {
        if selected.contains(category) { selected.remove(category) }
        else { selected.insert(category) }
    }

    private func refresh() async {
        var next: [ImageCache.Category: Int64] = [:]
        for c in ImageCache.Category.allCases {
            next[c] = await cache.sizeOnDisk(category: c)
        }
        sizes = next
    }

    private func clearSelected() async {
        clearing = true
        defer { clearing = false }

        if selected.isEmpty {
            await cache.clearAll()
        } else {
            for c in selected { await cache.clear(category: c) }
        }

        selected.removeAll()
        await refresh()
    }

    // MARK: - Format

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes <= 0 { return "0 KB" }
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}
