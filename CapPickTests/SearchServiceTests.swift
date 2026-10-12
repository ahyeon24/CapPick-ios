import XCTest
@testable import CapPick

final class SearchServiceTests: XCTestCase {
    private var captureStore: GRDBCaptureStore!
    private var embedder: FakeTextEmbedder!
    private var service: SearchService!

    override func setUp() async throws {
        captureStore = GRDBCaptureStore(database: try AppDatabase.makeInMemory())
        embedder = FakeTextEmbedder()
        service = SearchService(embedder: embedder, captureStore: captureStore)
    }

    private func saveAnalyzedCapture(
        _ id: String, capturedAt: Date = Date(timeIntervalSince1970: 1_000), ocrText: String = "",
        searchText: String = "", embedding: [Double] = [], embeddingModelVersion: String = "fake-embed-v1"
    ) async throws {
        try await captureStore.save(Capture(
            id: id, photoAssetID: "asset-\(id)", capturedAt: capturedAt,
            width: 100, height: 200, availability: .accessible, excludedAt: nil, favorite: false,
            contentRevision: 1, searchState: .ready, classificationState: .complete))
        try await captureStore.saveAnalysis(
            CaptureAnalysis(
                captureID: id, contentRevision: 1, analysisRevision: 1,
                ocrText: ocrText, observedEvidence: [], modelVersion: "m1"),
            searchDocument: SearchDocument(
                captureID: id, sourceAnalysisRevision: 1, searchText: searchText,
                embedding: embedding, embeddingModelVersion: embeddingModelVersion, state: "ready"))
    }

    func testReturnsEmptyWithoutEmbeddingQueryWhenNothingIsAnalyzed() async throws {
        let results = try await service.search(query: "면접", folderID: nil)

        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(embedder.embedCalls.isEmpty)
    }

    func testKeywordSearchUsesWhitespaceSeparatedTermsOfTheQuery() async throws {
        try await saveAnalyzedCapture("interview", ocrText: "자바 면접 예상 질문")
        try await saveAnalyzedCapture("other", ocrText: "파스타 맛집")

        let results = try await service.search(query: "자바 면접", folderID: nil)

        XCTAssertEqual(results.map(\.id), ["interview"])
    }

    func testSemanticMatchIsFoundThroughOnDeviceQueryEmbedding() async throws {
        try await saveAnalyzedCapture("saju", ocrText: "용신 대운", searchText: "사주 풀이", embedding: [1, 0])
        try await saveAnalyzedCapture("pasta", ocrText: "메뉴판", searchText: "파스타 맛집", embedding: [0, 1])
        embedder.vectorsByText["운세"] = [1, 0]

        let results = try await service.search(query: "운세", folderID: nil)

        XCTAssertEqual(results.map(\.id), ["saju"])
        XCTAssertEqual(embedder.embedCalls.last?.kind, .query)
    }

    func testRelativeDatePhraseNarrowsCandidatesAndIsRemovedFromKeywords() async throws {
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: Date())!
        let longAgo = calendar.date(byAdding: .year, value: -2, to: Date())!
        try await saveAnalyzedCapture("recent", capturedAt: yesterday, ocrText: "면접 질문")
        try await saveAnalyzedCapture("old", capturedAt: longAgo, ocrText: "면접 질문")

        let results = try await service.search(query: "어제 면접", folderID: nil)

        XCTAssertEqual(results.map(\.id), ["recent"])
        // "어제"가 키워드로 남았다면 matchRatio는 달라져도 결과 목록은 같다 — 벡터 쪽 입력으로 확인한다.
        XCTAssertEqual(embedder.embedCalls.last?.text, "면접")
    }

    func testDateOnlyQueryReturnsEverythingInThatPeriodNewestFirst() async throws {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let yesterdayMorning = calendar.date(byAdding: .hour, value: -15, to: startOfToday)!
        let yesterdayEvening = calendar.date(byAdding: .hour, value: -3, to: startOfToday)!
        try await saveAnalyzedCapture("morning", capturedAt: yesterdayMorning, ocrText: "아무 글자")
        try await saveAnalyzedCapture("evening", capturedAt: yesterdayEvening, ocrText: "다른 글자")
        try await saveAnalyzedCapture("today", capturedAt: Date(), ocrText: "오늘 것")

        let results = try await service.search(query: "어제", folderID: nil)

        XCTAssertEqual(results.map(\.id), ["evening", "morning"])
        XCTAssertTrue(embedder.embedCalls.isEmpty)
    }

    func testVectorsFromAnotherModelAreRebuiltOnDeviceBeforeSearching() async throws {
        try await saveAnalyzedCapture(
            "legacy", ocrText: "용신 대운", searchText: "사주 풀이", embedding: [0.1, 0.2, 0.3],
            embeddingModelVersion: "gemini-embedding-001")
        embedder.vectorsByText["사주 풀이"] = [1, 0]
        embedder.vectorsByText["운세"] = [1, 0]

        let results = try await service.search(query: "운세", folderID: nil)

        XCTAssertEqual(results.map(\.id), ["legacy"])
        XCTAssertEqual(embedder.embedCalls.first?.text, "사주 풀이")
        XCTAssertEqual(embedder.embedCalls.first?.kind, .passage)
        let stale = try await captureStore.fetchStaleSearchTexts(currentModelVersion: embedder.modelVersion)
        XCTAssertTrue(stale.isEmpty)
    }

    /// 가짜가 아니라 번들된 실제 모델로 끝까지 돌린다 — 색인(passage)·검색어(query) 벡터가 실제로
    /// 같은 공간에서 비교되는지 확인하는 유일한 테스트다.
    func testRealOnDeviceModelRanksSemanticallyRelatedCaptureFirst() async throws {
        let realEmbedder = OnnxEmbeddingService()
        let realService = SearchService(embedder: realEmbedder, captureStore: captureStore)
        // 일부러 예전 버전으로 저장해서, 검색 직전에 실제 모델로 벡터가 다시 만들어지는 경로까지 태운다.
        try await saveAnalyzedCapture(
            "pasta", ocrText: "메뉴 가격 예약", searchText: "성수동 파스타 맛집 메뉴판 화면",
            embedding: [0.1], embeddingModelVersion: "gemini-embedding-001")
        try await saveAnalyzedCapture(
            "saju", ocrText: "용신 대운 연운", searchText: "사주 풀이와 신살 정보가 담긴 사주 명식표 화면",
            embedding: [0.1], embeddingModelVersion: "gemini-embedding-001")
        try await saveAnalyzedCapture(
            "router", ocrText: "Router#configure terminal", searchText: "네트워크 라우터 설정 명령어 CLI 화면",
            embedding: [0.1], embeddingModelVersion: "gemini-embedding-001")

        let results = try await realService.search(query: "오늘의 운세", folderID: nil)

        XCTAssertEqual(results.first?.id, "saju")
        let candidates = try await captureStore.fetchSearchCandidates(capturedFrom: nil, capturedBefore: nil, folderID: nil)
        XCTAssertEqual(Set(candidates.map(\.embedding.count)), [384])
    }
}
