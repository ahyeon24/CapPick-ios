import Foundation

// API 명세 §3. 앱이 서버와 통신하는 첫 경계 — Job 등 다른 도메인 클라이언트도 이 폴더에 같은
// 패턴(프로토콜 + URLSession 구현체)으로 추가한다.
protocol InstallationAPIClient: Sendable {
    func requestChallenge() async throws -> ChallengeIssued
    func register(challengeId: String, keyId: String, attestationObject: Data) async throws -> InstallationRegistered
    func renewCredential(currentCredential: String, challengeId: String, assertionObject: Data) async throws -> CredentialRenewed
}

struct ChallengeIssued: Equatable, Sendable {
    let challengeId: String
    let challenge: String
    let expiresAt: Date
}

struct InstallationRegistered: Equatable, Sendable {
    let installationId: String
    let credential: String
    let expiresAt: Date
}

struct CredentialRenewed: Equatable, Sendable {
    let credential: String
    let expiresAt: Date
}

enum CapPickAPIError: Error, Equatable {
    /// 서버가 API 명세 §2 형식으로 돌려준 오류.
    case server(status: Int, code: String, message: String, retryable: Bool)
    /// HTTP 응답이 아니거나 알 수 없는 상태 — 오류 본문을 못 읽었을 때.
    case unexpectedResponse(status: Int)
    case network(String)
    case decoding(String)
}
