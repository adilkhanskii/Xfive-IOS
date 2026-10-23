import Foundation
import UIKit
import CryptoKit

/// NSCache is documented as thread-safe but has not adopted Sendable. Keep
/// that single audited escape hatch inside a tiny wrapper instead of exposing
/// a non-Sendable Foundation object across the actor boundary.
private final class ImageMemoryCache: @unchecked Sendable {
    private let storage: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    func object(forKey key: NSString) -> UIImage? {
        storage.object(forKey: key)
    }

    func setObject(_ image: UIImage, forKey key: NSString, cost: Int) {
        storage.setObject(image, forKey: key, cost: cost)
    }

    func removeAllObjects() {
        storage.removeAllObjects()
    }
}

/// Persistent on-disk image cache split by category so the user can review
/// what's stored and selectively wipe parts of it (Telegram-style).
///
/// AsyncImage hits URLCache.shared but URLCache evicts aggressively and gives
/// no per-bucket size info. We need both: stable caching across app launches
/// and a UI that says "Avatars: 4.2 MB, Course covers: 18.1 MB".
///
/// `actor` isolation is intentional:
/// - `inFlight` deduplicates concurrent fetches of the same URL
/// - disk I/O is dispatched via `Task.detached` so it never blocks the actor
/// - `NSCache` itself is thread-safe and used directly
actor ImageCache {
    static let shared = ImageCache()

    enum Category: String, CaseIterable, Identifiable {
        case avatars
        case courseCovers = "course-covers"
        case portfolio
        case chatMedia = "chat-media"
        case other

        var id: String { rawValue }

        /// Bucket name as it appears in Supabase storage URLs:
        /// `/storage/v1/object/public/<bucket>/...`
        var bucketHint: String? {
            switch self {
            case .avatars: return "avatars"
            case .courseCovers: return "course-covers"
            case .portfolio: return "portfolio"
            case .chatMedia: return "chat-media"
            case .other: return nil
            }
        }
    }

    /// In-memory layer to avoid re-reading from disk during scroll.
    /// Cost is set per insertion (bytesPerRow * height) so totalCostLimit actually bounds memory.
    ///
    /// `nonisolated` so views can peek synchronously on `init` and seed
    /// their `@State` with a hot image before the first render — avoids the
    /// "blank placeholder for one frame" flicker when leaving and returning
    /// to a chat. NSCache is documented thread-safe; only this property and
    /// the static `keyFor(_:)` are nonisolated.
    nonisolated private let memory = ImageMemoryCache()

    /// Coalesces concurrent requests for the same URL into a single network task.
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    private let fm = FileManager.default
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024,
                                   diskCapacity: 64 * 1024 * 1024,
                                   directory: nil)
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public

    /// Synchronous peek into the in-memory layer. Returns nil if the URL
    /// hasn't been resolved yet OR was evicted by NSCache pressure. Use from
    /// view initialisers to seed `@State` and skip the async hop on warm
    /// re-entry — never replaces `image(for:)` since this never fetches.
    nonisolated func peekMemory(for url: URL) -> UIImage? {
        let key = Self.keyFor(url: url)
        return memory.object(forKey: key as NSString)
    }

    /// Synchronous disk peek for cold app starts. This avoids a visible
    /// placeholder flash for images already cached on disk before the async
    /// actor hop resolves.
    nonisolated func peekDisk(for url: URL) -> UIImage? {
        let key = Self.keyFor(url: url)
        if let cached = memory.object(forKey: key as NSString) { return cached }

        let category = Self.categorize(url: url)
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let path = caches
            .appendingPathComponent("x5-images", isDirectory: true)
            .appendingPathComponent(category.rawValue, isDirectory: true)
            .appendingPathComponent(key)
        guard let data = try? Data(contentsOf: path), let image = UIImage(data: data) else {
            return nil
        }
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 1024 * 1024
        memory.setObject(image, forKey: key as NSString, cost: cost)
        return image
    }

    /// Returns image for URL, downloading if needed. Categorisation is automatic.
    /// Concurrent calls for the same URL share a single fetch (no duplicate downloads).
    func image(for url: URL) async -> UIImage? {
        let key = Self.keyFor(url: url)
        if let cached = memory.object(forKey: key as NSString) { return cached }
        if let task = inFlight[url] { return await task.value }

        let task = Task<UIImage?, Never> { [weak self] in
            await self?.resolveImage(url: url, key: key) ?? nil
        }
        inFlight[url] = task
        let result = await task.value
        inFlight[url] = nil
        return result
    }

    /// Total disk size for a single category in bytes. Off-main.
    func sizeOnDisk(category: Category) -> Int64 {
        let dir = directory(for: category)
        return Self.directorySize(dir, fm: fm)
    }

    /// Removes all cached files for a single category and clears the in-memory layer.
    func clear(category: Category) {
        let dir = directory(for: category)
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        memory.removeAllObjects()
    }

    /// Removes everything across all categories and resets the URLSession cache.
    func clearAll() {
        for c in Category.allCases { clear(category: c) }
        session.configuration.urlCache?.removeAllCachedResponses()
    }

    /// Called on sign-out: drops private (chat) media and the in-memory layer
    /// so a different user signing in on this device can't see leftovers.
    func clearForSignOut() {
        clear(category: .chatMedia)
        memory.removeAllObjects()
        for (_, task) in inFlight { task.cancel() }
        inFlight.removeAll()
    }

    // MARK: - Internal

    /// Disk-load → fall back to network. Disk I/O is detached so the actor
    /// stays responsive while bytes are read.
    private func resolveImage(url: URL, key: String) async -> UIImage? {
        let category = Self.categorize(url: url)
        let path = filePath(category: category, key: key)

        if let img = await Task.detached(
            priority: .utility,
            operation: { () -> UIImage? in
                guard let data = try? Data(contentsOf: path) else { return nil }
                return UIImage(data: data)
            }
        ).value {
            store(img, key: key)
            return img
        }

        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return nil
            }
            guard let img = UIImage(data: data) else { return nil }
            store(img, key: key)
            // Persist on background; ignore failure (next request will refetch).
            Task.detached(priority: .utility) { [data, path] in
                try? data.write(to: path, options: .atomic)
            }
            return img
        } catch {
            return nil
        }
    }

    /// Insert into NSCache with proper byte cost so totalCostLimit actually bounds memory.
    private func store(_ img: UIImage, key: String) {
        let cost = img.cgImage.map { $0.bytesPerRow * $0.height } ?? 1024 * 1024
        memory.setObject(img, forKey: key as NSString, cost: cost)
    }

    private func directory(for category: Category) -> URL {
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches
            .appendingPathComponent("x5-images", isDirectory: true)
            .appendingPathComponent(category.rawValue, isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func filePath(category: Category, key: String) -> URL {
        directory(for: category).appendingPathComponent(key)
    }

    private static func keyFor(url: URL) -> String {
        // Signed chat-media tokens rotate. Hashing the full URL would create a
        // duplicate disk entry after every refresh; the protected object path
        // is stable and the chat-media cache is wiped on sign-out.
        let cacheIdentity: String
        if url.path.contains("/storage/v1/object/sign/chat-media/") {
            cacheIdentity = "\(url.scheme ?? "https")://\(url.host ?? "")\(url.path)"
        } else {
            cacheIdentity = url.absoluteString
        }
        let digest = SHA256.hash(data: Data(cacheIdentity.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func categorize(url: URL) -> Category {
        let path = url.path
        for c in Category.allCases {
            if let bucket = c.bucketHint,
               (path.contains("/storage/v1/object/public/\(bucket)/")
                || path.contains("/storage/v1/object/authenticated/\(bucket)/")
                || path.contains("/storage/v1/object/sign/\(bucket)/")) {
                return c
            }
        }
        return .other
    }

    private static func directorySize(_ dir: URL, fm: FileManager) -> Int64 {
        guard let enumerator = fm.enumerator(at: dir,
                                             includingPropertiesForKeys: [.fileSizeKey],
                                             options: [.skipsHiddenFiles])
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }
}

extension ImageCache.Category {
    /// Human-readable label key for localization. View resolves via `loc.t(...)`.
    var localizationKey: String {
        switch self {
        case .avatars: return "cache_cat_avatars"
        case .courseCovers: return "cache_cat_courses"
        case .portfolio: return "cache_cat_portfolio"
        case .chatMedia: return "cache_cat_chat"
        case .other: return "cache_cat_other"
        }
    }
}
