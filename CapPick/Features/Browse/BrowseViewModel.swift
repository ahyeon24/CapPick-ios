import Foundation
import Observation

// 화면설계서 BROWSE-01이 보여줄 범위 — Home 카드나 FOLDER-01 행을 눌러 들어온다. 폴더 전환은
// 이 화면 안에서 하지 않고(§7.3의 가로 폴더 줄은 이번엔 없음) Home/FOLDER-01로 돌아가 다시
// 들어가는 것으로 대신한다.
enum BrowseScope: Equatable {
    case all
    case unclassified
    case folder(Folder)

    var folderID: String? {
        if case .folder(let folder) = self { folder.id } else { nil }
    }

    var title: String {
        switch self {
        case .all: "전체"
        case .unclassified: "미분류"
        case .folder(let folder): folder.displayName
        }
    }
}

// 검색어가 비어있으면 scope의 최근순 목록을 보여주고(SEARCH-06 — 미분석 이미지도 탐색 가능해야
// 해서 분류 준비 상태로 거르지 않는다), 검색어를 실행하면 SearchService가 같은 scope 범위 안에서
// 결과를 대신 정렬해서 준다(SEARCH-04).
@MainActor @Observable
final class BrowseViewModel {
    private(set) var captures: [Capture] = []
    private(set) var folders: [Folder] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var analyzingCaptureIDs: Set<String> = []
    /// 검색 결과를 보여주는 중인지 — 빈 배열이 "라이브러리 자체가 비었다"인지 "검색 결과 없음"인지
    /// 구분하는 데 쓴다(SEARCH-08).
    private(set) var isSearchActive = false
    var searchText = ""
    /// 지금 화면에 결과가 보이는 검색어(입력 중인 searchText와 다를 수 있다) — 제목에 쓴다.
    private(set) var activeQuery = ""

    /// 폴더 이름·기준이 이 화면에서 바뀌면 refreshFolder()가 새 값으로 갈아끼운다.
    private(set) var scope: BrowseScope
    private let captureStore: any CaptureStoring
    private let folderStore: any FolderStoring
    private let analysisQueueService: AnalysisQueueService
    private let searchService: SearchService
    /// SEARCH-09: 늦게 끝난 이전 검색 요청이 최신 검색어의 결과를 덮어쓰지 않게 하는 가드.
    private var latestSearchRequestID: UUID?

    init(
        scope: BrowseScope, captureStore: any CaptureStoring, folderStore: any FolderStoring,
        analysisQueueService: AnalysisQueueService, searchService: SearchService,
        initialQuery: String? = nil
    ) {
        self.scope = scope
        self.captureStore = captureStore
        self.folderStore = folderStore
        self.analysisQueueService = analysisQueueService
        self.searchService = searchService
        // HOME-01 상단 검색에서 넘어올 때만 쓴다(§2 흐름: "HOME-01 상단에서 검색 실행 →
        // BROWSE-01 전체 검색 결과"). View의 .task가 이 값을 보고 load() 대신 search()를 부른다.
        let trimmedInitialQuery = initialQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedInitialQuery.isEmpty {
            self.searchText = trimmedInitialQuery
        }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        do {
            let scoped = try await fetchScopedCaptures()
            folders = try await folderStore.fetchAll()
            // 검색이 진행 중이거나 끝나 결과를 보여주는 중이면 전체 목록으로 덮어쓰지 않는다 —
            // 홈에서 검색해 들어올 때 검색과 목록 읽기가 같이 시작돼, 첫 검색(모델 준비로 조금
            // 느림)에서 목록이 늦게 와 검색 결과를 덮어쓰던 버그가 있었다(2026-10-17).
            guard latestSearchRequestID == nil, !isSearchActive else { return }
            captures = scoped
        } catch {
            errorMessage = "캡처를 불러오지 못했어요."
        }
    }

    private func fetchScopedCaptures() async throws -> [Capture] {
        switch scope {
        case .all: try await captureStore.fetchAll()
        case .unclassified: try await captureStore.fetchUnclassified()
        case .folder(let folder): try await captureStore.fetch(in: folder)
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
            let results = try await searchService.search(query: query, folderID: scope.folderID)
            guard latestSearchRequestID == requestID else { return } // 이미 더 최신 요청이 있음
            captures = results
            isSearchActive = true
            activeQuery = query
        } catch {
            guard latestSearchRequestID == requestID else { return }
            errorMessage = "검색을 완료하지 못했어요."
        }
    }

    /// 검색어를 지우면(SEARCH-*: "검색어 지우기") scope의 최근순 목록으로 돌아간다 — 네트워크 요청 없음.
    /// 폴더 수정 시트에서 저장한 뒤 부른다 — 제목 등이 새 이름을 따르게 한다.
    func refreshFolder() async {
        guard case .folder(let folder) = scope,
              let updated = try? await folderStore.fetchFolder(id: folder.id) else { return }
        scope = .folder(updated)
    }

    func clearSearch() async {
        latestSearchRequestID = nil
        isSearchActive = false
        activeQuery = ""
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
            errorMessage = AnalysisPauseReason(serverError: error)?.userMessage ?? "분석에 실패했어요: \(error)"
        }
    }

    /// MEMBER-01의 "한 장" 케이스(FOLDER-03) — 썸네일 컨텍스트 메뉴에서 부른다. 이미 그 폴더에
    /// 있어도 다시 불러도 안전하다(present로 덮어쓸 뿐 — GRDBFolderStore.addManually 참고).
    func addToFolder(_ capture: Capture, folderID: String) async {
        errorMessage = nil
        do {
            try await folderStore.addManually(captureID: capture.id, to: folderID)
        } catch {
            errorMessage = "폴더에 추가하지 못했어요."
        }
    }

    /// 폴더 범위(scope == .folder)에서 보고 있을 때만 의미가 있다 — 지금 보고 있는 그 폴더에서
    /// 뺀다. 성공하면 다시 불러서 그리드에서 사라지게 한다(fetch(in:)가 present만 반환).
    func removeFromCurrentFolder(_ capture: Capture) async {
        guard let folderID = scope.folderID else { return }
        errorMessage = nil
        do {
            try await folderStore.removeManually(captureID: capture.id, from: folderID)
            await load()
        } catch {
            errorMessage = "폴더에서 제거하지 못했어요."
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
