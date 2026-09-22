import XCTest
@testable import CapPick

@MainActor
final class BrowseViewModelTests: XCTestCase {

    private func makeAnalysisQueueService(captureStore: GRDBCaptureStore, database: AppDatabase) throws -> AnalysisQueueService {
        let credentialStore = InMemoryCredentialStore()
        try credentialStore.save("existing-credential")
        let registrar = InstallationRegistrar(
            apiClient: FakeInstallationAPIClient(),
            attestationProvider: FakeAttestationProvider(),
            credentialStore: credentialStore
        )
        let contentAnalysisService = ContentAnalysisService(
            jobAPIClient: FakeJobAPIClient(), installationRegistrar: registrar,
            captureStore: captureStore, imageProvider: FakeCaptureImageProviding()
        )
        return AnalysisQueueService(
            captureStore: captureStore, contentAnalysisService: contentAnalysisService,
            appStateStore: GRDBAppStateStore(database: database)
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
            captureStore: store, analysisQueueService: try makeAnalysisQueueService(captureStore: store, database: database))

        await viewModel.load()

        // 미분석(pending) 캡처도 보여야 한다 — SEARCH-06: 빈 검색어는 미분석 이미지도 탐색 가능.
        XCTAssertEqual(viewModel.captures.map(\.id), ["new", "old"])
        XCTAssertNil(viewModel.errorMessage)
    }

    func testLoadWithNoCapturesLeavesEmptyListWithoutError() async throws {
        let database = try AppDatabase.makeInMemory()
        let store = GRDBCaptureStore(database: database)
        let viewModel = BrowseViewModel(
            captureStore: store, analysisQueueService: try makeAnalysisQueueService(captureStore: store, database: database))

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
            captureStore: store, analysisQueueService: try makeAnalysisQueueService(captureStore: store, database: database))
        await viewModel.load()
        XCTAssertEqual(viewModel.captures.first?.searchState, .failed)

        await viewModel.retry(capture)

        XCTAssertEqual(viewModel.captures.first?.searchState, .ready)
        XCTAssertTrue(viewModel.analyzingCaptureIDs.isEmpty, "완료 후엔 분석 중 표시가 남지 않아야 한다")
    }
}
