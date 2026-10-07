import UIKit
import XCTest
@testable import X5

/// Обложки из галереи ужимаются один раз сразу после выбора (сборка 247):
/// полное фото с камеры тормозило редактор курса и уходило на сервер целиком.
final class CourseCoverImageTests: XCTestCase {
    func testLargePhotoIsDownscaledToMaxPixelSize() throws {
        let source = try XCTUnwrap(Self.jpeg(width: 4000, height: 3000))

        let prepared = try XCTUnwrap(CourseCoverImage.prepare(source))

        let cg = try XCTUnwrap(prepared.preview.cgImage)
        XCTAssertEqual(max(cg.width, cg.height), Int(CourseCoverImage.maxPixelSize))
        // Пропорции сохраняются (4:3).
        XCTAssertEqual(Double(cg.width) / Double(cg.height), 4.0 / 3.0, accuracy: 0.01)
        XCTAssertLessThan(prepared.jpeg.count, source.count)
        XCTAssertNotNil(UIImage(data: prepared.jpeg))
    }

    func testSmallPhotoIsNotUpscaled() throws {
        let source = try XCTUnwrap(Self.jpeg(width: 800, height: 450))

        let prepared = try XCTUnwrap(CourseCoverImage.prepare(source))

        let cg = try XCTUnwrap(prepared.preview.cgImage)
        XCTAssertEqual(cg.width, 800)
        XCTAssertEqual(cg.height, 450)
    }

    func testNotAnImageReturnsNil() {
        XCTAssertNil(CourseCoverImage.prepare(Data("not an image".utf8)))
    }

    private static func jpeg(width: Int, height: Int) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height),
            format: format
        ).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return image.jpegData(compressionQuality: 0.95)
    }
}
