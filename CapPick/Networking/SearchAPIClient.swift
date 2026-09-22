import Foundation

// API 명세 §6. Job이 아니다 — 큐잉·폴링 없는 동기 요청/응답 하나로 끝난다(서버
// CapPick-server/CLAUDE.md "검색어 해석" 절과 짝). 실제 캡처 검색(키워드·의미 결합)은 여기서
// 안 하고 Services/SearchService가 이 결과를 가지고 로컬 DB에서 한다.
protocol SearchAPIClient: Sendable {
    func prepare(
        query: String, now: Date, timezone: TimeZone, embeddingModelVersion: String, credential: String
    ) async throws -> SearchPrepared
}

struct SearchPrepared: Equatable, Sendable {
    let normalizedQuery: String
    let lexicalTerms: [String]
    let embedding: [Double]
    let embeddingModelVersion: String
    /// 시작 포함, 끝 미포함. 질의에 날짜 조건이 없으면 둘 다 nil(API 명세 §6).
    let capturedFrom: Date?
    let capturedBefore: Date?
    let dateInterpretation: String?
}
