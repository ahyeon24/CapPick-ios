import Foundation

/// SETTINGS-01 사용량 표시(기능명세서 §3.8) — 서버 `GET /v1/usage`를 부른다. 서버의 같은 이름
/// `UsageService`와는 다른 레이어(이쪽은 클라이언트 API 호출만, 저장은 안 함)다.
actor UsageService {
    private let usageAPIClient: any UsageAPIClient
    private let installationRegistrar: InstallationRegistrar

    init(usageAPIClient: any UsageAPIClient, installationRegistrar: InstallationRegistrar) {
        self.usageAPIClient = usageAPIClient
        self.installationRegistrar = installationRegistrar
    }

    func fetchUsage() async throws -> UsageSummary {
        let credential = try await installationRegistrar.ensureRegistered()
        return try await usageAPIClient.fetchUsage(credential: credential)
    }
}
