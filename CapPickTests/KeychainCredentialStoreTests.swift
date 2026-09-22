import XCTest
@testable import CapPick

final class KeychainCredentialStoreTests: XCTestCase {
    private var store: KeychainCredentialStore!

    override func setUpWithError() throws {
        // 테스트끼리 겹치지 않게 매번 다른 service 이름을 쓴다.
        store = KeychainCredentialStore(service: "com.cappick.ios.tests.\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? store.delete()
    }

    func testLoadReturnsNilWhenNothingSaved() throws {
        XCTAssertNil(try store.load())
    }

    func testSaveThenLoadRoundTrips() throws {
        try store.save("secret-token")
        XCTAssertEqual(try store.load(), "secret-token")
    }

    func testSavingTwiceReplacesThePreviousValue() throws {
        try store.save("first")
        try store.save("second")
        XCTAssertEqual(try store.load(), "second")
    }

    func testDeleteRemovesTheValue() throws {
        try store.save("secret-token")
        try store.delete()
        XCTAssertNil(try store.load())
    }

    func testDeleteWhenNothingSavedDoesNotThrow() throws {
        XCTAssertNoThrow(try store.delete())
    }
}
