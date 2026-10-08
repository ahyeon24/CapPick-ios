import XCTest
@testable import CapPick

final class SearchRankingTests: XCTestCase {

    private func makeCapture(_ id: String, capturedAt: TimeInterval = 1_000) -> Capture {
        Capture(
            id: id, photoAssetID: "asset-\(id)", capturedAt: Date(timeIntervalSince1970: capturedAt),
            width: 100, height: 200, availability: .accessible, excludedAt: nil, favorite: false,
            contentRevision: 1, searchState: .ready, classificationState: .complete
        )
    }

    func testKeywordOnlyMatchIsIncluded() {
        let candidate = SearchCandidate(
            capture: makeCapture("c1"), ocrText: "면접 질문 목록", searchText: nil, embedding: [])

        let ranked = SearchRanking.rank([candidate], lexicalTerms: ["면접"], queryEmbedding: [])

        XCTAssertEqual(ranked.map(\.id), ["c1"])
    }

    func testKeywordSplitAcrossLineBreakStillMatches() {
        // 기기 OCR이 줄바꿈된 단어를 줄 단위로 끊어서 돌려주는 경우.
        let candidate = SearchCandidate(
            capture: makeCapture("c1"), ocrText: "해당 인터페이스 설정 모드로 진\n입", searchText: nil, embedding: [])

        let ranked = SearchRanking.rank([candidate], lexicalTerms: ["진입"], queryEmbedding: [])

        XCTAssertEqual(ranked.map(\.id), ["c1"])
    }

    func testVectorOnlyMatchIsIncludedWhenNoKeywordOverlap() {
        let candidate = SearchCandidate(
            capture: makeCapture("c1"), ocrText: "관련 없는 글자", searchText: nil, embedding: [1, 0, 0])

        let ranked = SearchRanking.rank([candidate], lexicalTerms: ["전혀다른단어"], queryEmbedding: [1, 0, 0])

        XCTAssertEqual(ranked.map(\.id), ["c1"], "코사인 유사도 1.0이면 키워드가 안 겹쳐도 후보에 포함돼야 한다")
    }

    func testUnrelatedCandidateIsExcluded() {
        let candidate = SearchCandidate(
            capture: makeCapture("c1"), ocrText: "전혀 상관없는 내용", searchText: nil, embedding: [0, 1, 0])

        let ranked = SearchRanking.rank([candidate], lexicalTerms: ["면접"], queryEmbedding: [1, 0, 0])

        XCTAssertTrue(ranked.isEmpty)
    }

    func testCandidateMatchingBothKeywordAndVectorRanksAboveKeywordOnly() {
        let both = SearchCandidate(
            capture: makeCapture("both"), ocrText: "면접 준비 자료", searchText: nil, embedding: [1, 0, 0])
        let keywordOnly = SearchCandidate(
            capture: makeCapture("keywordOnly"), ocrText: "면접 후기", searchText: nil, embedding: [0, 1, 0])

        let ranked = SearchRanking.rank(
            [keywordOnly, both], lexicalTerms: ["면접"], queryEmbedding: [1, 0, 0])

        XCTAssertEqual(ranked.map(\.id), ["both", "keywordOnly"])
    }

    func testSearchTextIsAlsoSearchedNotJustOcrText() {
        let candidate = SearchCandidate(
            capture: makeCapture("c1"), ocrText: nil, searchText: "알고리즘 실습 자료", embedding: [])

        let ranked = SearchRanking.rank([candidate], lexicalTerms: ["알고리즘"], queryEmbedding: [])

        XCTAssertEqual(ranked.map(\.id), ["c1"])
    }
}
