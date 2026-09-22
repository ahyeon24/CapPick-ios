import XCTest
@testable import CapPick

final class InstallationRegistrarTests: XCTestCase {

    func testEnsureRegisteredReturnsStoredCredentialWithoutCallingAPI() async throws {
        let api = FakeInstallationAPIClient()
        let credentialStore = InMemoryCredentialStore()
        try credentialStore.save("already-stored")
        let registrar = InstallationRegistrar(
            apiClient: api, attestationProvider: FakeAttestationProvider(), credentialStore: credentialStore)

        let result = try await registrar.ensureRegistered()

        XCTAssertEqual(result, "already-stored")
        XCTAssertEqual(api.challengeCallCount, 0)
    }

    func testEnsureRegisteredRegistersAndStoresCredentialWhenMissing() async throws {
        let api = FakeInstallationAPIClient()
        let attestation = FakeAttestationProvider()
        let credentialStore = InMemoryCredentialStore()
        let registrar = InstallationRegistrar(apiClient: api, attestationProvider: attestation, credentialStore: credentialStore)

        let result = try await registrar.ensureRegistered()

        XCTAssertEqual(result, "cred-1")
        XCTAssertEqual(try credentialStore.load(), "cred-1")
        XCTAssertEqual(api.registerCalls.count, 1)
        XCTAssertEqual(api.registerCalls[0].challengeId, "c1")
        XCTAssertEqual(api.registerCalls[0].keyId, "fake-key-id")
        XCTAssertEqual(attestation.attestationCallCount, 1)
        XCTAssertEqual(attestation.assertionCallCount, 0)
        // 서버와 동일하게 challenge 문자열의 UTF-8 바이트를 그대로 넘겨야 한다(base64 디코딩 안 함).
        XCTAssertEqual(attestation.lastChallenge, Data("challenge-value".utf8))
    }

    func testRegisterFailurePropagatesAndDoesNotStoreCredential() async throws {
        let api = FakeInstallationAPIClient()
        api.registerResult = .failure(StubError())
        let credentialStore = InMemoryCredentialStore()
        let registrar = InstallationRegistrar(
            apiClient: api, attestationProvider: FakeAttestationProvider(), credentialStore: credentialStore)

        do {
            _ = try await registrar.ensureRegistered()
            XCTFail("expected failure")
        } catch is StubError {
            // 기대한 대로
        }
        XCTAssertNil(try credentialStore.load())
    }

    func testRenewUsesStoredCredentialAndReplacesItWithAssertion() async throws {
        let api = FakeInstallationAPIClient()
        let attestation = FakeAttestationProvider()
        let credentialStore = InMemoryCredentialStore()
        try credentialStore.save("old-cred")
        let registrar = InstallationRegistrar(apiClient: api, attestationProvider: attestation, credentialStore: credentialStore)

        let result = try await registrar.renew()

        XCTAssertEqual(result, "cred-2")
        XCTAssertEqual(try credentialStore.load(), "cred-2")
        XCTAssertEqual(api.renewCalls.count, 1)
        XCTAssertEqual(api.renewCalls[0].currentCredential, "old-cred")
        XCTAssertEqual(attestation.assertionCallCount, 1)
        XCTAssertEqual(attestation.attestationCallCount, 0)
    }

    func testRenewWithoutStoredCredentialFallsBackToRegister() async throws {
        let api = FakeInstallationAPIClient()
        let credentialStore = InMemoryCredentialStore()
        let registrar = InstallationRegistrar(
            apiClient: api, attestationProvider: FakeAttestationProvider(), credentialStore: credentialStore)

        let result = try await registrar.renew()

        XCTAssertEqual(result, "cred-1")
        XCTAssertEqual(api.registerCalls.count, 1)
        XCTAssertEqual(api.renewCalls.count, 0)
    }
}
