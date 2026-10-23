import SwiftUI
import UIKit

struct GeneratedGalleryView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var loc: LocalizationService
    @StateObject private var store = GeneratedGalleryStore()
    @State private var preview: GeneratedGalleryPreview?
    @State private var showingCloudGallery = false

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                X5Background()

                if store.items.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(store.items) { item in
                                Button {
                                    if let image = store.image(for: item) {
                                        preview = GeneratedGalleryPreview(item: item, image: image)
                                    }
                                } label: {
                                    galleryCell(item)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle(loc.t("gen_gallery"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingCloudGallery = true
                    } label: {
                        Label("Облако", systemImage: "icloud.and.arrow.down")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(loc.t("btn_done")) { dismiss() }
                }
            }
            .sheet(isPresented: $showingCloudGallery) {
                AICloudGalleryView()
            }
            .fullScreenCover(item: $preview) { preview in
                GeneratedGalleryPreviewView(preview: preview, onImageUpdated: { image in
                    store.replaceImage(for: preview.item, image: image)
                }, onDelete: {
                    store.delete(preview.item)
                    self.preview = nil
                })
                .environmentObject(loc)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.stack")
                .font(.system(size: 44, weight: .light))
                .foregroundColor(.white.opacity(0.45))
            Text(loc.t("gen_gallery_empty_title"))
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
            Text(loc.t("gen_gallery_empty_subtitle"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
        }
    }

    private func galleryCell(_ item: GeneratedGalleryItem) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let image = store.image(for: item) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.white.opacity(0.07)
                Image(systemName: "photo")
                    .foregroundColor(.white.opacity(0.4))
            }

            LinearGradient(colors: [.clear, .black.opacity(0.68)],
                           startPoint: .center,
                           endPoint: .bottom)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.category.uppercased())
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundColor(.white.opacity(0.64))
                Text(item.prompt)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)
            }
            .padding(10)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct GeneratedGalleryPreview: Identifiable {
    let item: GeneratedGalleryItem
    let image: UIImage
    var id: String { item.id }
}

private struct GeneratedGalleryPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var loc: LocalizationService

    let preview: GeneratedGalleryPreview
    let onImageUpdated: (UIImage) -> Void
    let onDelete: () -> Void

    @State private var image: UIImage
    @State private var showingShare = false
    @State private var showingEditor = false
    @State private var saveMessage: String?

    init(
        preview: GeneratedGalleryPreview,
        onImageUpdated: @escaping (UIImage) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.preview = preview
        self.onImageUpdated = onImageUpdated
        self.onDelete = onDelete
        _image = State(initialValue: preview.image)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 16) {
                    Spacer(minLength: 0)
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(.horizontal, 14)
                    Text(preview.item.prompt)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.62))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                    Spacer(minLength: 0)
                }

                if let saveMessage {
                    Text(saveMessage)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.9))
                        .clipShape(Capsule())
                        .padding(.bottom, 30)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .navigationTitle(loc.t("gen_gallery"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(loc.t("btn_done")) { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { saveToPhotos() } label: {
                        Image(systemName: "arrow.down.circle")
                    }
                    .accessibilityLabel(loc.t("common_save"))
                    Button { showingShare = true } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel(loc.t("gen_action_share"))
                    Button { showingEditor = true } label: {
                        Image(systemName: "pencil")
                    }
                    .accessibilityLabel(loc.t("gen_action_edit"))
                    Button { showingEditor = true } label: {
                        Image(systemName: "paintbrush")
                    }
                    .accessibilityLabel(loc.t("gen_action_draw"))
                    Button(role: .destructive) { onDelete() } label: {
                        Image(systemName: "trash")
                    }
                }
            }
            .sheet(isPresented: $showingShare) {
                GeneratedGalleryActivityView(image: image)
            }
            .fullScreenCover(isPresented: $showingEditor) {
                ImageMarkupEditorView(source: image) { edited in
                    image = edited
                    onImageUpdated(edited)
                    withAnimation { saveMessage = loc.t("gen_saved_gallery") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                        withAnimation { saveMessage = nil }
                    }
                }
                .environmentObject(loc)
            }
        }
    }

    private func saveToPhotos() {
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        withAnimation { saveMessage = loc.t("gen_saved_photos") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation { saveMessage = nil }
        }
    }
}

private struct GeneratedGalleryActivityView: UIViewControllerRepresentable {
    let image: UIImage

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [image], applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
