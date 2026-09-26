import Foundation
import Observation

// 화면설계서 §12 SETTINGS-01 중 이번 라운드 범위(사용량 표시 + 앱 데이터 삭제)만 다룬다 —
// 사진 접근 상태·데이터 처리 안내 정적 문구·결제는 후속 과제(CapPick-ios/CLAUDE.md 참고).
@MainActor @Observable
final class SettingsViewModel {
    private(set) var usage: UsageSummary?
    private(set) var isLoadingUsage = false
    private(set) var usageLoadFailed = false
    private(set) var isDeletingData = false
    private(set) var deletionError: String?
    /// true가 되면 View가 화면을 닫는다.
    private(set) var didDeleteData = false

    private let usageService: UsageService
    private let appDataDeletionService: AppDataDeletionService

    init(usageService: UsageService, appDataDeletionService: AppDataDeletionService) {
        self.usageService = usageService
        self.appDataDeletionService = appDataDeletionService
    }

    func load() async {
        isLoadingUsage = true
        usageLoadFailed = false
        defer { isLoadingUsage = false }
        do {
            usage = try await usageService.fetchUsage()
        } catch {
            usageLoadFailed = true
        }
    }

    func deleteAllData() async {
        isDeletingData = true
        deletionError = nil
        defer { isDeletingData = false }
        do {
            try await appDataDeletionService.deleteAllAppData()
            didDeleteData = true
        } catch {
            deletionError = "데이터를 삭제하지 못했어요. 다시 시도해주세요."
        }
    }
}
