import XCTest
@testable import CapPick

final class ClassificationServiceTests: XCTestCase {
    private var captureStore: GRDBCaptureStore!
    private var folderStore: GRDBFolderStore!
    private var apiClient: FakeClassificationAPIClient!
    private var registrar: InstallationRegistrar!
    private var service: ClassificationService!

    private let capture = Capture(
        id: "capture-1", photoAssetID: "asset-1", capturedAt: Date(timeIntervalSince1970: 1_000),
        width: 100, height: 200, availability: .accessible, excludedAt: nil, favorite: false,
        contentRevision: 1, searchState: .ready, classificationState: .pending
    )

    override func setUp() async throws {
        let database = try AppDatabase.makeInMemory()
        captureStore = GRDBCaptureStore(database: database)
        folderStore = GRDBFolderStore(database: database)
        try await captureStore.save(capture)

        apiClient = FakeClassificationAPIClient()

        let credentialStore = InMemoryCredentialStore()
        try credentialStore.save("existing-credential")
        registrar = InstallationRegistrar(
            apiClient: FakeInstallationAPIClient(),
            attestationProvider: FakeAttestationProvider(),
            credentialStore: credentialStore
        )

        service = ClassificationService(
            classificationAPIClient: apiClient, installationRegistrar: registrar,
            captureStore: captureStore, folderStore: folderStore
        )
    }

    private func saveAnalysis(ocrText: String = "용신 정보", observedEvidence: [String] = ["사주 앱 화면"]) async throws {
        try await captureStore.saveAnalysis(
            CaptureAnalysis(
                captureID: "capture-1", contentRevision: 1, analysisRevision: 1,
                ocrText: ocrText, observedEvidence: observedEvidence, modelVersion: "embed-v1"),
            searchDocument: SearchDocument(
                captureID: "capture-1", sourceAnalysisRevision: 1, searchText: "s",
                embedding: [0.1], embeddingModelVersion: "embed-v1", state: "ready")
        )
    }

    private func saveFolder(id: String, criteriaText: String?, criteriaVersion: Int = 1) async throws {
        try await folderStore.save(Folder(
            id: id, displayName: id, criteriaText: criteriaText, criteriaVersion: criteriaVersion,
            criteriaState: .ready, membershipRevision: 0))
    }

    func testClassifyReturnsWithoutSubmittingWhenAnalysisMissing() async throws {
        try await saveFolder(id: "folder-1", criteriaText: "면접 준비")

        try await service.classify(capture)

        XCTAssertEqual(apiClient.submitCalls.count, 0)
    }

    func testClassifySkipsNetworkWhenThereAreNoFoldersAtAll() async throws {
        try await saveAnalysis()

        try await service.classify(capture)

        XCTAssertEqual(apiClient.submitCalls.count, 0)
    }

    // 2026-09-25 사용자 결정: 기준 텍스트를 안 적어도 폴더 이름으로 분류 대상이 된다 — 기준을
    // 입력하는 게 귀찮은 사용자가 많을 거라는 판단.
    func testClassifyFallsBackToDisplayNameWhenCriteriaTextIsBlank() async throws {
        try await saveAnalysis()
        try await saveFolder(id: "folder-1", criteriaText: "면접 준비")
        try await folderStore.save(Folder(
            id: "folder-2", displayName: "운세", criteriaText: nil, criteriaVersion: 1,
            criteriaState: .pending, membershipRevision: 0))
        apiClient.submitResultsByReference["capture-1"] = .success(
            JobSubmitted(jobId: "job-1", status: .queued, pollAfterSeconds: 0))
        apiClient.statusResultsByJobId["job-1"] = [
            .success(ClassificationJobStatusResult(
                jobId: "job-1", status: .succeeded, clientReference: "capture-1",
                result: ClassificationResultDTO(decisions: []), resultExpiresAt: nil, error: nil))
        ]

        try await service.classify(capture)

        XCTAssertEqual(apiClient.submitCalls.count, 1)
        let folders = Dictionary(uniqueKeysWithValues: apiClient.submitCalls[0].folders.map { ($0.id, $0.criteriaText) })
        XCTAssertEqual(folders["folder-1"], "면접 준비")
        XCTAssertEqual(folders["folder-2"], "운세")
    }

