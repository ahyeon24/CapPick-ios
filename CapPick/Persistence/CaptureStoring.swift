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
}
