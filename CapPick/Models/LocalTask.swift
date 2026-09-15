import Foundation

// ERD v0.2 §2·§3 LocalTask. 서버 제출 전부터 기록하는 단계별 처리·복구 기록.
// idempotencyKey는 같은 논리 작업을 재개할 때 동일하게 유지한다.
struct LocalTask: Identifiable, Equatable {
    let id: String
    var captureID: String?
    var folderID: String?
    var kind: LocalTaskKind
    var inputRevision: Int
    var criteriaVersion: Int?
    var serverJobID: String?
    let idempotencyKey: String
    var state: LocalTaskState
    var attempts: Int
    var errorCode: String?
    var nextRetryAt: Date?
}

// API 명세 §4 Job kind와 동일한 값 — 서버에 Job으로 제출될 때 이 값을 그대로 쓴다.
enum LocalTaskKind: String, Codable {
    case contentAnalysis = "content_analysis"
    case folderCriteria = "folder_criteria"
    case classification
    case searchDocument = "search_document"
}

enum LocalTaskState: String, Codable {
    case pending
    case submitted
    case processing
    case succeeded
    case failed
    case waitingLimit = "waiting_limit"
    case discarded
}
