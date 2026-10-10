import Foundation
import UIKit
import XCTest
@testable import X5

/// Адильхан 10.10 20:11: «поменял на другую обложку — не поменялось».
/// Проверяем весь путь смены обложки видео без телефона:
/// выбранное фото → склейка «обложка + кадры» → новый файл в Storage →
/// PATCH thumbnail_url → в списке новый URL (кэш картинки по старому URL не мешает).
@MainActor
final class PortfolioCoverChangeTests: XCTestCase {
    private let oldCanonical = "https://example.supabase.co/storage/v1/object/public/portfolio/user-1/thumbnails/100-old-cover.jpg"

    override func tearDown() {
        CoverChangeURLProtocol.handler = nil
        super.tearDown()
    }

    func testCoverChangeUploadsNewFileAndPointsItemAtIt() async throws {
        let recorder = CoverChangeRequestRecorder()
        var patchedThumbnail: String?
        CoverChangeURLProtocol.handler = { [oldCanonical = self.oldCanonical] request in
            recorder.record(request)
            let path = request.url?.path ?? ""
            switch (request.httpMethod ?? "GET", path) {
            case ("GET", "/rest/v1/portfolio_items"):
                return Self.json(request, """
                [{"id":"item-1","user_id":"user-1","type":"video",
                  "media_url":"https://example.supabase.co/storage/v1/object/public/portfolio/user-1/v.mp4",
                  "thumbnail_url":"\(oldCanonical)","moderation_status":"approved","moderation_revision":17}]
                """)
            case ("GET", "/rest/v1/profiles"):
                return Self.json(request, #"[{"id":"user-1","name":"Owner","avatar":null,"nickname":"owner"}]"#)
            case ("POST", _) where path.hasPrefix("/storage/v1/object/portfolio/user-1/thumbnails/"):
                // Новый файл, не перезапись старого: иначе картинка по старому URL осталась бы в кэше.
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-upsert"), "false")
                XCTAssertTrue(path.hasSuffix("-cover.jpg"))
                return Self.json(request, #"{"Key":"ok"}"#)
            case ("PATCH", "/rest/v1/portfolio_items"):
                let body = try XCTUnwrap(request.httpBody)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                patchedThumbnail = json["thumbnail_url"] as? String
                return Self.json(request, """
                [{"id":"item-1","user_id":"user-1","type":"video",
                  "media_url":"https://example.supabase.co/storage/v1/object/public/portfolio/user-1/v.mp4",
                  "thumbnail_url":"\(patchedThumbnail ?? "")","moderation_status":"pending","moderation_revision":18}]
                """)
            case (_, _) where path.hasPrefix("/storage/v1/object/sign/portfolio/"):
                let objectPath = String(path.dropFirst("/storage/v1/object/sign/portfolio/".count))
                return Self.json(request, #"{"signedURL":"/object/sign/portfolio/\#(objectPath)?token=t"}"#)
            default:
                // moderate-portfolio и прочее: пусть упадёт — сервис должен пережить.
                return Self.json(request, "{}", status: 500)
            }
        }

        let service = makeService()
        await service.load(userId: "user-1", accessToken: "token")
        let before = try XCTUnwrap(service.items.first)
        XCTAssertTrue(before.hasVideoCover)

        let updated = await service.updateDetails(
            itemId: "item-1",
            title: "target",
            description: "target",
            newVideoThumbnail: Data([0xFF, 0xD8, 0xFF, 0xD9]),
            ownerId: "user-1",
            accessToken: "token"
        )

        let item = try XCTUnwrap(updated)
        let newCanonical = try XCTUnwrap(patchedThumbnail)
        XCTAssertNotEqual(newCanonical, oldCanonical, "Новая обложка — новый путь файла")
        XCTAssertTrue(newCanonical.hasSuffix("-cover.jpg"))
        XCTAssertEqual(item.thumbnailUrl, newCanonical)
        XCTAssertTrue(item.hasVideoCover)
        XCTAssertEqual(service.items.first?.thumbnailUrl, newCanonical, "Плитка в сетке берёт новый URL")
        XCTAssertNotEqual(service.items.first?.displayThumbnailUrl, before.displayThumbnailUrl)
        XCTAssertEqual(
            recorder.requests.filter { $0.httpMethod == "POST" && $0.url?.path.contains("/thumbnails/") == true }.count,
            1
        )
    }

    func testRecomposePutsNewCoverOnTopAndKeepsVideoFrames() throws {
        let frames = Self.solid(.blue, size: CGSize(width: 1200, height: 600))
        let firstData = try XCTUnwrap(PortfolioVideoCover.compose(
            cover: Self.solid(.red, size: CGSize(width: 300, height: 400)),
            frameSheet: frames
        ))
        let recomposed = try XCTUnwrap(PortfolioVideoCover.recompose(
            cover: Self.solid(.green, size: CGSize(width: 900, height: 900)),
            currentThumbnail: firstData,
            currentHasCover: true
        ))
        let image = try XCTUnwrap(UIImage(data: recomposed)?.cgImage)
        XCTAssertEqual(image.width, 1200)
        XCTAssertEqual(image.height, 1600 + 600, "Кадры видео не теряются и не дублируются")
        XCTAssertEqual(Self.dominant(image, x: 600, y: 800), .green, "Сверху — новая обложка")
        XCTAssertEqual(Self.dominant(image, x: 600, y: 1900), .blue, "Снизу — кадры видео")
    }

    func testCoverPickLoadsPickedPhotoAndBlocksSaveWhileLoading() async throws {
        let pick = PortfolioCoverPick()
        let provider = NSItemProvider(object: Self.solid(.green, size: CGSize(width: 800, height: 1000)))
        pick.load(provider)
        XCTAssertTrue(pick.loading, "Пока фото грузится, «Сохранить» выключено")
        for _ in 0..<100 where pick.loading {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(pick.loading)
        XCTAssertNil(pick.errorText)
        XCTAssertNotNil(pick.cover, "Выбранное фото стало новой обложкой")
    }

    // MARK: - Helpers

    private enum Channel { case red, green, blue }

    private static func solid(_ color: UIColor, size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private static func dominant(_ image: CGImage, x: Int, y: Int) -> Channel? {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        let (r, g, b) = (pixel[0], pixel[1], pixel[2])
        if r > 150, g < 100, b < 100 { return .red }
        if g > 150, r < 100, b < 100 { return .green }
        if b > 150, r < 100, g < 100 { return .blue }
        return nil
    }

    private func makeService() -> PortfolioService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CoverChangeURLProtocol.self]
        return PortfolioService(
            session: URLSession(configuration: configuration),
            baseURL: URL(string: "https://example.supabase.co")!,
            anonKey: "test-anon-key",
            functionsBaseURL: URL(string: "https://example.functions.supabase.co")!
        )
    }

    private static func json(_ request: URLRequest, _ body: String, status: Int = 200) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }
}

private final class CoverChangeRequestRecorder {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ request: URLRequest) {
        lock.lock()
        storage.append(request)
        lock.unlock()
    }
}

private final class CoverChangeURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let materialized = try request.materializingHTTPBodyForTesting()
            let (response, data) = try handler(materialized)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
