import XCTest
@testable import X5

/// Начисление кредитов владельцем (Адильхан 02.11).
/// Границы — как в owner_grant_credits / owner_search_users (миграция 20261102120000).
final class OwnerCreditsTests: XCTestCase {
    func testAmountBounds() {
        XCTAssertNil(OwnerCreditsError.validate(amount: 1))
        XCTAssertNil(OwnerCreditsError.validate(amount: 100_000))
        XCTAssertEqual(OwnerCreditsError.validate(amount: 0), .amount)
        XCTAssertEqual(OwnerCreditsError.validate(amount: -5), .amount)
        XCTAssertEqual(OwnerCreditsError.validate(amount: 100_001), .amount)
        XCTAssertEqual(OwnerCreditsError.validate(amount: nil), .amount)
    }

    func testSearchNeedsThreeCharacters() {
        XCTAssertFalse(OwnerCreditsError.canSearch("ab"))
        XCTAssertFalse(OwnerCreditsError.canSearch("  ab  "))
        XCTAssertTrue(OwnerCreditsError.canSearch("abc"))
    }

    func testServerErrorsMapToReadableKeys() {
        XCTAssertEqual(OwnerCreditsError.from(code: "42501", message: "developer_required", fallback: .grant), .access)
        XCTAssertEqual(OwnerCreditsError.from(code: "22023", message: "invalid_amount", fallback: .grant), .amount)
        XCTAssertEqual(OwnerCreditsError.from(code: "22023", message: "query_too_short", fallback: .search), .query)
        XCTAssertEqual(OwnerCreditsError.from(code: "P0001", message: "profile_not_found", fallback: .grant), .notFound)
        XCTAssertEqual(OwnerCreditsError.from(code: nil, message: nil, fallback: .search), .search)
        XCTAssertEqual(OwnerCreditsError.notFound.localizationKey, "credits_ctl_err_not_found")
    }

    func testNumberFieldKeepsDigitsOnly() {
        XCTAssertEqual(OwnerCreditsError.number(from: "1 000"), 1000)
        XCTAssertNil(OwnerCreditsError.number(from: ""))
    }

    func testSearchRowsDecodeAndLabel() throws {
        let data = Data(#"[{"id":"871a0446-3e8b-464a-b02d-9bd4a527e481","name":"Тест","nickname":"qa_2","email":"qa@x5.app","credits":1},{"id":"x","name":null,"nickname":null,"email":"a@b.c","credits":null}]"#.utf8)
        let users = try JSONDecoder().decode([OwnerCreditsUser].self, from: data)
        XCTAssertEqual(users.count, 2)
        XCTAssertEqual(users[0].label, "@qa_2")
        XCTAssertEqual(users[0].credits, 1)
        XCTAssertEqual(users[1].label, "a@b.c")
        XCTAssertEqual(users[1].credits, 0)
        XCTAssertEqual(try JSONDecoder().decode(Int.self, from: Data("6".utf8)), 6)
    }

    func testTextsExistInRuEnKk() {
        let keys = ["credits_ctl_row", "credits_ctl_title", "credits_ctl_search", "credits_ctl_search_hint", "credits_ctl_nothing",
                    "credits_ctl_balance", "credits_ctl_change", "credits_ctl_amount", "credits_ctl_note", "credits_ctl_submit",
                    "credits_ctl_confirm", "credits_ctl_cancel", "credits_ctl_yes", "credits_ctl_done",
                    "credits_ctl_err_amount", "credits_ctl_err_query", "credits_ctl_err_access", "credits_ctl_err_not_found",
                    "credits_ctl_err_search", "credits_ctl_err_grant"]
        for language in [AppLanguage.ru, .en, .kk] {
            for key in keys {
                XCTAssertNotNil(LocalizationService.dict[language]?[key], "\(language).\(key)")
            }
        }
        XCTAssertEqual(LocalizationService.dict[.ru]?["credits_ctl_confirm"], "Начислить {n} кредитов пользователю {user}?")
    }
}
