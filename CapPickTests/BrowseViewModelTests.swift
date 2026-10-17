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
        let registrar = try makeRegistrar()
        let contentAnalysisService = ContentAnalysisService(
            jobAPIClient: FakeJobAPIClient(), installationRegistrar: registrar,
            captureStore: captureStore, imageProvider: FakeCaptureImageProviding(),
            textRecognizer: FakeTextRecognizer(), embedder: FakeTextEmbedder()
        )
        let classificationService = ClassificationService(
            classificationAPIClient: FakeClassificationAPIClient(), installationRegistrar: registrar,
            captureStore: captureStore, folderStore: GRDBFolderStore(database: database)
        )
        return AnalysisQueueService(
            captureStore: captureStore, contentAnalysisService: contentAnalysisService,
            classificationService: classificationService, appStateStore: GRDBAppStateStore(database: database)
        )
    }

    private func makeSearchService(
        captureStore: GRDBCaptureStore, embedder: FakeTextEmbedder = FakeTextEmbedder()
    ) throws -> SearchService {
        SearchService(embedder: embedder, captureStore: captureStore)
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
            scope: .all, captureStore: store, folderStore: GRDBFolderStore(database: database), analysisQueueService: try makeAnalysisQueueService(captureStore: store, database: database),
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
            scope: .all, captureStore: store, folderStore: GRDBFolderStore(database: database), analysisQueueService: try makeAnalysisQueueService(captureStore: store, database: database),
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
            scope: .all, captureStore: store, folderStore: GRDBFolderStore(database: database), analysisQueueService: try makeAnalysisQueueService(captureStore: store, database: database),
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

        let fakeEmbedder = FakeTextEmbedder()
        let viewModel = BrowseViewModel(
            scope: .all, captureStore: store, folderStore: GRDBFolderStore(database: database), analysisQueueService: try makeAnalysisQueueService(captureStore: store, database: database),
            searchService: try makeSearchService(captureStore: store, embedder: fakeEmbedder))
        await viewModel.load()

        viewModel.searchText = "면접"
        await viewModel.search()

        XCTAssertEqual(viewModel.captures.map(\.id), ["matching"])
        XCTAssertTrue(viewModel.isSearchActive)
    }

    // HOME-01 상단 검색에서 넘어올 때 쓴다(§2 흐름) — BrowseView.task가 이 값을 보고 곧바로
    // search()를 부른다(load()가 아니라).
    func testInitialQueryPrefillsSearchText() async throws {
        let database = try AppDatabase.makeInMemory()
        let store = GRDBCaptureStore(database: database)
        let viewModel = BrowseViewModel(
            scope: .all, captureStore: store, folderStore: GRDBFolderStore(database: database),
            analysisQueueService: try makeAnalysisQueueService(captureStore: store, database: database),
            searchService: try makeSearchService(captureStore: store), initialQuery: "면접")

        XCTAssertEqual(viewModel.searchText, "면접")
    }

    func testMissingOrBlankInitialQueryLeavesSearchTextEmpty() async throws {
        let database = try AppDatabase.makeInMemory()
        let store = GRDBCaptureStore(database: database)
        let viewModel = BrowseViewModel(
            scope: .all, captureStore: store, folderStore: GRDBFolderStore(database: database),
            analysisQueueService: try makeAnalysisQueueService(captureStore: store, database: database),
            searchService: try makeSearchService(captureStore: store), initialQuery: "   ")

        XCTAssertEqual(viewModel.searchText, "")
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
            scope: .all, captureStore: store, folderStore: GRDBFolderStore(database: database), analysisQueueService: try makeAnalysisQueueService(captureStore: store, database: database),
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

        let fakeEmbedder = FakeTextEmbedder()
        // "old query"가 먼저 시작하지만 응답이 늦게 온다 — 그사이 시작한 "new query"가 먼저 끝난다.
        fakeEmbedder.delayByText["old query"] = .milliseconds(150)

        let viewModel = BrowseViewModel(
            scope: .all, captureStore: store, folderStore: GRDBFolderStore(database: database), analysisQueueService: try makeAnalysisQueueService(captureStore: store, database: database),
            searchService: try makeSearchService(captureStore: store, embedder: fakeEmbedder))

        viewModel.searchText = "old query"
        let staleTask = Task { await viewModel.search() }
        try await Task.sleep(for: .milliseconds(30)) // "old query" 요청이 먼저 등록되도록 잠깐 대기
        viewModel.searchText = "new query"
        await viewModel.search() // 지연이 없어서 바로 끝난다
        _ = await staleTask.value // 뒤늦게 끝나는 "old query" 응답도 처리시킨다

        XCTAssertEqual(viewModel.captures.map(\.id), ["forNew"], "늦게 도착한 이전 검색 결과가 최신 결과를 덮어쓰면 안 된다")
    }

    func testLoadWithUnclassifiedScopeShowsOnlyUnclassifiedCaptures() async throws {
        let database = try AppDatabase.makeInMemory()
        let store = GRDBCaptureStore(database: database)
        let folderStore = GRDBFolderStore(database: database)
        try await store.save(Capture(
            id: "unclassified", photoAssetID: "a", capturedAt: Date(timeIntervalSince1970: 1_000),
            width: 100, height: 200, availability: .accessible, excludedAt: nil, favorite: false,
            contentRevision: 1, searchState: .ready, classificationState: .complete
        ))
        try await store.save(Capture(
            id: "inFolder", photoAssetID: "b", capturedAt: Date(timeIntervalSince1970: 2_000),
            width: 100, height: 200, availability: .accessible, excludedAt: nil, favorite: false,
            contentRevision: 1, searchState: .ready, classificationState: .complete
        ))
        try await folderStore.save(Folder(
            id: "f1", displayName: "폴더", criteriaText: nil, criteriaVersion: 1,
            criteriaState: .pending, membershipRevision: 0))
        try await folderStore.addManually(captureID: "inFolder", to: "f1")

        let viewModel = BrowseViewModel(
            scope: .unclassified, captureStore: store, folderStore: folderStore,
            analysisQueueService: try makeAnalysisQueueService(captureStore: store, database: database),
            searchService: try makeSearchService(captureStore: store))

        await viewModel.load()

        XCTAssertEqual(viewModel.captures.map(\.id), ["unclassified"])
    }

    func testLoadWithFolderScopeShowsOnlyThatFoldersCaptures() async throws {
        let database = try AppDatabase.makeInMemory()
        let store = GRDBCaptureStore(database: database)
        let folderStore = GRDBFolderStore(database: database)
        try await store.save(Capture(
            id: "inFolder", photoAssetID: "a", capturedAt: Date(timeIntervalSince1970: 1_000),
            width: 100, height: 200, availability: .accessible, excludedAt: nil, favorite: false,
            contentRevision: 1, searchState: .ready, classificationState: .complete
        ))
        try await store.save(Capture(
            id: "outside", photoAssetID: "b", capturedAt: Date(timeIntervalSince1970: 2_000),
            width: 100, height: 200, availability: .accessible, excludedAt: nil, favorite: false,
            contentRevision: 1, searchState: .ready, classificationState: .complete
        ))
        let folder = Folder(
            id: "f1", displayName: "폴더", criteriaText: nil, criteriaVersion: 1,
            criteriaState: .pending, membershipRevision: 0)
        try await folderStore.save(folder)
        try await folderStore.addManually(captureID: "inFolder", to: "f1")

        let viewModel = BrowseViewModel(
            scope: .folder(folder), captureStore: store, folderStore: folderStore,
            analysisQueueService: try makeAnalysisQueueService(captureStore: store, database: database),
            searchService: try makeSearchService(captureStore: store))

        await viewModel.load()

        XCTAssertEqual(viewModel.captures.map(\.id), ["inFolder"])
    }

    func testAddToFolderAddsCaptureToFolder() async throws {
        let database = try AppDatabase.makeInMemory()
        let store = GRDBCaptureStore(database: database)
        let folderStore = GRDBFolderStore(database: database)
        let capture = Capture(
            id: "c1", photoAssetID: "a", capturedAt: Date(timeIntervalSince1970: 1_000),
            width: 100, height: 200, availability: .accessible, excludedAt: nil, favorite: false,
            contentRevision: 1, searchState: .ready, classificationState: .complete
        )
        try await store.save(capture)
        try await folderStore.save(Folder(
            id: "f1", displayName: "폴더", criteriaText: nil, criteriaVersion: 1,
            criteriaState: .pending, membershipRevision: 0))
        let viewModel = BrowseViewModel(
            scope: .all, captureStore: store, folderStore: folderStore,
            analysisQueueService: try makeAnalysisQueueService(captureStore: store, database: database),
            searchService: try makeSearchService(captureStore: store))

        await viewModel.addToFolder(capture, folderID: "f1")

        let memberships = try await folderStore.fetchMemberships(of: "f1")
        XCTAssertEqual(memberships.map(\.captureID), ["c1"])
        XCTAssertNil(viewModel.errorMessage)
    }

    func testRemoveFromCurrentFolderRemovesCaptureWhenScopedToFolder() async throws {
        let database = try AppDatabase.makeInMemory()
        let store = GRDBCaptureStore(database: database)
        let folderStore = GRDBFolderStore(database: database)
        let capture = Capture(
            id: "c1", photoAssetID: "a", capturedAt: Date(timeIntervalSince1970: 1_000),
            width: 100, height: 200, availability: .accessible, excludedAt: nil, favorite: false,
            contentRevision: 1, searchState: .ready, classificationState: .complete
        )
        try await store.save(capture)
        let folder = Folder(
            id: "f1", displayName: "폴더", criteriaText: nil, criteriaVersion: 1,
            criteriaState: .pending, membershipRevision: 0)
        try await folderStore.save(folder)
        try await folderStore.addManually(captureID: "c1", to: "f1")
        let viewModel = BrowseViewModel(
            scope: .folder(folder), captureStore: store, folderStore: folderStore,
            analysisQueueService: try makeAnalysisQueueService(captureStore: store, database: database),
            searchService: try makeSearchService(captureStore: store))
        await viewModel.load()
        XCTAssertEqual(viewModel.captures.map(\.id), ["c1"])

        await viewModel.removeFromCurrentFolder(capture)

        XCTAssertTrue(viewModel.captures.isEmpty)
    }

    func testSearchRespectsFolderScope() async throws {
        let database = try AppDatabase.makeInMemory()
        let store = GRDBCaptureStore(database: database)
        let folderStore = GRDBFolderStore(database: database)
        try await store.save(Capture(
            id: "inFolder", photoAssetID: "a", capturedAt: Date(timeIntervalSince1970: 1_000),
            width: 100, height: 200, availability: .accessible, excludedAt: nil, favorite: false,
            contentRevision: 1, searchState: .ready, classificationState: .complete
        ))
        try await saveAnalysis(store: store, captureID: "inFolder", ocrText: "면접 질문")
        try await store.save(Capture(
            id: "outside", photoAssetID: "b", capturedAt: Date(timeIntervalSince1970: 2_000),
            width: 100, height: 200, availability: .accessible, excludedAt: nil, favorite: false,
            contentRevision: 1, searchState: .ready, classificationState: .complete
        ))
        try await saveAnalysis(store: store, captureID: "outside", ocrText: "면접 질문")
        let folder = Folder(
            id: "f1", displayName: "폴더", criteriaText: nil, criteriaVersion: 1,
            criteriaState: .pending, membershipRevision: 0)
        try await folderStore.save(folder)
        try await folderStore.addManually(captureID: "inFolder", to: "f1")

        let fakeEmbedder = FakeTextEmbedder()
        let viewModel = BrowseViewModel(
            scope: .folder(folder), captureStore: store, folderStore: folderStore,
            analysisQueueService: try makeAnalysisQueueService(captureStore: store, database: database),
            searchService: try makeSearchService(captureStore: store, embedder: fakeEmbedder))

        viewModel.searchText = "면접"
        await viewModel.search()

        // "outside"도 키워드는 일치하지만 폴더 범위 밖이라 결과에서 빠져야 한다(SEARCH-04).
        XCTAssertEqual(viewModel.captures.map(\.id), ["inFolder"])
    }

    /// 홈에서 검색해 들어올 때 검색과 목록 읽기가 같이 시작되는 상황 — 늦게 끝난 목록 읽기가
    /// 검색 결과를 전체 목록으로 덮어쓰면 안 된다(2026-10-17 실기기에서 발견).
    func testListLoadFinishingDuringSearchDoesNotOverwriteResults() async throws {
        let database = try AppDatabase.makeInMemory()
        let store = GRDBCaptureStore(database: database)
        for (id, text) in [("matching", "면접 질문 목록"), ("other", "파스타 맛집")] {
            try await store.save(Capture(
                id: id, photoAssetID: "asset-\(id)", capturedAt: Date(timeIntervalSince1970: 1_000),
                width: 100, height: 200, availability: .accessible, excludedAt: nil, favorite: false,
                contentRevision: 1, searchState: .ready, classificationState: .complete))
            try await saveAnalysis(store: store, captureID: id, ocrText: text)
        }
        let slowEmbedder = FakeTextEmbedder()
        slowEmbedder.delayByText["면접"] = .milliseconds(150) // 첫 검색처럼 검색이 늦게 끝난다
        let viewModel = BrowseViewModel(
            scope: .all, captureStore: store, folderStore: GRDBFolderStore(database: database),
            analysisQueueService: try makeAnalysisQueueService(captureStore: store, database: database),
            searchService: try makeSearchService(captureStore: store, embedder: slowEmbedder),
            initialQuery: "면접")

        let searchTask = Task { await viewModel.search() }
        try await Task.sleep(for: .milliseconds(20))
        await viewModel.load() // 검색이 끝나기 전에 목록 읽기가 끝난다
        _ = await searchTask.value

        XCTAssertEqual(viewModel.captures.map(\.id), ["matching"])
    }
}
