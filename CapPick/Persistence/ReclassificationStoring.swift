import Foundation

// RECLASS-01. ERD ReclassificationRun/Item(§2)을 처음 실제로 쓴다 — 모델은 이미 있었지만 이번까지
// 아무도 안 썼다.
protocol ReclassificationStoring: Sendable {
    /// 이 폴더에 아직 확정(적용·취소)되지 않은 실행이 있는지 — 중복 실행 방지(화면설계서 §11
    /// "실패·처리 중 중복 실행을 막고").
    func activeRun(folderID: String) async throws -> ReclassificationRun?

    /// 새 실행을 만든다. 폴더의 현재 criteriaVersion·membershipRevision을 그대로 고정해서 저장한다
    /// (ERD: "미리보기 기준과 소속 버전 고정") — 계산 도중 기준이 바뀌어도 이 실행은 계산 시작
    /// 시점 기준으로 일관되게 남는다.
    func createRun(folderID: String, criteriaVersion: Int, membershipRevision: Int, mode: ReclassificationMode) async throws -> ReclassificationRun

    func fetchRun(id: String) async throws -> ReclassificationRun?
    func fetchItems(runID: String) async throws -> [ReclassificationItem]
    func saveItems(_ items: [ReclassificationItem]) async throws
    func setRunState(_ runID: String, state: String) async throws
    func setItemState(runID: String, captureID: String, state: String) async throws
}

// state 값 집합은 ERD에 명시돼 있지 않다(Folder.criteriaState 등과 같은 사정) — 이 서비스 계층
// 안에서만 쓰는 잠정 값들.
enum ReclassificationRunState {
    static let previewing = "previewing"
    static let applied = "applied"
    static let cancelled = "cancelled"
    static let failed = "failed"
}

enum ReclassificationItemState {
    static let pending = "pending"
    static let applied = "applied"
    static let skipped = "skipped"
}
