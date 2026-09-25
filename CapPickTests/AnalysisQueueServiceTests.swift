import XCTest
@testable import CapPick

final class AnalysisQueueServiceTests: XCTestCase {
    private var captureStore: GRDBCaptureStore!
    private var folderStore: GRDBFolderStore!
    private var jobAPIClient: FakeJobAPIClient!
    private var classificationAPIClient: FakeClassificationAPIClient!
    private var appStateStore: GRDBAppStateStore!
    private var queue: AnalysisQueueService!

    override func setUp() async throws {
        let database = try AppDatabase.makeInMemory()
        captureStore = GRDBCaptureStore(database: database)
        folderStore = GRDBFolderStore(database: database)
        appStateStore = GRDBAppStateStore(database: database)
        jobAPIClient = FakeJobAPIClient()
        classificationAPIClient = FakeClassificationAPIClient()

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
        // 이 테스트 파일의 폴더는 기본적으로 비어있다 — classify()가 비교할 폴더가 없어 곧바로
        // 끝나므로(ClassificationServiceTests가 그 동작 자체는 이미 검증함), 여기서는 별도 스텁
        // 없이도 큐가 끝까지 안전하게 도는지만 확인하면 된다. 분류 자체의 체이닝 동작은 아래
        // testResumeIfNeededChainsClassificationAfterSuccessfulAnalysis가 검증한다.
        let classificationService = ClassificationService(
            classificationAPIClient: classificationAPIClient, installationRegistrar: registrar,
            captureStore: captureStore, folderStore: folderStore
        )
        queue = AnalysisQueueService(
            captureStore: captureStore, contentAnalysisService: contentAnalysisService,
            classificationService: classificationService, appStateStore: appStateStore
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

    // 자동 큐가 pending을 처음(또는 앱이 죽어 processing에서 되돌아온 뒤 다시) 집을 때는
    // analysisAttempt를 올리지 않는다 — 아직 서버에서 진행 중이었을 수도 있는 작업과 같은
    // Idempotency-Key를 유지해야 중복 제출·중복 AI 호출을 피한다(사용자가 명시적으로 누르는
    // retry()만 attempt를 올린다).
    func testResumeIfNeededDoesNotChangeIdempotencyKeyAcrossRuns() async throws {
        try await captureStore.save(makeCapture("c1", capturedAt: 1_000, searchState: .processing))
        succeedingSubmitAndStatus(for: "c1")
        try await appStateStore.setValue("true", for: AppStateKey.analysisStartRequested)

        await queue.resumeIfNeeded()

        XCTAssertEqual(jobAPIClient.submitCalls.count, 1)
        XCTAssertTrue(jobAPIClient.submitCalls[0].idempotencyKey.hasSuffix("-a0"))
    }

    func testRetrySucceedsAndMarksReady() async throws {
        let capture = makeCapture("c1", capturedAt: 1_000, searchState: .failed)
        try await captureStore.save(capture)
        succeedingSubmitAndStatus(for: "c1")

        try await queue.retry(capture)

        let state = try await captureStore.fetchAll().first?.searchState
        XCTAssertEqual(state, .ready)
    }

    // 서버가 같은 Idempotency-Key로 온 요청은 예전 작업(설령 영원히 멈춰있거나 이미 FAILED로
    // 끝난 것이라도)을 그대로 돌려주고 재실행하지 않는다 — 재시도마다 키가 달라야 실제로 다시
    // 분석을 시도한다(2026-09-25 발견·수정).
    func testRetryUsesADifferentIdempotencyKeyEachTime() async throws {
        let capture = makeCapture("c1", capturedAt: 1_000, searchState: .failed)
        try await captureStore.save(capture)
        failingSubmitAndStatus(for: "c1")

        try? await queue.retry(capture)
        try? await queue.retry(capture)

        XCTAssertEqual(jobAPIClient.submitCalls.count, 2)
        let keys = jobAPIClient.submitCalls.map(\.idempotencyKey)
        XCTAssertEqual(Set(keys).count, 2)
    }

    // "갤러리 전체를 서비스가 다 처리해준다"는 방향대로, 분석이 성공하면 같은 실행에서 바로
    // 분류까지 끝나야 한다 — 사용자가 분류를 따로 트리거할 필요가 없다.
    func testResumeIfNeededChainsClassificationAfterSuccessfulAnalysis() async throws {
        try await captureStore.save(makeCapture("c1", capturedAt: 1_000))
        try await folderStore.save(Folder(
            id: "folder-1", displayName: "면접", criteriaText: "면접 준비 자료", criteriaVersion: 1,
            criteriaState: .ready, membershipRevision: 0))
        succeedingSubmitAndStatus(for: "c1")
        classificationAPIClient.submitResultsByReference["c1"] = .success(
            JobSubmitted(jobId: "classify-c1", status: .queued, pollAfterSeconds: 0))
        classificationAPIClient.statusResultsByJobId["classify-c1"] = [
            .success(ClassificationJobStatusResult(
                jobId: "classify-c1", status: .succeeded, clientReference: "c1",
                result: ClassificationResultDTO(decisions: [
                    ClassificationDecisionDTO(folderId: "folder-1", criteriaVersion: 1, decision: .match, evidence: "e"),
                ]),
                resultExpiresAt: nil, error: nil))
        ]
        try await appStateStore.setValue("true", for: AppStateKey.analysisStartRequested)

        await queue.resumeIfNeeded()

        let capture = try await captureStore.fetchCapture(id: "c1")
        XCTAssertEqual(capture?.searchState, .ready)
        XCTAssertEqual(capture?.classificationState, .complete)
        let folders = try await folderStore.fetchFolders(containing: "c1")
        XCTAssertEqual(folders.map(\.id), ["folder-1"])
    }

    // 분류가 실패해도 분석 자체는 이미 성공했으니 searchState는 ready로 남는다 — 실패는
    // classificationState에만 반영된다.
    func testClassificationFailureDoesNotUndoSuccessfulAnalysis() async throws {
        try await captureStore.save(makeCapture("c1", capturedAt: 1_000))
        try await folderStore.save(Folder(
            id: "folder-1", displayName: "면접", criteriaText: "면접 준비 자료", criteriaVersion: 1,
            criteriaState: .ready, membershipRevision: 0))
        succeedingSubmitAndStatus(for: "c1")
        classificationAPIClient.submitResultsByReference["c1"] = .success(
            JobSubmitted(jobId: "classify-c1", status: .queued, pollAfterSeconds: 0))
        classificationAPIClient.statusResultsByJobId["classify-c1"] = [
            .success(ClassificationJobStatusResult(
                jobId: "classify-c1", status: .failed, clientReference: "c1", result: nil,
                resultExpiresAt: nil, error: JobErrorDTO(code: "X", message: "실패", retryable: true)))
        ]
        try await appStateStore.setValue("true", for: AppStateKey.analysisStartRequested)

        await queue.resumeIfNeeded()

        let capture = try await captureStore.fetchCapture(id: "c1")
        XCTAssertEqual(capture?.searchState, .ready)
        XCTAssertEqual(capture?.classificationState, .failed)
    }

    // 이 기능이 생기기 전에 분석만 끝나 있던(searchState=ready, classificationState=pending)
    // 캡처도 nextPendingForClassification()으로 마저 처리돼야 한다.
    func testResumeIfNeededAlsoClassifiesPreviouslyAnalyzedCaptures() async throws {
        try await captureStore.save(makeCapture("old-ready", capturedAt: 1_000, searchState: .ready))
        try await folderStore.save(Folder(
            id: "folder-1", displayName: "면접", criteriaText: "면접 준비 자료", criteriaVersion: 1,
            criteriaState: .ready, membershipRevision: 0))
        try await captureStore.saveAnalysis(
            CaptureAnalysis(captureID: "old-ready", contentRevision: 1, analysisRevision: 1, ocrText: "", observedEvidence: [], modelVersion: "v1"),
            searchDocument: SearchDocument(captureID: "old-ready", sourceAnalysisRevision: 1, searchText: "s", embedding: [0.1], embeddingModelVersion: "v1", state: "ready")
        )
        classificationAPIClient.submitResultsByReference["old-ready"] = .success(
            JobSubmitted(jobId: "classify-old", status: .queued, pollAfterSeconds: 0))
        classificationAPIClient.statusResultsByJobId["classify-old"] = [
            .success(ClassificationJobStatusResult(
                jobId: "classify-old", status: .succeeded, clientReference: "old-ready",
                result: ClassificationResultDTO(decisions: []), resultExpiresAt: nil, error: nil))
        ]
        try await appStateStore.setValue("true", for: AppStateKey.analysisStartRequested)

        await queue.resumeIfNeeded()

        let capture = try await captureStore.fetchCapture(id: "old-ready")
        XCTAssertEqual(capture?.classificationState, .complete)
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
