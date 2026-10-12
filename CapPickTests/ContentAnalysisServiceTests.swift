import XCTest
@testable import CapPick

final class ContentAnalysisServiceTests: XCTestCase {
    private var captureStore: GRDBCaptureStore!
    private var jobAPIClient: FakeJobAPIClient!
    private var imageProvider: FakeCaptureImageProviding!
    private var textRecognizer: FakeTextRecognizer!
    private var embedder: FakeTextEmbedder!
    private var registrar: InstallationRegistrar!
    private var service: ContentAnalysisService!

    private let capture = Capture(
        id: "capture-1", photoAssetID: "asset-1", capturedAt: Date(timeIntervalSince1970: 1_000),
        width: 100, height: 200, availability: .accessible, excludedAt: nil, favorite: false,
        contentRevision: 3, searchState: .pending, classificationState: .pending
    )

    override func setUp() async throws {
        captureStore = GRDBCaptureStore(database: try AppDatabase.makeInMemory())
        try await captureStore.save(capture)

        jobAPIClient = FakeJobAPIClient()
        imageProvider = FakeCaptureImageProviding()
        textRecognizer = FakeTextRecognizer()
        embedder = FakeTextEmbedder()

        let credentialStore = InMemoryCredentialStore()
        try credentialStore.save("existing-credential") // ensureRegistered()가 API를 안 타게
        registrar = InstallationRegistrar(
            apiClient: FakeInstallationAPIClient(),
            attestationProvider: FakeAttestationProvider(),
            credentialStore: credentialStore
        )

        service = ContentAnalysisService(
            jobAPIClient: jobAPIClient, installationRegistrar: registrar,
            captureStore: captureStore, imageProvider: imageProvider, textRecognizer: textRecognizer,
            embedder: embedder
        )
    }

    func testAnalyzeSubmitsWithStableIdempotencyKeyAndSavesResultOnSuccess() async throws {
        try await service.analyze(capture)

        XCTAssertEqual(jobAPIClient.submitCalls.count, 1)
        XCTAssertEqual(jobAPIClient.submitCalls[0].clientReference, "capture-1")
        XCTAssertEqual(jobAPIClient.submitCalls[0].contentRevision, 3)
        XCTAssertEqual(jobAPIClient.submitCalls[0].idempotencyKey, "content-analysis-capture-1-r3-a0")

        let saved = try await captureStore.fetchAll().first { $0.id == "capture-1" }
        XCTAssertEqual(saved?.searchState, .ready)
    }

    func testAnalyzeSendsOnDeviceOCRTextAsHint() async throws {
        textRecognizer.textToReturn = "기기에서 읽은 글자"

        try await service.analyze(capture)

        XCTAssertEqual(jobAPIClient.submittedOCRTextHints, ["기기에서 읽은 글자"])
    }

    func testAnalyzeStillSubmitsWithoutHintWhenOnDeviceOCRFindsNothing() async throws {
        textRecognizer.textToReturn = nil

        try await service.analyze(capture)

        XCTAssertEqual(jobAPIClient.submittedOCRTextHints, [nil])
    }

    func testAnalyzeStoresOnDeviceEmbeddingOfSearchTextAsPassage() async throws {
        embedder.vectorsByText["search"] = [0.6, 0.8]

        try await service.analyze(capture)

        XCTAssertEqual(embedder.embedCalls.map(\.text), ["search"])
        XCTAssertEqual(embedder.embedCalls.first?.kind, .passage)
        let candidates = try await captureStore.fetchSearchCandidates(capturedFrom: nil, capturedBefore: nil, folderID: nil)
        XCTAssertEqual(candidates.first?.embedding, [0.6, 0.8])
        let stale = try await captureStore.fetchStaleSearchTexts(currentModelVersion: embedder.modelVersion)
        XCTAssertTrue(stale.isEmpty)
    }

    func testAnalyzeLeavesDocumentStaleWhenEmbeddingFails() async throws {
        // 기본 FakeTextEmbedder는 빈 벡터를 돌려준다 — 벡터 생성 실패와 같은 취급.
        try await service.analyze(capture)

        let stale = try await captureStore.fetchStaleSearchTexts(currentModelVersion: embedder.modelVersion)
        XCTAssertEqual(stale, [StaleSearchText(captureID: "capture-1", searchText: "search")])
    }

    func testAnalyzeThrowsWhenImageUnavailable() async throws {
        imageProvider.dataToReturn = nil

        do {
            try await service.analyze(capture)
            XCTFail("expected imageUnavailable")
        } catch ContentAnalysisError.imageUnavailable {
            // 기대한 대로
        }
        XCTAssertEqual(jobAPIClient.submitCalls.count, 0)
    }

    func testAnalyzePollsThroughRunningBeforeSucceeding() async throws {
        jobAPIClient.statusResults = [
            .success(JobStatusResult(jobId: "job-1", status: .running, clientReference: "c1", result: nil, resultExpiresAt: nil, error: nil)),
            .success(JobStatusResult(
                jobId: "job-1", status: .succeeded, clientReference: "c1",
                result: ContentAnalysisResultDTO(
                    analysisRevision: 3, ocrText: "", observedEvidence: [], searchText: "s"),
                resultExpiresAt: nil, error: nil)),
        ]

        try await service.analyze(capture)

        XCTAssertEqual(jobAPIClient.statusCallCount, 2)
    }

    func testAnalyzeThrowsJobFailedWithServerErrorCode() async throws {
        jobAPIClient.statusResults = [
            .success(JobStatusResult(
                jobId: "job-1", status: .failed, clientReference: "c1", result: nil, resultExpiresAt: nil,
                error: JobErrorDTO(code: "ANALYSIS_FAILED", message: "실패", retryable: true)))
        ]

        do {
            try await service.analyze(capture)
            XCTFail("expected jobFailed")
        } catch ContentAnalysisError.jobFailed(let code) {
            XCTAssertEqual(code, "ANALYSIS_FAILED")
        }

        let saved = try await captureStore.fetchAll().first { $0.id == "capture-1" }
        XCTAssertEqual(saved?.searchState, .pending, "실패하면 searchState를 건드리지 않는다")
    }
}
