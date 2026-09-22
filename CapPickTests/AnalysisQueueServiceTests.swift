import XCTest
@testable import CapPick

final class AnalysisQueueServiceTests: XCTestCase {
    private var captureStore: GRDBCaptureStore!
    private var jobAPIClient: FakeJobAPIClient!
    private var appStateStore: GRDBAppStateStore!
    private var queue: AnalysisQueueService!

    override func setUp() async throws {
        let database = try AppDatabase.makeInMemory()
        captureStore = GRDBCaptureStore(database: database)
        appStateStore = GRDBAppStateStore(database: database)
        jobAPIClient = FakeJobAPIClient()

        let credentialStore = InMemoryCredentialStore()
        try credentialStore.save("existing-credential") // ensureRegistered()가 API를 안 타게
        let registrar = InstallationRegistrar(
            apiClient: FakeInstallationAPIClient(),
            attestationProvider: FakeAttestationProvider(),
            credentialStore: credentialStore
        )
        let contentAnalysisService = ContentAnalysisService(
            jobAPIClient: jobAPIClient, installationRegistrar: registrar,
            captureStore: captureStore, imageProvider: FakeCaptureImageProviding()
        )
        queue = AnalysisQueueService(
            captureStore: captureStore, contentAnalysisService: contentAnalysisService,
            appStateStore: appStateStore
        )
    }

    private func makeCapture(_ id: String, capturedAt: TimeInterval, searchState: SearchState = .pending) -> Capture {
        Capture(
            id: id, photoAssetID: "asset-\(id)", capturedAt: Date(timeIntervalSince1970: capturedAt),
            width: 100, height: 200, availability: .accessible, excludedAt: nil, favorite: false,
            contentRevision: 1, searchState: searchState, classificationState: .pending
        )
    }

    private func succeedingSubmitAndStatus(for id: String) {
        jobAPIClient.submitResultsByReference[id] = .success(
            JobSubmitted(jobId: "job-\(id)", status: .queued, pollAfterSeconds: 0))
        jobAPIClient.statusResultsByJobId["job-\(id)"] = [
            .success(JobStatusResult(
                jobId: "job-\(id)", status: .succeeded, clientReference: id,
                result: ContentAnalysisResultDTO(
                    analysisRevision: 1, ocrText: "", observedEvidence: [], searchText: "s",
                    embedding: [], embeddingModelVersion: "v1"),
                resultExpiresAt: nil, error: nil))
        ]
    }

    private func failingSubmitAndStatus(for id: String) {
        jobAPIClient.submitResultsByReference[id] = .success(
            JobSubmitted(jobId: "job-\(id)", status: .queued, pollAfterSeconds: 0))
        jobAPIClient.statusResultsByJobId["job-\(id)"] = [
            .success(JobStatusResult(
                jobId: "job-\(id)", status: .failed, clientReference: id, result: nil,
                resultExpiresAt: nil, error: JobErrorDTO(code: "X", message: "실패", retryable: true)))
        ]
    }

    func testResumeIfNeededProcessesPendingCapturesNewestFirst() async throws {
        try await captureStore.save(makeCapture("older", capturedAt: 1_000))
        try await captureStore.save(makeCapture("newer", capturedAt: 2_000))
        succeedingSubmitAndStatus(for: "older")
        succeedingSubmitAndStatus(for: "newer")
        try await appStateStore.setValue("true", for: AppStateKey.analysisStartRequested)

        await queue.resumeIfNeeded()

        // 최근 것부터 처리됐는지는 submit 호출 순서로 확인한다.
        XCTAssertEqual(jobAPIClient.submitCalls.map(\.clientReference), ["newer", "older"])
        let states = Dictionary(uniqueKeysWithValues: try await captureStore.fetchAll().map { ($0.id, $0.searchState) })
        XCTAssertEqual(states["older"], .ready)
        XCTAssertEqual(states["newer"], .ready)
    }

    func testResumeIfNeededDoesNothingWhenAnalysisNotRequested() async throws {
        try await captureStore.save(makeCapture("c1", capturedAt: 1_000))
        // analysisStartRequested를 설정하지 않음 — 기본 nil.

        await queue.resumeIfNeeded()

        XCTAssertEqual(jobAPIClient.submitCalls.count, 0)
        let state = try await captureStore.fetchAll().first?.searchState
        XCTAssertEqual(state, .pending)
    }

    func testFailedCaptureIsSkippedNotRetriedForeverAndQueueContinues() async throws {
        try await captureStore.save(makeCapture("bad", capturedAt: 1_000))
        try await captureStore.save(makeCapture("good", capturedAt: 2_000))
        failingSubmitAndStatus(for: "bad")
        succeedingSubmitAndStatus(for: "good")
        try await appStateStore.setValue("true", for: AppStateKey.analysisStartRequested)

        await queue.resumeIfNeeded()

        // 실패한 캡처 때문에 같은 실행에서 멈추거나 무한 반복하지 않고 다음 캡처로 넘어간다.
        XCTAssertEqual(jobAPIClient.submitCalls.map(\.clientReference), ["good", "bad"])
        let states = Dictionary(uniqueKeysWithValues: try await captureStore.fetchAll().map { ($0.id, $0.searchState) })
        XCTAssertEqual(states["bad"], .failed)
        XCTAssertEqual(states["good"], .ready)
    }

    func testResumeIfNeededResetsStuckProcessingBeforeRunning() async throws {
        try await captureStore.save(makeCapture("stuck", capturedAt: 1_000, searchState: .processing))
        succeedingSubmitAndStatus(for: "stuck")
        try await appStateStore.setValue("true", for: AppStateKey.analysisStartRequested)

        await queue.resumeIfNeeded()

        XCTAssertEqual(jobAPIClient.submitCalls.map(\.clientReference), ["stuck"])
        let state = try await captureStore.fetchAll().first?.searchState
        XCTAssertEqual(state, .ready)
    }

    func testRetrySucceedsAndMarksReady() async throws {
        let capture = makeCapture("c1", capturedAt: 1_000, searchState: .failed)
        try await captureStore.save(capture)
        succeedingSubmitAndStatus(for: "c1")

        try await queue.retry(capture)

        let state = try await captureStore.fetchAll().first?.searchState
        XCTAssertEqual(state, .ready)
    }

    func testRetryThrowsAndKeepsFailedOnRepeatedFailure() async throws {
        let capture = makeCapture("c1", capturedAt: 1_000, searchState: .failed)
        try await captureStore.save(capture)
        failingSubmitAndStatus(for: "c1")

        do {
            try await queue.retry(capture)
            XCTFail("expected the underlying job failure to propagate")
        } catch ContentAnalysisError.jobFailed(let code) {
            XCTAssertEqual(code, "X")
        }
        let state = try await captureStore.fetchAll().first?.searchState
        XCTAssertEqual(state, .failed)
    }
}
