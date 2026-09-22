import CryptoKit
import DeviceCheck
import Foundation

enum AppAttestError: Error {
    case unsupported
}

/// 실제 App Attest 구현. 서버의 `AppleAppAttestVerifier`와 짝을 이룬다.
///
/// ⚠️ 실기기에서 동작 확인 아직 안 함 — Apple Developer Program 미가입이라 App Attest capability를
/// 프로비저닝 프로파일에 켤 수 없다(`CapPick-server/CLAUDE.md` "설치 검증" 참고). 시뮬레이터는
/// `DCAppAttestService.isSupported`가 항상 false라 여기서도 테스트가 안 된다. 계정이 생기면
/// `AppEnvironment.live()`에서 이 클래스로 교체하고 실기기로 등록·갱신 흐름부터 다시 검증할 것.
// DCAppAttestService.shared는 애플 문서상 어느 큐에서 호출해도 되는 싱글턴이라 @unchecked로 표시한다
// — Swift 6 동시성 검사기가 DeviceCheck를 Sendable로 감사하지 않아서다.
final class AppAttestProvider: AttestationProvider, @unchecked Sendable {
    private let service = DCAppAttestService.shared
    private let appStateStore: any AppStateStoring

    init(appStateStore: any AppStateStoring) {
        self.appStateStore = appStateStore
    }

    func keyId() async throws -> String {
        if let existing = try await appStateStore.value(for: AppStateKey.attestationKeyId) {
            return existing
        }
        guard service.isSupported else { throw AppAttestError.unsupported }
        let generated = try await service.generateKey()
        try await appStateStore.setValue(generated, for: AppStateKey.attestationKeyId)
        return generated
    }

    func attestationObject(challenge: Data, keyId: String) async throws -> Data {
        try await service.attestKey(keyId, clientDataHash: clientDataHash(for: challenge))
    }

    func assertionObject(challenge: Data, keyId: String) async throws -> Data {
        try await service.generateAssertion(keyId, clientDataHash: clientDataHash(for: challenge))
    }

    // 서버(InstallationService.challengeBytes)와 동일하게 challenge 문자열의 UTF-8 바이트를
    // 그대로 해시한다 — base64 디코딩하지 않는다.
    private func clientDataHash(for challenge: Data) -> Data {
        Data(SHA256.hash(data: challenge))
    }
}
