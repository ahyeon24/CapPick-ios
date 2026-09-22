import Foundation
import Observation

// 화면설계서 BROWSE-01. 검색어가 비어있으면 선택 범위(지금은 전체)를 최근순으로 보여주고
// (SEARCH-06 — 미분석 이미지도 탐색 가능해야 해서 fetchAll()을 그대로 쓴다, 검색 준비 상태로
// 거르지 않는다), 검색어를 실행하면 SearchService가 결과를 대신 정렬해서 준다. 폴더 범위 검색
// (SEARCH-04·05)은 FOLDER-* 화면이 아직 없어서 이번엔 없다 — 항상 전체 범위.
@MainActor @Observable
final class BrowseViewModel {
    private(set) var captures: [Capture] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var analyzingCaptureIDs: Set<String> = []
    /// 검색 결과를 보여주는 중인지 — 빈 배열이 "라이브러리 자체가 비었다"인지 "검색 결과 없음"인지
    /// 구분하는 데 쓴다(SEARCH-08).
    private(set) var isSearchActive = false
    var searchText = ""

    private let captureStore: any CaptureStoring
    private let analysisQueueService: AnalysisQueueService
    private let searchService: SearchService
    /// SEARCH-09: 늦게 끝난 이전 검색 요청이 최신 검색어의 결과를 덮어쓰지 않게 하는 가드.
    private var latestSearchRequestID: UUID?

    init(captureStore: any CaptureStoring, analysisQueueService: AnalysisQueueService, searchService: SearchService) {
        self.captureStore = captureStore
        self.analysisQueueService = analysisQueueService
        self.searchService = searchService
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

    /// "검색 실행" 시점에만 부른다 — 입력할 때마다 부르지 않는다(SEARCH-*: 검색은 실행 시에만 AI 요청).
    func search() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            await clearSearch()
            return
        }
        let requestID = UUID()
        latestSearchRequestID = requestID
        isLoading = true
        errorMessage = nil
        defer {
            if latestSearchRequestID == requestID { isLoading = false }
        }
        do {
            let results = try await searchService.search(query: query)
            guard latestSearchRequestID == requestID else { return } // 이미 더 최신 요청이 있음
            captures = results
            isSearchActive = true
        } catch {
            guard latestSearchRequestID == requestID else { return }
            errorMessage = "검색을 완료하지 못했어요."
        }
    }

    /// 검색어를 지우면(SEARCH-*: "검색어 지우기") 최근순 전체 탐색으로 돌아간다 — 네트워크 요청 없음.
    func clearSearch() async {
        latestSearchRequestID = nil
        isSearchActive = false
        searchText = ""
        await load()
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
    /// isRunning을 직접 관찰하지 않고, 관찰 가능한 진행률로 종료를 판단한다. 검색 결과를 보는
    /// 중이면 전체 목록으로 덮어쓰지 않는다 — 검색은 사용자가 다시 실행해야 갱신된다.
    func observeQueueUntilIdle() async {
        while let progress = try? await captureStore.currentProgress(), progress.searchPending > 0 {
            try? await Task.sleep(for: .seconds(2))
            if !isSearchActive {
                await load()
            }
        }
    }
}
