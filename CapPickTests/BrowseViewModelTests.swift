import XCTest
@testable import CapPick

@MainActor
final class BrowseViewModelTests: XCTestCase {

    private func makeRegistrar() throws -> InstallationRegistrar {
        let credentialStore = InMemoryCredentialStore()
        try credentialStore.save("existing-credential")
        return InstallationRegistrar(
            apiClient: FakeInstallationAPIClient(),
            attestationProvider: FakeAttestationProvider(),
            credentialStore: credentialStore
        )
    }

    private func makeAnalysisQueueService(captureStore: GRDBCaptureStore, database: AppDatabase) throws -> AnalysisQueueService {
        let contentAnalysisService = ContentAnalysisService(
            jobAPIClient: FakeJobAPIClient(), installationRegistrar: try makeRegistrar(),
            captureStore: captureStore, imageProvider: FakeCaptureImageProviding()
        )
        return AnalysisQueueService(
            captureStore: captureStore, contentAnalysisService: contentAnalysisService,
            appStateStore: GRDBAppStateStore(database: database)
        )
    }

    private func makeSearchService(
        captureStore: GRDBCaptureStore, searchAPIClient: FakeSearchAPIClient = FakeSearchAPIClient()
    ) throws -> SearchService {
        SearchService(searchAPIClient: searchAPIClient, installationRegistrar: try makeRegistrar(), captureStore: captureStore)
    }

    private func saveAnalysis(
        store: GRDBCaptureStore, captureID: String, ocrText: String = "", embedding: [Double] = []
    ) async throws {
        try await store.saveAnalysis(
            CaptureAnalysis(
                captureID: captureID, contentRevision: 1, analysisRevision: 1,
                ocrText: ocrText, observedEvidence: [], modelVersion: "m1"),
            searchDocument: SearchDocument(
                captureID: captureID, sourceAnalysisRevision: 1, searchText: ocrText,
                embedding: embedding, embeddingModelVersion: "v1", state: "ready")
        )
    }

    func testLoadShowsAllVisibleCapturesNewestFirst() async throws {
        let database = try AppDatabase.makeInMemory()
        let store = GRDBCaptureStore(database: database)
        try await store.save(Capture(
            id: "old", photoAssetID: "a", capturedAt: Date(timeIntervalSince1970: 1_000),
            width: 100, height: 200, availability: .accessible, excludedAt: nil, favorite: false,
            contentRevision: 1, searchState: .pending, classificationState: .pending
        ))
        try await store.save(Capture(
            id: "new", photoAssetID: "b", capturedAt: Date(timeIntervalSince1970: 2_000),
            width: 100, height: 200, availability: .accessible, excludedAt: nil, favorite: false,
            contentRevision: 1, searchState: .ready, classificationState: .complete
        ))
        let viewModel = BrowseViewModel(
            captureStore: store, analysisQueueService: try makeAnalysisQueueService(captureStore: store, database: database),
            searchService: try makeSearchService(captureStore: store))

        await viewModel.load()

        // 미분석(pending) 캡처도 보여야 한다 — SEARCH-06: 빈 검색어는 미분석 이미지도 탐색 가능.
        XCTAssertEqual(viewModel.captures.map(\.id), ["new", "old"])
        XCTAssertNil(viewModel.errorMessage)
    }

