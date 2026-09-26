import Foundation
import OSLog

/// SETTINGS-01 앱 데이터 삭제(기능명세서 §3.8). 시스템 설계 §2 "로컬 DB가 기준" 원칙에 따라
/// **서버 삭제 요청이 실패해도 로컬 삭제는 항상 진행한다**(사용자 결정, 2026-09-26) — 서버 쪽은
/// 어차피 임시 Job 데이터 정리일 뿐이고, 사용자에게 중요한 건 자기 기기의 데이터가 지워지는
/// 것이다. 서버 요청의 완료를 기다리거나 폴링하지 않는다 — 지금 서버 구현은 Job 행을 지우는
/// 동기적 DB 작업이라 대개 즉시 끝나지만(CapPick-server/CLAUDE.md "사용량·삭제" 절), 그 완료
/// 시점을 이 화면이 기다릴 이유는 없다.
actor AppDataDeletionService {
    private static let logger = Logger(subsystem: "com.cappick.ios", category: "AppDataDeletionService")

    private let deletionAPIClient: any DeletionAPIClient
    private let installationRegistrar: InstallationRegistrar
    private let database: AppDatabase

    init(deletionAPIClient: any DeletionAPIClient, installationRegistrar: InstallationRegistrar, database: AppDatabase) {
        self.deletionAPIClient = deletionAPIClient
        self.installationRegistrar = installationRegistrar
        self.database = database
    }

    func deleteAllAppData() async throws {
        do {
            let credential = try await installationRegistrar.ensureRegistered()
            _ = try await deletionAPIClient.requestInstallationDeletion(
                credential: credential, idempotencyKey: UUID().uuidString)
        } catch {
            // best-effort — 서버 호출이 실패해도(오프라인 등) 로컬 삭제는 그대로 진행한다.
            Self.logger.warning("server-side deletion request failed, continuing with local erase: \(error)")
        }
        try await database.eraseAllLocalData()
    }
}
