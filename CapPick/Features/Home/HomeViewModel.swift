import Observation

// 화면설계서 HOME-01: 접근 가능한 스크린샷 수·분석 진행 상태에 이어 2열 폴더 카드(전체/미분류/
// 사용자 폴더)까지 보여준다. 검색창(§7.1 상단 큰 검색영역)은 아직 없다 — BROWSE-01 하단
// 검색창만 있다(사용자 결정, 2026-09-22).
@MainActor @Observable
final class HomeViewModel {
    private(set) var progress: AnalysisProgress?
    private(set) var authorization: PhotoAuthorization
    private(set) var errorMessage: String?
    /// 분석 큐가 한도 때문에 멈춰 있으면 그 안내 문구.
    private(set) var analysisPauseMessage: String?
    private(set) var folders: [Folder] = []
    private(set) var unclassifiedCount = 0
    /// 폴더 카드에 겹쳐 보여줄 최근 캡처(카드당 최대 3장).
    private(set) var cardPreviews = FolderCardPreviews()
    private var folderCounts: [String: Int] = [:]

    private let library: any ScreenshotLibrary
    private let syncService: ScreenshotSyncService
    private let captureStore: any CaptureStoring
    private let folderStore: any FolderStoring
    private let appStateStore: any AppStateStoring
    private let analysisQueueService: AnalysisQueueService

    init(
        library: any ScreenshotLibrary,
        syncService: ScreenshotSyncService,
        captureStore: any CaptureStoring,
        folderStore: any FolderStoring,
        appStateStore: any AppStateStoring,
        analysisQueueService: AnalysisQueueService
    ) {
        self.library = library
        self.syncService = syncService
        self.captureStore = captureStore
        self.folderStore = folderStore
        self.appStateStore = appStateStore
        self.analysisQueueService = analysisQueueService
        self.authorization = library.authorization
    }

    /// 소속 캡처가 0장인 폴더는 fetchFolderCaptureCounts() 결과에 키 자체가 없다.
    func count(for folder: Folder) -> Int {
        folderCounts[folder.id] ?? 0
    }

    /// 앱 실행·복귀 시 새 캡처를 확인하고 진행 상태·폴더 카드를 다시 읽는다 (PHOTO-04). ON-03에서
    /// 분석 시작에 동의했다면 pending 캡처 자동 분석 큐를 깨우고, 큐가 도는 동안 진행률을 갱신한다.
    func refresh() async {
        authorization = library.authorization
        errorMessage = nil
        do {
            _ = try await syncService.sync()
            progress = try await captureStore.currentProgress()
            folders = try await folderStore.fetchAll()
            folderCounts = try await captureStore.fetchFolderCaptureCounts()
            unclassifiedCount = try await captureStore.unclassifiedCount()
            cardPreviews = try await captureStore.fetchFolderCardPreviews(limit: 3)
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
            // 한도 때문에 멈췄으면 pending이 남아 있어도 더 줄어들지 않는다 — 여기서 관찰을 끝낸다.
            if let reason = await analysisQueueService.pauseReason() {
                analysisPauseMessage = reason.userMessage
                return
            }
        }
        analysisPauseMessage = nil
    }
}
