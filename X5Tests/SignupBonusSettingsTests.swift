import XCTest
@testable import X5

/// Управление бонусом новым из профиля владельца (Адильхан 01.11).
/// Границы — как в signup_bonus_update_settings (миграция 20261101120000).
final class SignupBonusSettingsTests: XCTestCase {
    func testValidateGiftAndLimitBounds() {
        XCTAssertNil(SignupBonusSettingsError.validate(credits: 200, maxGrants: 1000, granted: 4))
        XCTAssertEqual(SignupBonusSettingsError.validate(credits: 0, maxGrants: 1000, granted: 4), .credits)
        XCTAssertEqual(SignupBonusSettingsError.validate(credits: 10_001, maxGrants: 1000, granted: 4), .credits)
        XCTAssertEqual(SignupBonusSettingsError.validate(credits: nil, maxGrants: 1000, granted: 4), .credits)
        XCTAssertEqual(SignupBonusSettingsError.validate(credits: 200, maxGrants: 3, granted: 4), .limit)
        XCTAssertNil(SignupBonusSettingsError.validate(credits: 200, maxGrants: 4, granted: 4))
        XCTAssertEqual(SignupBonusSettingsError.validate(credits: 200, maxGrants: 1_000_001, granted: 4), .limit)
        XCTAssertEqual(SignupBonusSettingsError.validate(credits: 200, maxGrants: nil, granted: 4), .limit)
    }

    func testServerErrorsMapToReadableKeys() {
        XCTAssertEqual(SignupBonusSettingsError.from(code: "42501", message: "developer_required"), .access)
        XCTAssertEqual(SignupBonusSettingsError.from(code: "22023", message: "invalid_credits"), .credits)
        XCTAssertEqual(SignupBonusSettingsError.from(code: "22023", message: "max_grants_below_granted"), .limit)
        XCTAssertEqual(SignupBonusSettingsError.from(code: "22023", message: "invalid_max_grants"), .limit)
        XCTAssertEqual(SignupBonusSettingsError.from(code: nil, message: nil), .save)
    }

    func testNumberFieldKeepsDigitsOnly() {
        XCTAssertEqual(SignupBonusSettingsError.number(from: "1 000"), 1000)
        XCTAssertNil(SignupBonusSettingsError.number(from: ""))
    }

    func testStatsDecodeWithAndWithoutNewFields() throws {
        let full = Data(#"{"granted":4,"max_grants":1000,"credits":200,"enabled":false}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(SignupBonusStats.self, from: full),
                       SignupBonusStats(granted: 4, maxGrants: 1000, credits: 200, enabled: false))
        let old = Data(#"{"granted":4,"max_grants":1000}"#.utf8)
        let decoded = try JSONDecoder().decode(SignupBonusStats.self, from: old)
        XCTAssertEqual(decoded.credits, 200)
        XCTAssertTrue(decoded.enabled)
    }

    func testTextsExistInRuEnKk() {
        let keys = ["bonus_ctl_row", "bonus_ctl_on", "bonus_ctl_paused", "bonus_ctl_title", "bonus_ctl_toggle",
                    "bonus_ctl_toggle_hint", "bonus_ctl_credits", "bonus_ctl_limit", "bonus_ctl_granted",
                    "bonus_ctl_err_credits", "bonus_ctl_err_limit", "bonus_ctl_err_access", "bonus_ctl_err_save"]
        for language in [AppLanguage.ru, .en, .kk] {
            for key in keys {
                XCTAssertNotNil(LocalizationService.dict[language]?[key], "\(language).\(key)")
            }
        }
        XCTAssertEqual(LocalizationService.dict[.ru]?["bonus_ctl_toggle"], "Раздавать бонус")
    }
}
