import Foundation
import UIKit

struct GeneratedGalleryItem: Codable, Identifiable, Equatable {
    let id: String
    let prompt: String
    let provider: String
    let category: String
    let costCredits: Int
    let createdAt: Date
    let fileName: String
}

@MainActor
final class GeneratedGalleryStore: ObservableObject {
    @Published private(set) var items: [GeneratedGalleryItem] = []
    @Published private(set) var error: String?

    private let fm = FileManager.default
    private let manifestName = "manifest.json"

    init() {
        load()
    }

    func load() {
        do {
            try ensureDirectory()
            let url = manifestURL
            guard fm.fileExists(atPath: url.path) else {
                items = []
                return
            }
            let data = try Data(contentsOf: url)
            items = try JSONDecoder.gallery.decode([GeneratedGalleryItem].self, from: data)
                .sorted { $0.createdAt > $1.createdAt }
        } catch {
            self.error = error.localizedDescription
            items = []
        }
    }

    @discardableResult
    func save(image: UIImage, prompt: String, provider: String, category: String, costCredits: Int) -> GeneratedGalleryItem? {
        do {
            try ensureDirectory()
            let id = UUID().uuidString
            let fileName = "\(id).png"
            let item = GeneratedGalleryItem(
                id: id,
                prompt: prompt,
                provider: provider,
                category: category,
                costCredits: costCredits,
                createdAt: Date(),
                fileName: fileName
            )
            guard let data = image.pngData() else { return nil }
            try data.write(to: imageURL(for: item), options: .atomic)
            items.insert(item, at: 0)
            try persist()
            return item
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func delete(_ item: GeneratedGalleryItem) {
        do {
            try? fm.removeItem(at: imageURL(for: item))
            items.removeAll { $0.id == item.id }
            try persist()
        } catch {
            self.error = error.localizedDescription
        }
    }

    @discardableResult
    func replaceImage(for item: GeneratedGalleryItem, image: UIImage) -> Bool {
        do {
            guard let data = image.pngData() else { return false }
            try data.write(to: imageURL(for: item), options: .atomic)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func image(for item: GeneratedGalleryItem) -> UIImage? {
        guard let data = try? Data(contentsOf: imageURL(for: item)) else { return nil }
        return UIImage(data: data)
    }

    private var directoryURL: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("x5-generated-gallery", isDirectory: true)
    }

    private var manifestURL: URL {
        directoryURL.appendingPathComponent(manifestName)
    }

    private func imageURL(for item: GeneratedGalleryItem) -> URL {
        directoryURL.appendingPathComponent(item.fileName)
    }

    private func ensureDirectory() throws {
        if !fm.fileExists(atPath: directoryURL.path) {
            try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
    }

    private func persist() throws {
        let data = try JSONEncoder.gallery.encode(items)
        try data.write(to: manifestURL, options: .atomic)
    }
}

private extension JSONEncoder {
    static var gallery: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var gallery: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
