import Foundation

/// 로그인 화면 없이 앱 설치 단위로 서버 자격을 확보한다(기능명세서 §3.9, 시스템 설계 §7).
/// 사용자에게 보이는 흐름이 아니라 백그라운드에서 조용히 진행 — 실패해도 앱 핵심 기능(사진 접근,
/// 로컬 검색)을 막지 않는다. 호출하는 쪽이 실패를 무시하거나 나중에 다시 시도할 수 있다.
actor InstallationRegistrar {
    private let apiClient: any InstallationAPIClient
    private let attestationProvider: any AttestationProvider
    private let credentialStore: any CredentialStoring

    init(
        apiClient: any InstallationAPIClient,
        attestationProvider: any AttestationProvider,
        credentialStore: any CredentialStoring
    ) {
        self.apiClient = apiClient
        self.attestationProvider = attestationProvider
        self.credentialStore = credentialStore
    }

    /// 저장된 자격이 있으면 그대로 돌려주고, 없으면 새로 등록한다.
    @discardableResult
    func ensureRegistered() async throws -> String {
        if let existing = try credentialStore.load() {
            return existing
        }
        return try await register()
    }

    /// 저장된 자격으로 새 자격을 발급받는다. 만료 임박 판단은 아직 이 앞단에 없다 — 호출자가 필요할 때 부른다.
    @discardableResult
    func renew() async throws -> String {
        guard let current = try credentialStore.load() else {
            return try await register()
        }
        let challenge = try await apiClient.requestChallenge()
        let keyId = try await attestationProvider.keyId()
        let assertionObject = try await attestationProvider.assertionObject(
            challenge: challengeBytes(challenge.challenge), keyId: keyId)
        let renewed = try await apiClient.renewCredential(
            currentCredential: current, challengeId: challenge.challengeId, assertionObject: assertionObject)
        try credentialStore.save(renewed.credential)
        return renewed.credential
    }

    private func register() async throws -> String {
        let challenge = try await apiClient.requestChallenge()
        let keyId = try await attestationProvider.keyId()
        let attestationObject = try await attestationProvider.attestationObject(
            challenge: challengeBytes(challenge.challenge), keyId: keyId)
        let registered = try await apiClient.register(
            challengeId: challenge.challengeId, keyId: keyId, attestationObject: attestationObject)
        try credentialStore.save(registered.credential)
        return registered.credential
    }

    // 서버(InstallationService.challengeBytes)와 동일하게 challenge 문자열의 UTF-8 바이트를 그대로 쓴다.
    private func challengeBytes(_ challenge: String) -> Data {
        Data(challenge.utf8)
    }
}
