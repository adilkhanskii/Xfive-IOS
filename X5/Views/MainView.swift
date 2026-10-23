import SwiftUI

struct MainView: View {
    @EnvironmentObject private var auth: Auth
    @EnvironmentObject private var history: CaptionHistory
    @EnvironmentObject private var brand: BrandProfile
    @EnvironmentObject private var loc: LocalizationService

    @State private var topic: String = ""
    @State private var tone: Tone = .friendly
    @State private var platform: Platform = .instagram
    @State private var results: [String] = []
    @State private var showingProfile = false
    @State private var showingHistory = false
    @State private var showingBrand = false
    @FocusState private var topicFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sectionLabel("Topic")
                    TextField(
                        "e.g. opening a coffee shop",
                        text: $topic,
                        axis: .vertical
                    )
                    .focused($topicFocused)
                    .padding(14)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(14)
                    .frame(minHeight: 64, alignment: .top)
                    .lineLimit(2...4)

                    sectionLabel("Tone")
                    HStack(spacing: 10) {
                        ForEach(Tone.allCases, id: \.self) { option in
                            ToneChip(option: option, selected: tone == option) {
                                tone = option
                            }
                        }
                    }

                    sectionLabel("Platform")
                    Picker("", selection: $platform) {
                        ForEach(Platform.allCases, id: \.self) { p in
                            Text(p.label).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text("\(loc.t("main_target_length")): \(platform.recommendedLength)")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.45))
                        .padding(.top, -6)

                    Button(action: generate) {
                        Text(loc.t("main_generate"))
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(canGenerate ? Color.accentColor : Color.gray.opacity(0.3))
                            .cornerRadius(14)
                    }
                    .disabled(!canGenerate)
                    .padding(.top, 4)

                    if !results.isEmpty {
                        Divider().background(Color.white.opacity(0.08)).padding(.vertical, 8)
                        sectionLabel("Results")
                        VStack(spacing: 12) {
                            ForEach(Array(results.enumerated()), id: \.offset) { _, text in
                                ResultCard(text: text)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 32)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Xfive marketing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 14) {
                        Button { showingHistory = true } label: {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 19))
                                .foregroundColor(.white)
                        }
                        .accessibilityLabel("History")

                        Button { showingBrand = true } label: {
                            Image(systemName: brand.isFilled ? "sparkles" : "sparkles")
                                .font(.system(size: 19))
                                .foregroundColor(brand.isFilled ? .accentColor : .white.opacity(0.85))
                        }
                        .accessibilityLabel("Brand voice")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingProfile = true } label: {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 22))
                            .foregroundColor(.white)
                    }
                    .accessibilityLabel("Profile")
                }
            }
            .sheet(isPresented: $showingProfile) { ProfileView() }
            .sheet(isPresented: $showingHistory) { HistoryView() }
            .sheet(isPresented: $showingBrand) { BrandProfileView() }
        }
        .background { X5Background() }
    }

    private var canGenerate: Bool {
        !topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func generate() {
        topicFocused = false
        results = CaptionGenerator.generate(topic: topic, tone: tone, platform: platform, brand: brand.data)
        if !results.isEmpty {
            history.add(topic: topic, tone: tone, platform: platform, captions: results)
        }
    }

    @ViewBuilder
    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.2)
            .foregroundColor(.white.opacity(0.55))
    }
}

private struct ToneChip: View {
    let option: Tone
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(option.label)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(selected ? .accentColor : .white.opacity(0.85))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    Capsule().fill(
                        selected ? Color.accentColor.opacity(0.18) : Color.white.opacity(0.06)
                    )
                )
                .overlay(
                    Capsule().stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct ResultCard: View {
    let text: String
    @State private var copied = false
    @State private var sharing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(text)
                .font(.system(size: 15))
                .foregroundColor(.white)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Text("\(text.count) chars · \(hashtagCount(in: text)) tags")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
                Spacer()
                Button { sharing = true } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)

                Button(action: copy) {
                    Text(copied ? "Copied" : "Copy")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(copied ? .accentColor : .white.opacity(0.85))
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.05))
        .cornerRadius(14)
        .sheet(isPresented: $sharing) {
            ActivityViewController(items: [text])
        }
    }

    private func copy() {
        UIPasteboard.general.string = text
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

    private func hashtagCount(in text: String) -> Int {
        text.split(separator: " ").filter { $0.hasPrefix("#") }.count
    }
}

private struct ActivityViewController: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
