import Observation

// 화면설계서 HOME-01의 첫 단계: 접근 가능한 스크린샷 수와 분석 진행 상태만 보여준다.
// 검색·폴더 카드는 아직 없다.
@MainActor @Observable
final class HomeViewModel {
    private(set) var progress: AnalysisProgress?
    private(set) var authorization: PhotoAuthorization
    private(set) var errorMessage: String?

    private let library: any ScreenshotLibrary
    private let syncService: ScreenshotSyncService
    private let captureStore: any CaptureStoring
    private let appStateStore: any AppStateStoring
    private let analysisQueueService: AnalysisQueueService

    init(
        library: any ScreenshotLibrary,
        syncService: ScreenshotSyncService,
        captureStore: any CaptureStoring,
        appStateStore: any AppStateStoring,
        analysisQueueService: AnalysisQueueService
    ) {
        self.library = library
        self.syncService = syncService
        self.captureStore = captureStore
        self.appStateStore = appStateStore
        self.analysisQueueService = analysisQueueService
        self.authorization = library.authorization
    }

    /// 앱 실행·복귀 시 새 캡처를 확인하고 진행 상태를 다시 읽는다 (PHOTO-04). ON-03에서 분석
    /// 시작에 동의했다면 pending 캡처 자동 분석 큐를 깨우고, 큐가 도는 동안 진행률을 갱신한다.
    func refresh() async {
        authorization = library.authorization
        errorMessage = nil
        do {
            _ = try await syncService.sync()
            progress = try await captureStore.currentProgress()
        } catch {
            errorMessage = "스크린샷을 확인하지 못했어요."
        }

        guard (try? await appStateStore.value(for: AppStateKey.analysisStartRequested)) == "true" else { return }
        Task { await analysisQueueService.resumeIfNeeded() }
        await observeQueueUntilIdle()
    }

    // 큐 actor의 isRunning을 밖에서 직접 관찰하지 않는다 — 방금 fire-and-forget으로 띄운 Task가
    // 실제로 시작되기 전에 이 루프가 먼저 돌면 곧바로 빠져나가 버리는 레이스가 생긴다. 대신 관찰
    // 가능한 진행률(searchPending == 0) 자체로 종료를 판단한다.
    private func observeQueueUntilIdle() async {
        while let latest = try? await captureStore.currentProgress(), latest.searchPending > 0 {
            try? await Task.sleep(for: .seconds(2))
            progress = try? await captureStore.currentProgress()
        }
    }
}
