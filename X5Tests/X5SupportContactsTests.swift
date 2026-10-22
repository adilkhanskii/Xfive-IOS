import XCTest
@testable import X5

// Поддержка в Настройках (Адильхан 22.10): WhatsApp и основной аккаунт X5.
final class X5SupportContactsTests: XCTestCase {
    func testWhatsAppLinkOpensAdilkhanNumber() {
        XCTAssertEqual(X5SupportContacts.whatsappURL, "https://wa.me/77007744401")
        XCTAssertNotNil(URL(string: X5SupportContacts.whatsappURL))
    }

    func testOfficialAccountIsOwnerProfileId() {
        XCTAssertNotNil(UUID(uuidString: X5SupportContacts.officialAccountId))
    }
}
