// ERD v0.2 §2 Folder. display_name(표시 이름)과 criteria_text(분류 기준)는 별도로 관리한다 —
// 이름만 바꿔도 criteria_version이 올라가지 않는다 (기능명세서 §3.3.2).
struct Folder: Identifiable, Equatable {
    let id: String
    var displayName: String
    var criteriaText: String?
    var criteriaVersion: Int
    var criteriaState: FolderCriteriaState
    var membershipRevision: Int
}

// ERD §2는 "모호한 기준은 needs_clarification"만 명시한다. 나머지 값(pending, ready)은
// API 명세 §4 folder_criteria job 결과(criteria_state, clarification_message nullable)를
// 참고해 추정한 것 — 서버 계약이 구체화되면 다시 확인해야 한다.
enum FolderCriteriaState: String, Codable {
    case pending
    case ready
    case needsClarification = "needs_clarification"
}
