import SwiftUI

struct AIPresetsView: View {
    @EnvironmentObject private var auth: Auth

    @State private var presets: [AIStudioPreset] = []
    @State private var name = ""
    @State private var toolID = "image_generation"
    @State private var note = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let service = AIStudioService()
    private let tools: [(String, String)] = [
        ("image_generation", "Изображения"),
        ("product_cards", "Карточки товара"),
        ("youtube_cover", "Обложки YouTube"),
        ("content_pack", "Контент-пак"),
        ("voice", "Озвучка"),
        ("video", "Видео"),
        ("cinema", "Cinema Studio"),
        ("vfx", "VFX")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                VStack(alignment: .leading, spacing: 9) {
                    Image(systemName: "bookmark.square.fill")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                    Text("Сохранённые Presets")
                        .font(.system(size: 28, weight: .black))
                        .foregroundStyle(.white)
                    Text("Сохраняйте удачные настройки и краткие инструкции, чтобы повторять стиль в следующих генерациях.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.58))
                }
                .padding(17)
                .x5ClearGlass(cornerRadius: 22, highlight: 0.11)

                VStack(alignment: .leading, spacing: 12) {
                    Text("НОВЫЙ PRESET")
                        .font(.system(size: 10, weight: .black)).tracking(1.2)
                        .foregroundStyle(.white.opacity(0.46))
                    TextField("Название", text: $name)
                        .presetField()
                    Picker("Инструмент", selection: $toolID) {
                        ForEach(tools, id: \.0) { option in
                            Text(option.1).tag(option.0)
                        }
                    }
                    .tint(Color.accentColor)
                    TextField("Стиль, формат или заметка", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                        .presetField()
                    Button { save() } label: {
                        HStack {
                            if isSaving { ProgressView().tint(.black) }
                            Text(isSaving ? "Сохраняем…" : "Сохранить")
                                .font(.headline)
                        }
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .background(canSave ? Color.accentColor : Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSave)
                }
                .padding(16)
                .x5ClearGlass(cornerRadius: 20, highlight: 0.08)

                if isLoading {
                    HStack { Spacer(); ProgressView().tint(Color.accentColor); Spacer() }
                } else if presets.isEmpty {
                    Text("Сохранённых шаблонов пока нет.")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.52))
                        .frame(maxWidth: .infinity).padding(20)
                } else {
                    ForEach(presets) { preset in
                        HStack(spacing: 12) {
                            Image(systemName: "bookmark.fill")
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 40, height: 40)
                                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(preset.name).font(.headline).foregroundStyle(.white)
                                Text(toolTitle(preset.toolID))
                                    .font(.caption.bold()).foregroundStyle(.white.opacity(0.5))
                                if let note = preset.settings["note"], !note.isEmpty {
                                    Text(note).font(.caption).foregroundStyle(.white.opacity(0.62)).lineLimit(2)
                                }
                            }
                            Spacer()
                            Button(role: .destructive) { remove(preset) } label: {
                                Image(systemName: "trash")
                            }
                        }
                        .padding(14)
                        .x5ClearGlass(cornerRadius: 18, highlight: 0.07)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.subheadline.bold()).foregroundStyle(.white)
                        .padding(13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .padding(18)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background { X5Background() }
        .navigationTitle("Presets")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await load() }
    }

    private var canSave: Bool {
        !isSaving && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func toolTitle(_ id: String) -> String {
        tools.first(where: { $0.0 == id })?.1 ?? id
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        guard let token = await auth.freshAccessToken() else { return }
        do { presets = try await service.presets(accessToken: token) }
        catch { errorMessage = error.localizedDescription }
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        errorMessage = nil
        Task { @MainActor in
            defer { isSaving = false }
            guard let token = await auth.freshAccessToken() else { return }
            do {
                let saved = try await service.savePreset(
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    toolID: toolID,
                    settings: ["note": note],
                    accessToken: token
                )
                presets.removeAll { $0.id == saved.id || $0.name == saved.name }
                presets.insert(saved, at: 0)
                name = ""
                note = ""
                X5Feedback.success()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func remove(_ preset: AIStudioPreset) {
        Task { @MainActor in
            guard let token = await auth.freshAccessToken() else { return }
            do {
                try await service.deletePreset(id: preset.id, accessToken: token)
                presets.removeAll { $0.id == preset.id }
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

private extension View {
    func presetField() -> some View {
        self
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(12)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 13))
    }
}