    func testLoadWithNoCapturesLeavesEmptyListWithoutError() async throws {
        let database = try AppDatabase.makeInMemory()
        let store = GRDBCaptureStore(database: database)
        let viewModel = BrowseViewModel(
            captureStore: store, analysisQueueService: try makeAnalysisQueueService(captureStore: store, database: database),
            searchService: try makeSearchService(captureStore: store))

        await viewModel.load()

        XCTAssertTrue(viewModel.captures.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testRetryReloadsCapturesSoBadgeReflectsReadyState() async throws {
        let database = try AppDatabase.makeInMemory()
        let store = GRDBCaptureStore(database: database)
        // pending은 자동 큐가 처리하므로 Browse의 수동 재시도는 failed에서만 의미가 있다.
        let capture = Capture(
            id: "c1", photoAssetID: "a", capturedAt: Date(timeIntervalSince1970: 1_000),
            width: 100, height: 200, availability: .accessible, excludedAt: nil, favorite: false,
            contentRevision: 1, searchState: .failed, classificationState: .pending
        )
        try await store.save(capture)
        let viewModel = BrowseViewModel(
            captureStore: store, analysisQueueService: try makeAnalysisQueueService(captureStore: store, database: database),
            searchService: try makeSearchService(captureStore: store))
        await viewModel.load()
        XCTAssertEqual(viewModel.captures.first?.searchState, .failed)

        await viewModel.retry(capture)

        XCTAssertEqual(viewModel.captures.first?.searchState, .ready)
        XCTAssertTrue(viewModel.analyzingCaptureIDs.isEmpty, "완료 후엔 분석 중 표시가 남지 않아야 한다")
    }

    func testSearchReplacesCapturesWithRankedResultsAndMarksSearchActive() async throws {
        let database = try AppDatabase.makeInMemory()
        let store = GRDBCaptureStore(database: database)
        let matching = Capture(
            id: "matching", photoAssetID: "a", capturedAt: Date(timeIntervalSince1970: 1_000),
            width: 100, height: 200, availability: .accessible, excludedAt: nil, favorite: false,
            contentRevision: 1, searchState: .ready, classificationState: .complete
        )
        let unrelated = Capture(
            id: "unrelated", photoAssetID: "b", capturedAt: Date(timeIntervalSince1970: 2_000),
            width: 100, height: 200, availability: .accessible, excludedAt: nil, favorite: false,
            contentRevision: 1, searchState: .ready, classificationState: .complete
        )
        try await store.save(matching)
        try await saveAnalysis(store: store, captureID: "matching", ocrText: "면접 질문 목록")
        try await store.save(unrelated)
        try await saveAnalysis(store: store, captureID: "unrelated", ocrText: "전혀 상관없는 내용")

        let fakeClient = FakeSearchAPIClient()
        fakeClient.resultsByQuery["면접"] = SearchPrepared(
            normalizedQuery: "면접", lexicalTerms: ["면접"], embedding: [],
            embeddingModelVersion: "v1", capturedFrom: nil, capturedBefore: nil, dateInterpretation: nil)
        let viewModel = BrowseViewModel(
            captureStore: store, analysisQueueService: try makeAnalysisQueueService(captureStore: store, database: database),
            searchService: try makeSearchService(captureStore: store, searchAPIClient: fakeClient))
        await viewModel.load()

        viewModel.searchText = "면접"
        await viewModel.search()

        XCTAssertEqual(viewModel.captures.map(\.id), ["matching"])
        XCTAssertTrue(viewModel.isSearchActive)
    }

    func testClearingSearchTextReturnsToFullNewestFirstList() async throws {
        let database = try AppDatabase.makeInMemory()
        let store = GRDBCaptureStore(database: database)
        try await store.save(Capture(
            id: "c1", photoAssetID: "a", capturedAt: Date(timeIntervalSince1970: 1_000),
            width: 100, height: 200, availability: .accessible, excludedAt: nil, favorite: false,
            contentRevision: 1, searchState: .pending, classificationState: .pending
        ))
        let viewModel = BrowseViewModel(
            captureStore: store, analysisQueueService: try makeAnalysisQueueService(captureStore: store, database: database),
            searchService: try makeSearchService(captureStore: store))
        await viewModel.load()
        viewModel.searchText = "아무 검색어"

        await viewModel.clearSearch()

        XCTAssertEqual(viewModel.searchText, "")
        XCTAssertFalse(viewModel.isSearchActive)
        XCTAssertEqual(viewModel.captures.map(\.id), ["c1"])
    }

    func testStaleSearchResultDoesNotOverwriteNewerSearch() async throws {
        let database = try AppDatabase.makeInMemory()
        let store = GRDBCaptureStore(database: database)
        let forOldQuery = Capture(
            id: "forOld", photoAssetID: "a", capturedAt: Date(timeIntervalSince1970: 1_000),
            width: 100, height: 200, availability: .accessible, excludedAt: nil, favorite: false,
            contentRevision: 1, searchState: .ready, classificationState: .complete
        )
        let forNewQuery = Capture(
            id: "forNew", photoAssetID: "b", capturedAt: Date(timeIntervalSince1970: 2_000),
            width: 100, height: 200, availability: .accessible, excludedAt: nil, favorite: false,
            contentRevision: 1, searchState: .ready, classificationState: .complete
        )
        try await store.save(forOldQuery)
        try await saveAnalysis(store: store, captureID: "forOld", ocrText: "old 캡처")
        try await store.save(forNewQuery)
        try await saveAnalysis(store: store, captureID: "forNew", ocrText: "new 캡처")

        let fakeClient = FakeSearchAPIClient()
        // "old query"가 먼저 시작하지만 응답이 늦게 온다 — 그사이 시작한 "new query"가 먼저 끝난다.
        fakeClient.delayByQuery["old query"] = .milliseconds(150)
        fakeClient.resultsByQuery["old query"] = SearchPrepared(
            normalizedQuery: "old query", lexicalTerms: ["old"], embedding: [],
            embeddingModelVersion: "v1", capturedFrom: nil, capturedBefore: nil, dateInterpretation: nil)
        fakeClient.resultsByQuery["new query"] = SearchPrepared(
            normalizedQuery: "new query", lexicalTerms: ["new"], embedding: [],
            embeddingModelVersion: "v1", capturedFrom: nil, capturedBefore: nil, dateInterpretation: nil)

        let viewModel = BrowseViewModel(
            captureStore: store, analysisQueueService: try makeAnalysisQueueService(captureStore: store, database: database),
            searchService: try makeSearchService(captureStore: store, searchAPIClient: fakeClient))

        viewModel.searchText = "old query"
        let staleTask = Task { await viewModel.search() }
        try await Task.sleep(for: .milliseconds(30)) // "old query" 요청이 먼저 등록되도록 잠깐 대기
        viewModel.searchText = "new query"
        await viewModel.search() // 지연이 없어서 바로 끝난다
        _ = await staleTask.value // 뒤늦게 끝나는 "old query" 응답도 처리시킨다

        XCTAssertEqual(viewModel.captures.map(\.id), ["forNew"], "늦게 도착한 이전 검색 결과가 최신 결과를 덮어쓰면 안 된다")
    }
}
