import Observation

// 화면설계서 BROWSE-01의 "빈 검색어" 흐름만 먼저 구현한다: 검색어 없이 선택 범위(지금은 전체)를
// 최근순으로 보여준다. 미분석 이미지도 탐색 가능해야 한다는 규칙(§3.4 SEARCH-06)을 지키려고
// fetchAll()을 그대로 쓴다 — 검색 준비 상태로 거르지 않는다.
@MainActor @Observable
final class BrowseViewModel {
    private(set) var captures: [Capture] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private let captureStore: any CaptureStoring

    init(captureStore: any CaptureStoring) {
        self.captureStore = captureStore
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
}
