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
}
