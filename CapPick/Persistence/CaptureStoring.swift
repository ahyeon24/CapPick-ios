import Foundation

// 캡처 목록에 어떤 캡처가 보여야 하는지(ERD §3)는 이 프로토콜 구현체 안에서만 판단한다.
// 호출하는 쪽(ViewModel)은 필터 조건을 다시 조립하지 않는다.
protocol CaptureStoring: Sendable {
    func save(_ capture: Capture) async throws

    /// "전체": 접근 가능하고 캡픽에서 제외하지 않은 캡처, 최근순.
    func fetchAll() async throws -> [Capture]

    /// "미분류": 접근 가능 AND 제외 아님 AND 검색 준비 완료 AND 분류 complete AND 실제 소속 폴더 0개 (ERD §3).
    func fetchUnclassified() async throws -> [Capture]

    /// 폴더에 실제로 소속(present)된 캡처 중 접근 가능하고 제외하지 않은 것, 최근순.
    func fetch(in folder: Folder) async throws -> [Capture]

    func currentProgress() async throws -> AnalysisProgress

    /// 사진 보관함에서 발견한 스크린샷을 로컬 목록에 맞춘다 (기능명세서 PHOTO-04·PHOTO-06).
    /// 새 자산은 분석 대기(pending) 상태로 등록하고, 같은 자산은 다시 등록하지 않는다.
    /// 이번 목록에 없는 기존 캡처는 접근 불가(unavailable)로 표시하고, 다시 나타나면 접근 가능으로 되돌린다.
    /// 캡픽에서 제외한 캡처도 기록이 남아 있으므로 다시 등록되지 않는다.
    func registerDiscovered(_ screenshots: [DiscoveredScreenshot]) async throws -> ScreenshotSyncResult

    /// content_analysis 작업 결과를 저장하고 캡처의 searchState를 ready로 바꾼다. 하나의
    /// 트랜잭션으로 처리한다 — CaptureAnalysis·SearchDocument·Capture.searchState가 따로 놀지 않게.
    func saveAnalysis(_ analysis: CaptureAnalysis, searchDocument: SearchDocument) async throws

    /// 자동 순차 분석 큐가 다음으로 처리할 캡처: 접근 가능·제외 아님·searchState pending 중
    /// 최근 캡처 하나. 없으면 nil — 큐가 이걸로 루프 종료를 판단한다.
    func nextPendingForAnalysis() async throws -> Capture?

    /// 큐가 이 캡처의 분석을 시작하기 직전에 부른다.
    func markSearchProcessing(_ captureID: String) async throws

    /// 분석 실패 시 부른다 — 이후 자동 큐 루프(nextPendingForAnalysis)에서 이 캡처는 더 이상
    /// 집히지 않는다(무한 재시도 금지). 사용자가 명시적으로 재시도할 때만 다시 처리된다.
    func markSearchFailed(_ captureID: String) async throws

    /// 앱이 분석 도중 종료된 뒤 재실행됐을 때, processing에 멈춰있던 캡처를 전부 pending으로
    /// 되돌려 큐가 다시 집어갈 수 있게 한다.
    func resetStuckProcessing() async throws

    /// 검색 후보: 분석이 끝나(searchDocument가 있는) 접근 가능·제외 안 된 캡처. capturedFrom/Before로
    /// 캡처 시각 구간을, folderID로 그 폴더에 실제 소속(present)된 캡처만으로 좁힌다(SEARCH-04,
    /// 전부 nil이면 전체 기간·전체 범위). 최근 캡처부터.
    func fetchSearchCandidates(capturedFrom: Date?, capturedBefore: Date?, folderID: String?) async throws -> [SearchCandidate]

    /// 로컬에 저장된 임베딩의 모델 버전. 지금은 서버 설정이 고정이라 분석 완료된 캡처는 전부 같은
    /// 버전일 거라고 가정하고 아무거나 하나를 돌려준다 — 분석된 캡처가 하나도 없으면 nil(검색
    /// 자체가 의미 없음).
    func currentEmbeddingModelVersion() async throws -> String?

    /// "미분류" 개수만 필요할 때(HOME-01 카드) 전체 목록을 안 가져오고 센다. fetchUnclassified()와
    /// 같은 규칙(ERD §3)을 COUNT(*)로 구현한다.
    func unclassifiedCount() async throws -> Int

    /// 폴더별 present·visible(접근 가능·제외 안 됨) 캡처 개수를 한 번의 쿼리로 — HOME-01 카드
    /// N개를 그릴 때 폴더마다 따로 세지 않는다. 소속 캡처가 0장인 폴더는 결과에서 아예 빠진다
    /// (호출하는 쪽이 없는 키를 0으로 취급).
    func fetchFolderCaptureCounts() async throws -> [String: Int]

    /// id로 캡처 하나. DETAIL-01이 목록에서 넘겨받은 값 대신 최신 상태로 다시 읽을 때 쓴다.
    func fetchCapture(id: String) async throws -> Capture?

    /// DETAIL-05 즐겨찾기 토글.
    func setFavorite(_ captureID: String, favorite: Bool) async throws

    /// DETAIL-06 캡픽에서 제외. Self.visible이 이미 excludedAt IS NULL을 요구하므로, 이후
    /// fetchAll/fetch(in:)/fetchUnclassified/검색 후보 등 모든 조회에서 자동으로 빠진다.
    func exclude(_ captureID: String, at date: Date) async throws
}
