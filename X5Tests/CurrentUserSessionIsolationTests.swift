import Foundation
import XCTest
@testable import X5

@MainActor
final class CurrentUserSessionIsolationTests: XCTestCase {
    private let accountA = "11111111-1111-4111-8111-111111111111"
    private let accountB = "22222222-2222-4222-8222-222222222222"

    override func tearDown() {
        ProfileIsolationURLProtocol.handler = nil
        super.tearDown()
    }

    private func makeUser(account: @escaping @MainActor () -> String?) -> CurrentUser {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProfileIsolationURLProtocol.self]
        return CurrentUser(session: URLSession(configuration: configuration), sessionUserID: account, restoreCache: false)
    }

    func testDelayedPreviousAccountResponseCannotOverwriteCurrentProfileOrCache() async {
        var currentAccount: String? = accountA
        let user = makeUser { currentAccount }
        let oldRequestStarted = expectation(description: "request A held")
        var delayed: ProfileIsolationURLProtocol?
        ProfileIsolationURLProtocol.handler = { request in
            if request.request.value(forHTTPHeaderField: "Authorization") == "Bearer A" {
                delayed = request
                oldRequestStarted.fulfill()
            } else {
                request.complete(userID: self.accountB, credits: 200)
            }
        }
        let oldLoad = Task { await user.load(userId: accountA, accessToken: "A") }
        await fulfillment(of: [oldRequestStarted], timeout: 5)
        currentAccount = accountB
        let newLoaded = await user.load(userId: accountB, accessToken: "B")
        XCTAssertTrue(newLoaded)
        delayed?.complete(userID: accountA, credits: 100)
        let oldLoaded = await oldLoad.value
        XCTAssertFalse(oldLoaded)
        XCTAssertEqual(user.profile?.id, accountB)
        XCTAssertEqual(user.profile?.credits, 200)
    }

    func testSignedOutResponseCannotRestorePrivateProfile() async {
        var currentAccount: String? = accountA
        let user = makeUser { currentAccount }
        let started = expectation(description: "request held")
        var delayed: ProfileIsolationURLProtocol?
        ProfileIsolationURLProtocol.handler = { request in delayed = request; started.fulfill() }
        let load = Task { await user.load(userId: accountA, accessToken: "A") }
        await fulfillment(of: [started], timeout: 5)
        currentAccount = nil
        NotificationCenter.default.post(name: .x5UserDidSignOut, object: nil)
        delayed?.complete(userID: accountA, credits: 100)
        let loaded = await load.value
        XCTAssertFalse(loaded)
        XCTAssertNil(user.profile)
    }

    func testConcurrentSameAccountLoadsRemainValidForLoginRouting() async {
        let user = makeUser { self.accountA }
        let started = expectation(description: "both requests held")
        started.expectedFulfillmentCount = 2
        let requests = HeldProfileRequests()
        ProfileIsolationURLProtocol.handler = { request in requests.add(request); started.fulfill() }
        let first = Task { await user.load(userId: accountA, accessToken: "A") }
        let second = Task { await user.load(userId: accountA, accessToken: "refreshed-A") }
        await fulfillment(of: [started], timeout: 5)
        for request in requests.snapshot { request.complete(userID: accountA, credits: 100) }
        let firstLoaded = await first.value
        let secondLoaded = await second.value
        XCTAssertTrue(firstLoaded)
        XCTAssertTrue(secondLoaded)
        XCTAssertEqual(user.profile?.id, accountA)
    }

    func testSignOutAndBackToSameAccountInvalidatesOldSessionIncarnation() async {
        var currentAccount: String? = accountA
        let user = makeUser { currentAccount }
        let started = expectation(description: "old session held")
        var delayed: ProfileIsolationURLProtocol?
        ProfileIsolationURLProtocol.handler = { request in delayed = request; started.fulfill() }
        let load = Task { await user.load(userId: accountA, accessToken: "A") }
        await fulfillment(of: [started], timeout: 5)
        currentAccount = nil
        NotificationCenter.default.post(name: .x5UserDidSignOut, object: nil)
        currentAccount = accountA
        delayed?.complete(userID: accountA, credits: 100)
        let loaded = await load.value
        XCTAssertFalse(loaded)
        XCTAssertNil(user.profile)
    }

    func testLatePatchCannotReplaceNextAccount() async {
        var currentAccount: String? = accountA
        let user = makeUser { currentAccount }
        ProfileIsolationURLProtocol.handler = { $0.complete(userID: self.accountA, credits: 100) }
        _ = await user.load(userId: accountA, accessToken: "A")
        let started = expectation(description: "PATCH held")
        var delayed: ProfileIsolationURLProtocol?
        ProfileIsolationURLProtocol.handler = { request in
            if request.request.httpMethod == "PATCH" { delayed = request; started.fulfill() }
            else { request.complete(userID: self.accountB, credits: 200) }
        }
        let patch = Task { await user.patch("name", value: "Old account edit", accessToken: "A") }
        await fulfillment(of: [started], timeout: 5)
        currentAccount = accountB
        _ = await user.load(userId: accountB, accessToken: "B")
        delayed?.complete(userID: accountA, credits: 100)
        let patched = await patch.value
        XCTAssertFalse(patched)
        XCTAssertEqual(user.profile?.id, accountB)
    }

    func testStaleAvatarNeverPatchesNextAccountOrReportsSuccess() async {
        var currentAccount: String? = accountA
        let user = makeUser { currentAccount }
        ProfileIsolationURLProtocol.handler = { $0.complete(userID: self.accountA, credits: 100) }
        _ = await user.load(userId: accountA, accessToken: "A")
        let started = expectation(description: "upload held")
        var delayed: ProfileIsolationURLProtocol?
        let patches = HeldProfileRequests()
        ProfileIsolationURLProtocol.handler = { request in
            if request.request.httpMethod == "POST" { delayed = request; started.fulfill() }
            else {
                if request.request.httpMethod == "PATCH" { patches.add(request) }
                request.complete(userID: self.accountB, credits: 200)
            }
        }
        let upload = Task { await user.uploadAvatar(Data([1, 2, 3]), accessToken: "A") }
        await fulfillment(of: [started], timeout: 5)
        currentAccount = accountB
        _ = await user.load(userId: accountB, accessToken: "B")
        delayed?.complete(userID: accountA, credits: 100)
        let url = await upload.value
        XCTAssertNil(url)
        XCTAssertTrue(patches.snapshot.isEmpty)
        XCTAssertEqual(user.profile?.id, accountB)
    }

    func testDelayedCreditResultCannotMutateAnotherAccount() async throws {
        var currentAccount: String? = accountA
        let user = makeUser { currentAccount }
        ProfileIsolationURLProtocol.handler = { $0.complete(userID: self.accountA, credits: 100) }
        _ = await user.load(userId: accountA, accessToken: "A")
        let previousOperation = try XCTUnwrap(user.operationContext())
        currentAccount = accountB
        ProfileIsolationURLProtocol.handler = { $0.complete(userID: self.accountB, credits: 200) }
        _ = await user.load(userId: accountB, accessToken: "B")
        user.applyCreditsRemaining(1, for: previousOperation)
        XCTAssertEqual(user.profile?.credits, 200)
        user.applyCreditsRemaining(150, for: user.operationContext())
        XCTAssertEqual(user.profile?.credits, 150)
    }

    func testUnexpectedResponseOwnerFailsClosed() async {
        let user = makeUser { self.accountA }
        ProfileIsolationURLProtocol.handler = { $0.complete(userID: self.accountB, credits: 200) }
        let loaded = await user.load(userId: accountA, accessToken: "A")
        XCTAssertFalse(loaded)
        XCTAssertNil(user.profile)
    }

    func testCurrentAccountPatchPreservesNormalEditing() async {
        let user = makeUser { self.accountA }
        ProfileIsolationURLProtocol.handler = { $0.complete(userID: self.accountA, credits: 100) }
        let loaded = await user.load(userId: accountA.uppercased(), accessToken: "A")
        let patched = await user.patch("name", value: "Current account edit", accessToken: "A")
        XCTAssertTrue(loaded)
        XCTAssertTrue(patched)
        XCTAssertEqual(user.profile?.id, accountA)
    }

    func testLateProfileCreationAndIgnoredInsertRefetchAreAccountFenced() async {
        for holdRefetch in [false, true] {
            var currentAccount: String? = accountA
            let user = makeUser { currentAccount }
            let started = expectation(description: holdRefetch ? "refetch held" : "creation held")
            let requests = HeldProfileRequests()
            var delayed: ProfileIsolationURLProtocol?
            ProfileIsolationURLProtocol.handler = { request in
                if request.request.value(forHTTPHeaderField: "Authorization") == "Bearer B" {
                    request.complete(userID: self.accountB, credits: 200)
                    return
                }
                requests.add(request)
                let isHeld = holdRefetch ? requests.snapshot.count == 3 : request.request.httpMethod == "POST"
                if isHeld { delayed = request; started.fulfill() }
                else { request.respond(status: 200, body: "[]") }
            }
            let oldLoad = Task { await user.load(userId: accountA, accessToken: "A") }
            await fulfillment(of: [started], timeout: 5)
            currentAccount = accountB
            _ = await user.load(userId: accountB, accessToken: "B")
            delayed?.complete(userID: accountA, credits: 100)
            let oldLoaded = await oldLoad.value
            XCTAssertFalse(oldLoaded)
            XCTAssertEqual(user.profile?.id, accountB)
            XCTAssertNil(user.error)
            XCTAssertEqual(requests.snapshot.count, holdRefetch ? 3 : 2)
        }
    }

    func testLateErrorDoesNotChangeNewAccountsErrorOrLoadingState() async {
        var currentAccount: String? = accountA
        let user = makeUser { currentAccount }
        let startedA = expectation(description: "A held")
        let startedB = expectation(description: "B held")
        var delayedA: ProfileIsolationURLProtocol?
        var delayedB: ProfileIsolationURLProtocol?
        ProfileIsolationURLProtocol.handler = { request in
            if request.request.value(forHTTPHeaderField: "Authorization") == "Bearer A" {
                delayedA = request; startedA.fulfill()
            } else { delayedB = request; startedB.fulfill() }
        }
        let loadA = Task { await user.load(userId: accountA, accessToken: "A") }
        await fulfillment(of: [startedA], timeout: 5)
        currentAccount = accountB
        let loadB = Task { await user.load(userId: accountB, accessToken: "B") }
        await fulfillment(of: [startedB], timeout: 5)
        delayedA?.respond(status: 500, body: "previous-account-error")
        _ = await loadA.value
        XCTAssertNil(user.error)
        XCTAssertTrue(user.isLoading)
        delayedB?.complete(userID: accountB, credits: 200)
        _ = await loadB.value
        XCTAssertFalse(user.isLoading)
        XCTAssertEqual(user.profile?.id, accountB)
    }

    func testMissingProfileCreationControlRefetchesIgnoredInsertOnce() async {
        let user = makeUser { self.accountA }
        let requests = HeldProfileRequests()
        ProfileIsolationURLProtocol.handler = { request in
            requests.add(request)
            if requests.snapshot.count < 3 { request.respond(status: 200, body: "[]") }
            else { request.complete(userID: self.accountA, credits: 0) }
        }
        let loaded = await user.load(userId: accountA, accessToken: "A")
        XCTAssertTrue(loaded)
        XCTAssertEqual(requests.snapshot.map { $0.request.httpMethod }, ["GET", "POST", "GET"])
        XCTAssertEqual(user.profile?.id, accountA)
    }

    func testSignOutAndProfileEntitlementEventsApplySynchronouslyInOrder() {
        let subscription = Subscription()
        NotificationCenter.default.post(name: .x5ProfileDidUpdate, object: nil, userInfo: ["is_pro": true])
        XCTAssertTrue(subscription.isPro)
        NotificationCenter.default.post(name: .x5UserDidSignOut, object: nil)
        XCTAssertFalse(subscription.isPro)
        NotificationCenter.default.post(name: .x5ProfileDidUpdate, object: nil, userInfo: ["is_pro": false])
        XCTAssertFalse(subscription.isPro)
    }

    func testTokenFenceRejectsSwitchDuringRefreshAndAllowsSameAccountRotation() async throws {
        var currentAccount: String? = accountA
        let user = makeUser { currentAccount }
        let operation = try XCTUnwrap(user.operationContext())
        let fresh = await user.accessTokenForOperation(operation) { "rotated-A" }
        XCTAssertEqual(fresh, "rotated-A")
        let switched = await user.accessTokenForOperation(operation) {
            currentAccount = self.accountB
            await Task.yield()
            return "B"
        }
        XCTAssertNil(switched)
        var invoked = false
        let stale = await user.accessTokenForOperation(operation) { invoked = true; return "B" }
        XCTAssertNil(stale)
        XCTAssertFalse(invoked)
    }

    func testCourseUnauthorizedRetryCannotBorrowNextAccountsToken() async throws {
        var currentAccount: String? = accountA
        let user = makeUser { currentAccount }
        let operation = try XCTUnwrap(user.operationContext())
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProfileIsolationURLProtocol.self]
        let service = CoursePurchaseService(session: URLSession(configuration: configuration))
        let started = expectation(description: "A purchase held before 401")
        let requests = HeldProfileRequests()
        ProfileIsolationURLProtocol.handler = { request in
            requests.add(request)
            if requests.snapshot.count == 1 { started.fulfill() }
            else { request.respond(status: 500, body: "unexpected cross-account POST") }
        }
        let purchase = Task {
            try await service.purchase(courseId: accountA, expectedPrice: 1_000, accessToken: "A", refreshAccessToken: {
                await user.accessTokenForOperation(operation) { "B" }
            })
        }
        await fulfillment(of: [started], timeout: 5)
        currentAccount = accountB
        requests.snapshot.first?.respond(status: 401, body: #"{"message":"JWT expired"}"#)
        do {
            _ = try await purchase.value
            XCTFail("The previous account's purchase must stop")
        } catch let error as CoursePurchaseServiceError {
            XCTAssertEqual(error, .missingAccessToken)
        }
        XCTAssertEqual(requests.snapshot.count, 1)
        XCTAssertEqual(requests.snapshot.first?.request.value(forHTTPHeaderField: "Authorization"), "Bearer A")
    }

    func testUnfencedCourseCallbackCounterexampleWouldReplayAsNextAccount() async throws {
        // Baseline caller behavior: a fresh-token closure without owner/epoch
        // checks can replay an old 401 POST under a different account.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProfileIsolationURLProtocol.self]
        let service = CoursePurchaseService(session: URLSession(configuration: configuration))
        let requests = HeldProfileRequests()
        ProfileIsolationURLProtocol.handler = { request in
            requests.add(request)
            request.respond(status: 401, body: #"{"message":"JWT expired"}"#)
        }
        do {
            _ = try await service.purchase(courseId: accountA, expectedPrice: 1_000, accessToken: "A", refreshAccessToken: { "B" })
            XCTFail("The synthetic second 401 must fail")
        } catch let error as CoursePurchaseServiceError {
            XCTAssertEqual(error, .http(statusCode: 401, message: "JWT expired"))
        }
        XCTAssertEqual(requests.snapshot.map { $0.request.value(forHTTPHeaderField: "Authorization") }, ["Bearer A", "Bearer B"])
    }
}

private final class HeldProfileRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ProfileIsolationURLProtocol] = []
    func add(_ value: ProfileIsolationURLProtocol) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    var snapshot: [ProfileIsolationURLProtocol] { lock.lock(); defer { lock.unlock() }; return values }
}

private final class ProfileIsolationURLProtocol: URLProtocol {
    static var handler: ((ProfileIsolationURLProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(self) }
    override func stopLoading() {}

    func complete(userID: String, credits: Int) {
        respond(status: 200, body: "[{\"id\":\"\(userID)\",\"credits\":\(credits),\"plan\":\"free\"}]")
    }

    func respond(status: Int, body: String) {
        let data = Data(body.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
