import Foundation

/// 로컬 개발 전용. 서버의 `DevBypassAttestationVerifier`와 짝을 이룬다 — Apple Developer Program
/// 미가입 상태라 지금은 이게 유일하게 동작하는 구현체다 (`CapPick-server/CLAUDE.md` "설치 검증" 참고).
final class DevBypassAttestationProvider: AttestationProvider {
    private let appStateStore: any AppStateStoring

    init(appStateStore: any AppStateStoring) {
        self.appStateStore = appStateStore
    }

    func keyId() async throws -> String {
        if let existing = try await appStateStore.value(for: AppStateKey.attestationKeyId) {
            return existing
        }
        let generated = "dev-bypass-" + UUID().uuidString
        try await appStateStore.setValue(generated, for: AppStateKey.attestationKeyId)
        return generated
    }

    func attestationObject(challenge: Data, keyId: String) async throws -> Data {
        Data("dev-bypass-attestation".utf8)
    }

    func assertionObject(challenge: Data, keyId: String) async throws -> Data {
        Data("dev-bypass-assertion".utf8)
    }
}
