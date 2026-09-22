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
    private let contentAnalysisService: ContentAnalysisService

    init(captureStore: any CaptureStoring, contentAnalysisService: ContentAnalysisService) {
        self.captureStore = captureStore
        self.contentAnalysisService = contentAnalysisService
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

    /// 캡처 한 장을 서버로 보내 분석한다. 아직 DETAIL-01(캡처 상세) 화면이 없어서 그리드에서
    /// 바로 트리거하는 임시 진입점이다 — 화면설계서상 원래 자리는 아니다.
    func analyze(_ capture: Capture) async {
        guard !analyzingCaptureIDs.contains(capture.id) else { return }
        analyzingCaptureIDs.insert(capture.id)
        defer { analyzingCaptureIDs.remove(capture.id) }
        errorMessage = nil
        do {
            try await contentAnalysisService.analyze(capture)
            await load()
        } catch {
            errorMessage = "분석에 실패했어요: \(error)"
        }
    }
}
