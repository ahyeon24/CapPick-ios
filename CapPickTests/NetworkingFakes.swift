import Foundation
@testable import CapPick

final class FakeInstallationAPIClient: InstallationAPIClient, @unchecked Sendable {
    var challengeToReturn = ChallengeIssued(challengeId: "c1", challenge: "challenge-value", expiresAt: Date(timeIntervalSince1970: 1_000))
    var registerResult: Result<InstallationRegistered, Error> = .success(
        InstallationRegistered(installationId: "i1", credential: "cred-1", expiresAt: Date(timeIntervalSince1970: 2_000)))
    var renewResult: Result<CredentialRenewed, Error> = .success(
        CredentialRenewed(credential: "cred-2", expiresAt: Date(timeIntervalSince1970: 3_000)))

    private(set) var challengeCallCount = 0
    private(set) var registerCalls: [(challengeId: String, keyId: String, attestationObject: Data)] = []
    private(set) var renewCalls: [(currentCredential: String, challengeId: String, assertionObject: Data)] = []

    func requestChallenge() async throws -> ChallengeIssued {
        challengeCallCount += 1
        return challengeToReturn
    }

    func register(challengeId: String, keyId: String, attestationObject: Data) async throws -> InstallationRegistered {
        registerCalls.append((challengeId, keyId, attestationObject))
        return try registerResult.get()
    }

    func renewCredential(currentCredential: String, challengeId: String, assertionObject: Data) async throws -> CredentialRenewed {
        renewCalls.append((currentCredential, challengeId, assertionObject))
        return try renewResult.get()
    }
}

final class FakeAttestationProvider: AttestationProvider, @unchecked Sendable {
    var keyIdToReturn = "fake-key-id"
    private(set) var attestationCallCount = 0
    private(set) var assertionCallCount = 0
    private(set) var lastChallenge: Data?

    func keyId() async throws -> String {
        keyIdToReturn
    }

    func attestationObject(challenge: Data, keyId: String) async throws -> Data {
        attestationCallCount += 1
        lastChallenge = challenge
        return Data("attestation".utf8)
    }

    func assertionObject(challenge: Data, keyId: String) async throws -> Data {
        assertionCallCount += 1
        lastChallenge = challenge
        return Data("assertion".utf8)
    }
}

final class InMemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    private var stored: String?

    func save(_ credential: String) throws {
        stored = credential
    }

    func load() throws -> String? {
        stored
    }

    func delete() throws {
        stored = nil
    }
}

struct StubError: Error {}
