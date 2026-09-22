import Observation

// 화면설계서 BROWSE-01의 "빈 검색어" 흐름만 먼저 구현한다: 검색어 없이 선택 범위(지금은 전체)를
// 최근순으로 보여준다. 미분석 이미지도 탐색 가능해야 한다는 규칙(§3.4 SEARCH-06)을 지키려고
// fetchAll()을 그대로 쓴다 — 검색 준비 상태로 거르지 않는다.
@MainActor @Observable
final class BrowseViewModel {
    private(set) var captures: [Capture] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var analyzingCaptureIDs: Set<String> = []

    private let captureStore: any CaptureStoring
    private let analysisQueueService: AnalysisQueueService

    init(captureStore: any CaptureStoring, analysisQueueService: AnalysisQueueService) {
        self.captureStore = captureStore
        self.analysisQueueService = analysisQueueService
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        do {
            captures = try await captureStore.fetchAll()
        } catch {
            errorMessage = "캡처를 불러오지 못했어요."
        }
    }

    /// pending 캡처는 자동 큐가 처리하므로, 여기서는 실패(failed)한 캡처를 사용자가 직접
    /// 재시도할 때만 쓴다(DETAIL-01이 생기면 옮길 자리 — 화면설계서상 원래 위치는 아니다).
    func retry(_ capture: Capture) async {
        guard !analyzingCaptureIDs.contains(capture.id) else { return }
        analyzingCaptureIDs.insert(capture.id)
        defer { analyzingCaptureIDs.remove(capture.id) }
        errorMessage = nil
        do {
            try await analysisQueueService.retry(capture)
            await load()
        } catch {
            errorMessage = "분석에 실패했어요: \(error)"
        }
    }

    /// 큐가 백그라운드에서 pending 캡처들을 처리하는 동안 그리드도 같이 갱신되도록 진행 중엔
    /// 주기적으로 다시 불러온다. HomeViewModel.observeQueueUntilIdle과 같은 이유로 actor의
    /// isRunning을 직접 관찰하지 않고, 관찰 가능한 진행률로 종료를 판단한다.
    func observeQueueUntilIdle() async {
        while let progress = try? await captureStore.currentProgress(), progress.searchPending > 0 {
            try? await Task.sleep(for: .seconds(2))
            await load()
        }
    }
}