    func testMatchDecisionAppliesFolderMembershipAndNoMatchDoesNothing() async throws {
        try await saveAnalysis()
        try await saveFolder(id: "folder-1", criteriaText: "면접 준비")
        try await saveFolder(id: "folder-2", criteriaText: "맛집")
        apiClient.submitResultsByReference["capture-1"] = .success(
            JobSubmitted(jobId: "job-1", status: .queued, pollAfterSeconds: 0))
        apiClient.statusResultsByJobId["job-1"] = [
            .success(ClassificationJobStatusResult(
                jobId: "job-1", status: .succeeded, clientReference: "capture-1",
                result: ClassificationResultDTO(decisions: [
                    ClassificationDecisionDTO(folderId: "folder-1", criteriaVersion: 1, decision: .match, evidence: "면접 문구 확인"),
                    ClassificationDecisionDTO(folderId: "folder-2", criteriaVersion: 1, decision: .noMatch, evidence: ""),
                ]),
                resultExpiresAt: nil, error: nil))
        ]

        try await service.classify(capture)

        let memberFolders = try await folderStore.fetchFolders(containing: "capture-1")
        XCTAssertEqual(memberFolders.map(\.id), ["folder-1"])
    }

    func testUncertainDecisionDoesNotApplyMembership() async throws {
        try await saveAnalysis()
        try await saveFolder(id: "folder-1", criteriaText: "면접 준비")
        apiClient.submitResultsByReference["capture-1"] = .success(
            JobSubmitted(jobId: "job-1", status: .queued, pollAfterSeconds: 0))
        apiClient.statusResultsByJobId["job-1"] = [
            .success(ClassificationJobStatusResult(
                jobId: "job-1", status: .succeeded, clientReference: "capture-1",
                result: ClassificationResultDTO(decisions: [
                    ClassificationDecisionDTO(folderId: "folder-1", criteriaVersion: 1, decision: .uncertain, evidence: ""),
                ]),
                resultExpiresAt: nil, error: nil))
        ]

        try await service.classify(capture)

        let memberFolders = try await folderStore.fetchFolders(containing: "capture-1")
        XCTAssertTrue(memberFolders.isEmpty)
    }

    // analysisRevision만으로 키를 만들면, 재분석으로 OCR·관찰 내용 문구가 살짝 달라졌을 때 서버가
    // 옛 분류 요청과 같은 키·다른 내용으로 보고 409를 낸다(2026-09-25 실제로 겪음). capture의
    // analysisAttempt를 같이 넣어서, "다시 분석하기"(attempt 증가)마다 분류 키도 새로워지게 한다.
    func testIdempotencyKeyIncludesAnalysisAttempt() async throws {
        try await saveAnalysis()
        try await saveFolder(id: "folder-1", criteriaText: "면접 준비")
        apiClient.submitResultsByReference["capture-1"] = .success(
            JobSubmitted(jobId: "job-1", status: .queued, pollAfterSeconds: 0))
        apiClient.statusResultsByJobId["job-1"] = [
            .success(ClassificationJobStatusResult(
                jobId: "job-1", status: .succeeded, clientReference: "capture-1",
                result: ClassificationResultDTO(decisions: []), resultExpiresAt: nil, error: nil))
        ]
        var retriedCapture = capture
        retriedCapture.analysisAttempt = 3

        try await service.classify(retriedCapture)

        XCTAssertTrue(apiClient.submitCalls[0].idempotencyKey.hasSuffix("-a3"))
    }

    func testClassifyThrowsJobFailedWithServerErrorCode() async throws {
        try await saveAnalysis()
        try await saveFolder(id: "folder-1", criteriaText: "면접 준비")
        apiClient.submitResultsByReference["capture-1"] = .success(
            JobSubmitted(jobId: "job-1", status: .queued, pollAfterSeconds: 0))
        apiClient.statusResultsByJobId["job-1"] = [
            .success(ClassificationJobStatusResult(
                jobId: "job-1", status: .failed, clientReference: "capture-1", result: nil,
                resultExpiresAt: nil, error: JobErrorDTO(code: "CLASSIFICATION_FAILED", message: "실패", retryable: true)))
        ]

        do {
            try await service.classify(capture)
            XCTFail("expected jobFailed")
        } catch ClassificationError.jobFailed(let code) {
            XCTAssertEqual(code, "CLASSIFICATION_FAILED")
        }
    }
}
