import Foundation

// 서버 external/attestation의 AttestationVerifier와 짝을 이루는 클라이언트 쪽 경계.
// App Attest 실제 호출(DCAppAttestService)과 개발용 우회를 이 인터페이스 뒤로 격리한다.
protocol AttestationProvider: Sendable {
    /// 이 설치의 App Attest 키 식별자. 기기당 한 번만 생성하고 캐싱해서 재사용한다.
    func keyId() async throws -> String
    /// 신규 등록용 attestation object (서버 AttestationRequest.attestationObject).
    func attestationObject(challenge: Data, keyId: String) async throws -> Data
    /// 자격 갱신용 assertion object (서버 AssertionRequest.assertionObject).
    func assertionObject(challenge: Data, keyId: String) async throws -> Data
}
