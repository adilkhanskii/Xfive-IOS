import UIKit
import XCTest
@testable import X5

/// Адильхан 10.10 18:30: у «Бухгалтер» был пустой значок (calculator.fill нет в iOS).
/// Проверяем на симуляторе, что у КАЖДОЙ категории Hub настоящий SF Symbol.
final class HubCategorySymbolTests: XCTestCase {
    func testEveryHubCategoryHasAnExistingSymbol() {
        for category in HubCategories.all {
            let name = HubCategories.rawSymbol(for: category.id)
            XCTAssertNotNil(UIImage(systemName: name), "Нет значка \(name) для \(category.id)")
            XCTAssertEqual(HubCategories.symbol(for: category.id), name)
        }
    }

    func testMissingSymbolFallsBackToGenericIcon() {
        XCTAssertNotNil(UIImage(systemName: HubCategories.symbol(for: "no_such_category")))
    }
}
