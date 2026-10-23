import XCTest
@testable import X5

final class SalesCreativeBriefBuilderTests: XCTestCase {
    func testCatalogContainsAllClientRequestedAngles() {
        XCTAssertEqual(SalesAngle.all.count, 10)
        XCTAssertEqual(Set(SalesAngle.all.map(\.id)).count, 10)
        XCTAssertEqual(SalesAngle.all.first?.id, "pain")
        XCTAssertEqual(SalesAngle.all.last?.id, "loss_aversion")
    }

    func testPromptExplainsUploadedImageRolesInOrder() {
        let prompt = SalesCreativeBriefBuilder.compose(
            description: "Установка BI-LED линз от 90 000 тенге в Алматы",
            angle: SalesAngle.all[2],
            hasMainPhoto: true,
            hasLogo: true,
            referenceCount: 2
        )

        XCTAssertTrue(prompt.contains("Товар или услуга: Установка BI-LED линз"))
        XCTAssertTrue(prompt.contains("угол продаж: Через выгоду"))
        XCTAssertTrue(prompt.contains("изображение 1 является основной фотографией"))
        XCTAssertTrue(prompt.contains("изображение 2 является логотипом"))
        XCTAssertTrue(prompt.contains("изображения 3-4 являются референсами стиля"))
        XCTAssertTrue(prompt.contains("Самостоятельно напиши короткий продающий заголовок"))
    }

    func testPromptDoesNotInventImageRolesWhenNothingIsUploaded() {
        let prompt = SalesCreativeBriefBuilder.compose(
            description: "Доставка цветов по Астане",
            angle: SalesAngle.all[0],
            hasMainPhoto: false,
            hasLogo: false,
            referenceCount: 0
        )

        XCTAssertFalse(prompt.contains("Роли загруженных материалов"))
    }

    /// The client reported that switching the angle changed nothing in the
    /// creative. The angle has to lead the brief and carry its own tone, not
    /// sit as one interchangeable line in the middle.
    func testAngleLeadsTheBriefAndCarriesItsOwnTone() {
        let pain = SalesCreativeBriefBuilder.compose(
            description: "Курс по таргету",
            angle: SalesAngle.all[0],
            hasMainPhoto: false,
            hasLogo: false,
            referenceCount: 0
        )
        let benefit = SalesCreativeBriefBuilder.compose(
            description: "Курс по таргету",
            angle: SalesAngle.all[2],
            hasMainPhoto: false,
            hasLogo: false,
            referenceCount: 0
        )

        XCTAssertTrue(pain.contains("Главное требование — угол продаж: Через боль клиента"))
        XCTAssertTrue(pain.contains(SalesAngle.all[0].examples[0]))
        XCTAssertTrue(benefit.contains(SalesAngle.all[2].examples[0]))
        XCTAssertTrue(pain.contains("Не пиши универсальный заголовок"))
        XCTAssertNotEqual(pain, benefit)

        // The angle must survive even a description long enough to have blown
        // past the old backend prompt cap.
        let longDescription = String(repeating: "детали предложения, цена и город. ", count: 60)
        let longPrompt = SalesCreativeBriefBuilder.compose(
            description: longDescription,
            angle: SalesAngle.all[0],
            hasMainPhoto: true,
            hasLogo: true,
            referenceCount: 1
        )
        XCTAssertTrue(longPrompt.contains("Главное требование — угол продаж: Через боль клиента"))
        XCTAssertTrue(longPrompt.contains("изображение 1 является основной фотографией"))
        XCTAssertTrue(longPrompt.contains("изображение 2 является логотипом"))
        XCTAssertLessThanOrEqual(longPrompt.count, 4000)
    }

    /// Two creatives in a row must not be the same picture.
    func testVariationChangesTheCompositionDirective() {
        let first = SalesCreativeVariation.all[0]
        let second = SalesCreativeVariation.pick(excluding: first.id)
        XCTAssertNotEqual(second.id, first.id)

        let prompt = SalesCreativeBriefBuilder.compose(
            description: "Доставка цветов по Астане",
            angle: SalesAngle.all[0],
            hasMainPhoto: false,
            hasLogo: false,
            referenceCount: 0,
            variation: second
        )
        XCTAssertTrue(prompt.contains(second.directive))
        XCTAssertGreaterThanOrEqual(SalesCreativeVariation.all.count, 4)
        XCTAssertEqual(Set(SalesCreativeVariation.all.map(\.id)).count, SalesCreativeVariation.all.count)
    }
}
