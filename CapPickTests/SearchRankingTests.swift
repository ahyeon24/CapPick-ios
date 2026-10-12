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

    func testCandidateMatchingMoreQueryTermsRanksAbovePartialMatch() {
        let partial = SearchCandidate(
            capture: makeCapture("partial"), ocrText: "면접 후기", searchText: nil, embedding: [])
        let full = SearchCandidate(
            capture: makeCapture("full"), ocrText: "자바 면접 예상 질문", searchText: nil, embedding: [])

        let ranked = SearchRanking.rank([partial, full], lexicalTerms: ["자바", "면접"], queryEmbedding: [])

        XCTAssertEqual(ranked.map(\.id), ["full", "partial"])
    }

    func testEmbeddingFromDifferentModelDimensionIsIgnored() {
        // 예전 서버 임베딩(차원이 다름)이 남아 있는 캡처는 벡터 순위에 끼지 못한다.
        let candidate = SearchCandidate(
            capture: makeCapture("c1"), ocrText: "관련 없는 글자", searchText: nil, embedding: [1, 0, 0, 0])

        let ranked = SearchRanking.rank([candidate], lexicalTerms: ["면접"], queryEmbedding: [1, 0, 0])

        XCTAssertTrue(ranked.isEmpty)
    }

    func testEqualScoresKeepInputOrder() {
        let newer = SearchCandidate(capture: makeCapture("newer"), ocrText: "면접", searchText: nil, embedding: [])
        let older = SearchCandidate(capture: makeCapture("older"), ocrText: "면접", searchText: nil, embedding: [])

        // 둘 다 같은 토큰 수가 일치 — 순위는 들어온 순서(최근 먼저)대로여야 한다.
        let ranked = SearchRanking.rank([newer, older], lexicalTerms: ["면접"], queryEmbedding: [])

        XCTAssertEqual(ranked.map(\.id), ["newer", "older"])
    }

    // MARK: - 결과에 넣는 기준 (1위와의 유사도 차이)

    /// 길이 1인 2차원 벡터 — 검색어 벡터 [1, 0]과의 코사인 유사도가 정확히 `similarity`가 된다.
    private func vector(similarity: Double) -> [Double] {
        [similarity, (1 - similarity * similarity).squareRoot()]
    }

    func testSemanticOnlyCandidatesFarBelowTheBestAreLeftOut() {
        let best = SearchCandidate(capture: makeCapture("best"), ocrText: nil, searchText: nil, embedding: vector(similarity: 0.83))
        let close = SearchCandidate(capture: makeCapture("close"), ocrText: nil, searchText: nil, embedding: vector(similarity: 0.815))
        let far = SearchCandidate(capture: makeCapture("far"), ocrText: nil, searchText: nil, embedding: vector(similarity: 0.79))

        let ranked = SearchRanking.rank([far, close, best], lexicalTerms: ["운세"], queryEmbedding: [1, 0])

        XCTAssertEqual(ranked.map(\.id), ["best", "close"])
    }

    func testKeywordMatchIsAlwaysIncludedEvenWhenFarBelowTheBestSimilarity() {
        let best = SearchCandidate(capture: makeCapture("best"), ocrText: "다른 글자", searchText: nil, embedding: vector(similarity: 0.85))
        let keyword = SearchCandidate(capture: makeCapture("keyword"), ocrText: "포트 활성화", searchText: nil, embedding: vector(similarity: 0.70))

        let ranked = SearchRanking.rank([best, keyword], lexicalTerms: ["포트"], queryEmbedding: [1, 0])

        XCTAssertEqual(Set(ranked.map(\.id)), ["best", "keyword"])
    }

    func testSemanticOnlyResultsAreCappedButKeywordMatchesAreNot() {
        // 유사도가 전부 같아서 1위와의 차이 기준을 모두 통과하는 상황(관련 캡처가 없는 검색어).
        let semantic = (0..<(SearchRanking.semanticOnlyLimit + 10)).map {
            SearchCandidate(capture: makeCapture("s\($0)"), ocrText: nil, searchText: nil, embedding: [1, 0])
        }
        let keyword = SearchCandidate(capture: makeCapture("keyword"), ocrText: "면접", searchText: nil, embedding: [])

        let ranked = SearchRanking.rank(semantic + [keyword], lexicalTerms: ["면접"], queryEmbedding: [1, 0])

        XCTAssertEqual(ranked.count, SearchRanking.semanticOnlyLimit + 1)
        XCTAssertTrue(ranked.contains { $0.id == "keyword" })
    }

    func testObservedEvidenceIsSearchedForKeywords() {
        let candidate = SearchCandidate(
            capture: makeCapture("c1"), ocrText: "O'REILLY AI 시대의 엔지니어링 전략", searchText: "도서 광고",
            observedEvidence: ["오터(수달) 이미지가 포함된 책 표지임."], embedding: [])

        let ranked = SearchRanking.rank([candidate], lexicalTerms: ["수달"], queryEmbedding: [])

        XCTAssertEqual(ranked.map(\.id), ["c1"])
    }

    func testSearchTextIsAlsoSearchedNotJustOcrText() {
        let candidate = SearchCandidate(
            capture: makeCapture("c1"), ocrText: nil, searchText: "알고리즘 실습 자료", embedding: [])

        let ranked = SearchRanking.rank([candidate], lexicalTerms: ["알고리즘"], queryEmbedding: [])

        XCTAssertEqual(ranked.map(\.id), ["c1"])
    }
}
