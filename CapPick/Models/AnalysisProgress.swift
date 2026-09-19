// 화면설계서 §3: 분석 가능한 전체 수, 검색 가능한 수, 분류 대기·실패 수를 혼동시키지 않는다.
// 접근 가능하고 캡픽에서 제외하지 않은 캡처만 센다.
struct AnalysisProgress: Equatable {
    let total: Int
    let searchReady: Int
    let searchPending: Int
    let searchFailed: Int
    let classificationPending: Int
    let classificationFailed: Int
}
