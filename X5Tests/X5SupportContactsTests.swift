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

    // 23.10: «Связаться с разработчиком» — владелец не пишет сам себе.
    func testOfficialAccountDetection() {
        XCTAssertTrue(X5SupportContacts.isOfficialAccount("EEE55A08-18D1-46E3-A303-1411D1BB9333"))
        XCTAssertFalse(X5SupportContacts.isOfficialAccount("00000000-0000-0000-0000-000000000000"))
        XCTAssertFalse(X5SupportContacts.isOfficialAccount(nil))
    }

    // 23.10: почта поддержки — живой ящик, письмо с готовой темой.
    func testSupportMailtoHasLiveAddressAndSubject() throws {
        let url = try XCTUnwrap(X5SupportContacts.mailtoURL)
        XCTAssertEqual(url.scheme, "mailto")
        XCTAssertTrue(url.absoluteString.hasPrefix("mailto:adilkhanskii@gmail.com?subject="))
    }
}
