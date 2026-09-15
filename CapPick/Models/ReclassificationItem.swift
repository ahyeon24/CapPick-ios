// ERD v0.2 §2 ReclassificationItem. 재분류 실행(ReclassificationRun) 안에서 사용자가
// 확인할 개별 추가·제거 예정 항목. `state`의 값 집합은 ERD에 명시되어 있지 않아 String으로 둔다.
struct ReclassificationItem: Equatable {
    let runID: String
    let captureID: String
    var action: ReclassificationAction
    var evidence: String?
    var expectedMembershipRevision: Int?
    var state: String
}

enum ReclassificationAction: String, Codable {
    case add
    case remove
}
