// ERD v0.2 §2 ReclassificationRun. 폴더 생성 시 기존 캡처 적용(initialApply) 또는
// 기준 변경 후 재분류(reclassify) 실행 단위 — 미리보기 기준·소속 버전을 고정해 둔다.
// `state`의 값 집합은 ERD에 명시되어 있지 않아 String으로 둔다.
struct ReclassificationRun: Identifiable, Equatable {
    let id: String
    let folderID: String
    let criteriaVersion: Int
    let membershipRevision: Int
    var mode: ReclassificationMode
    var state: String
}

enum ReclassificationMode: String, Codable {
    case initialApply = "initial_apply"
    case reclassify
}
