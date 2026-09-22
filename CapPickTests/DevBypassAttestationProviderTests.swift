import XCTest
@testable import CapPick

final class DevBypassAttestationProviderTests: XCTestCase {
    private var appState: GRDBAppStateStore!

    override func setUp() async throws {
        appState = GRDBAppStateStore(database: try AppDatabase.makeInMemory())
    }

    func testKeyIdIsGeneratedOnceAndCached() async throws {
        let provider = DevBypassAttestationProvider(appStateStore: appState)

        let first = try await provider.keyId()
        let second = try await provider.keyId()

        XCTAssertEqual(first, second)
        let stored = try await appState.value(for: AppStateKey.attestationKeyId)
        XCTAssertEqual(stored, first)
    }

    func testAttestationAndAssertionObjectsAreNonEmpty() async throws {
        let provider = DevBypassAttestationProvider(appStateStore: appState)
        let keyId = try await provider.keyId()

        let attestation = try await provider.attestationObject(challenge: Data("x".utf8), keyId: keyId)
        let assertion = try await provider.assertionObject(challenge: Data("x".utf8), keyId: keyId)

        XCTAssertFalse(attestation.isEmpty)
        XCTAssertFalse(assertion.isEmpty)
    }
}
