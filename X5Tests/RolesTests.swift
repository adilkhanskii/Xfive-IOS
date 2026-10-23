import XCTest
@testable import X5

final class RolesTests: XCTestCase {
    private let ownerUserId = "f3eea23f-0aeb-405b-ab35-2c53173b7a8f"
    private let adilkhanUserId = "eee55a08-18d1-46e3-a303-1411d1bb9333"

    func testOnlyTheTwoExactAccountsAreDevelopers() {
        XCTAssertTrue(Roles.isDeveloper(email: "changed-owner-email@example.com", userId: ownerUserId))
        XCTAssertTrue(Roles.isDeveloper(email: "changed-adilkhan-email@example.com", userId: adilkhanUserId))

        XCTAssertFalse(Roles.isDeveloper(email: "h-a-n-1@mail.ru", userId: "9ae99a45-91ac-486a-b7ec-e6614b7bc257"))
        XCTAssertFalse(Roles.isDeveloper(email: nil, userId: "496071cf-7c5b-43e8-886e-9f43c4618f90"))
        XCTAssertFalse(Roles.isDeveloper(email: "tooyakov.art@gmail.com", userId: "00000000-0000-4000-8000-000000000099"))
        XCTAssertFalse(Roles.isDeveloper(email: "tuakov.ursa@gmail.com", userId: nil))
        XCTAssertFalse(Roles.isDeveloper(email: nil, userId: nil))
    }
}
