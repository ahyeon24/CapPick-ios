import XCTest
@testable import CapPick

@MainActor
final class CaptureDetailViewModelTests: XCTestCase {
    private var database: AppDatabase!
    private var captureStore: GRDBCaptureStore!
    private var folderStore: GRDBFolderStore!

    override func setUpWithError() throws {
        database = try AppDatabase.makeInMemory()
        captureStore = GRDBCaptureStore(database: database)
        folderStore = GRDBFolderStore(database: database)
    }

    private func makeRegistrar() throws -> InstallationRegistrar {
        let credentialStore = InMemoryCredentialStore()
        try credentialStore.save("existing-credential")
        return InstallationRegistrar(
            apiClient: FakeInstallationAPIClient(),
            attestationProvider: FakeAttestationProvider(),
            credentialStore: credentialStore
        )
    }

    private func makeAnalysisQueueService(jobAPIClient: FakeJobAPIClient = FakeJobAPIClient()) throws -> AnalysisQueueService {
        let contentAnalysisService = ContentAnalysisService(
            jobAPIClient: jobAPIClient, installationRegistrar: try makeRegistrar(),
            captureStore: captureStore, imageProvider: FakeCaptureImageProviding()
        )
        return AnalysisQueueService(
            captureStore: captureStore, contentAnalysisService: contentAnalysisService,
            appStateStore: GRDBAppStateStore(database: database)
        )
    }

    private func makeCapture(_ id: String, searchState: SearchState = .ready) -> Capture {
        Capture(
            id: id, photoAssetID: "asset-\(id)", capturedAt: Date(timeIntervalSince1970: 1_000),
            width: 100, height: 200, availability: .accessible, excludedAt: nil, favorite: false,
            contentRevision: 1, searchState: searchState, classificationState: .complete
        )
    }

    private func makeViewModel(capture: Capture, analysisQueueService: AnalysisQueueService? = nil) throws -> CaptureDetailViewModel {
        CaptureDetailViewModel(
            capture: capture, captureStore: captureStore, folderStore: folderStore,
            analysisQueueService: try analysisQueueService ?? makeAnalysisQueueService(),
            thumbnailLoader: FakeThumbnailLoading()
        )
    }

    func testLoadPopulatesFoldersAndRefreshesCapture() async throws {
        let capture = makeCapture("c1")
        try await captureStore.save(capture)
        try await folderStore.save(Folder(id: "f1", displayName: "면접 준비", criteriaText: nil, criteriaVersion: 1, criteriaState: .pending, membershipRevision: 0))
        try await folderStore.addManually(captureID: "c1", to: "f1")
        let viewModel = try makeViewModel(capture: capture)

        await viewModel.load()

        XCTAssertEqual(viewModel.folders.map(\.displayName), ["면접 준비"])
        XCTAssertEqual(viewModel.capture.searchState, .ready)
    }

    func testLoadWithNoFolderMembershipLeavesFoldersEmpty() async throws {
        let capture = makeCapture("c1", searchState: .pending)
        try await captureStore.save(capture)
        let viewModel = try makeViewModel(capture: capture)

        await viewModel.load()

        XCTAssertTrue(viewModel.folders.isEmpty)
    }

    func testToggleFavoriteUpdatesStoreAndLocalState() async throws {
        let capture = makeCapture("c1")
        try await captureStore.save(capture)
        let viewModel = try makeViewModel(capture: capture)
        XCTAssertFalse(viewModel.capture.favorite)

        await viewModel.toggleFavorite()

        XCTAssertTrue(viewModel.capture.favorite)
        let saved = try await captureStore.fetchCapture(id: "c1")
        XCTAssertEqual(saved?.favorite, true)
    }

    func testRetrySucceedsAndReloadsCaptureAsReady() async throws {
        let capture = makeCapture("c1", searchState: .failed)
        try await captureStore.save(capture)
        let jobAPIClient = FakeJobAPIClient()
        jobAPIClient.submitResultsByReference["c1"] = .success(
            JobSubmitted(jobId: "job-c1", status: .queued, pollAfterSeconds: 0))
        jobAPIClient.statusResultsByJobId["job-c1"] = [
            .success(JobStatusResult(
                jobId: "job-c1", status: .succeeded, clientReference: "c1",
                result: ContentAnalysisResultDTO(
                    analysisRevision: 1, ocrText: "글자", observedEvidence: [], searchText: "s",
                    embedding: [], embeddingModelVersion: "v1"),
                resultExpiresAt: nil, error: nil))
        ]
        let viewModel = try makeViewModel(capture: capture, analysisQueueService: try makeAnalysisQueueService(jobAPIClient: jobAPIClient))

        await viewModel.retry()

        XCTAssertEqual(viewModel.capture.searchState, .ready)
        XCTAssertFalse(viewModel.isRetrying)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testExcludeSetsDidExcludeAndPersistsExcludedAt() async throws {
        let capture = makeCapture("c1")
        try await captureStore.save(capture)
        let viewModel = try makeViewModel(capture: capture)

        await viewModel.exclude()

        XCTAssertTrue(viewModel.didExclude)
        let saved = try await captureStore.fetchCapture(id: "c1")
        XCTAssertNotNil(saved?.excludedAt)
    }
}
