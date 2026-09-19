import Foundation

// ERD v0.2 §2 SearchDocument. `state`의 구체적인 값 집합은 ERD에 명시되어 있지 않다 —
// 검색 모델·분석 버전 교체 시 "오래된 결과를 반영하지 않는다"(시스템 설계 §6)는 요구만
// 확인됨. 값이 확정되면 String 대신 enum으로 교체한다.
struct SearchDocument: Equatable, Codable {
    let captureID: String
    let sourceAnalysisRevision: Int
    let searchText: String
    let embedding: [Double]
    let embeddingModelVersion: String
    var state: String
}
