import XCTest
@testable import CapPick

final class ReclassificationServiceTests: XCTestCase {
    private var captureStore: GRDBCaptureStore!
    private var folderStore: GRDBFolderStore!
    private var reclassificationStore: GRDBReclassificationStore!
    private var apiClient: FakeClassificationAPIClient!
    private var service: ReclassificationService!

    private let folder = Folder(
        id: "f1", displayName: "면접 준비", criteriaText: "면접 관련 스크린샷", criteriaVersion: 1,
        criteriaState: .ready, membershipRevision: 0)

    override func setUp() async throws {
        let database = try AppDatabase.makeInMemory()
        captureStore = GRDBCaptureStore(database: database)
        folderStore = GRDBFolderStore(database: database)
        reclassificationStore = GRDBReclassificationStore(database: database)
        try await folderStore.save(folder)

        apiClient = FakeClassificationAPIClient()
        let credentialStore = InMemoryCredentialStore()
        try credentialStore.save("existing-credential")
        let registrar = InstallationRegistrar(
            apiClient: FakeInstallationAPIClient(),
            attestationProvider: FakeAttestationProvider(),
            credentialStore: credentialStore
        )
        let classificationService = ClassificationService(
            classificationAPIClient: apiClient, installationRegistrar: registrar,
            captureStore: captureStore, folderStore: folderStore
        )
        service = ReclassificationService(
            captureStore: captureStore, folderStore: folderStore,
            reclassificationStore: reclassificationStore, classificationService: classificationService
        )
    }

    private func makeCapture(_ id: String) -> Capture {
        Capture(
            id: id, photoAssetID: "asset-\(id)", capturedAt: Date(timeIntervalSince1970: 1_000),
            width: 100, height: 200, availability: .accessible, excludedAt: nil, favorite: false,
            contentRevision: 1, searchState: .ready, classificationState: .complete
        )
    }

    private func saveAnalysis(for captureID: String) async throws {
        try await captureStore.saveAnalysis(
            CaptureAnalysis(captureID: captureID, contentRevision: 1, analysisRevision: 1, ocrText: "면접 예상 질문", observedEvidence: [], modelVersion: "v1"),
            searchDocument: SearchDocument(captureID: captureID, sourceAnalysisRevision: 1, searchText: "s", embedding: [0.1], embeddingModelVersion: "v1", state: "ready")
        )
    }

    private func stubDecision(for captureID: String, decision: ClassificationDecision) {
        apiClient.submitResultsByReference[captureID] = .success(
            JobSubmitted(jobId: "job-\(captureID)", status: .queued, pollAfterSeconds: 0))
        apiClient.statusResultsByJobId["job-\(captureID)"] = [
            .success(ClassificationJobStatusResult(
                jobId: "job-\(captureID)", status: .succeeded, clientReference: captureID,
                result: ClassificationResultDTO(decisions: [
                    ClassificationDecisionDTO(folderId: "f1", criteriaVersion: 1, decision: decision, evidence: "근거"),
                ]),
                resultExpiresAt: nil, error: nil))
        ]
    }

    func testPreviewProposesAddForMatchingUnmemberedCapture() async throws {
        try await captureStore.save(makeCapture("c1"))
        try await saveAnalysis(for: "c1")
        stubDecision(for: "c1", decision: .match)

        let run = try await service.preview(folderID: "f1", mode: .reclassify)
        let items = try await reclassificationStore.fetchItems(runID: run.id)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].action, .add)
        XCTAssertEqual(items[0].captureID, "c1")
        // 확인 전이라 아직 실제 소속에는 반영되지 않는다.
        let memberships = try await folderStore.fetchMemberships(of: "f1")
        XCTAssertTrue(memberships.isEmpty)
    }

    func testPreviewProposesRemoveForAutoPresentCaptureNoLongerMatching() async throws {
        try await captureStore.save(makeCapture("c1"))
        try await saveAnalysis(for: "c1")
        _ = try await folderStore.applyAutoMatch(captureID: "c1", to: "f1", evidence: nil, criteriaVersion: 1)
        stubDecision(for: "c1", decision: .noMatch)

        let run = try await service.preview(folderID: "f1", mode: .reclassify)
        let items = try await reclassificationStore.fetchItems(runID: run.id)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].action, .remove)
    }

    func testPreviewNeverProposesRemovingManualMembership() async throws {
        try await captureStore.save(makeCapture("c1"))
        try await saveAnalysis(for: "c1")
        try await folderStore.addManually(captureID: "c1", to: "f1")
        stubDecision(for: "c1", decision: .noMatch)

        let run = try await service.preview(folderID: "f1", mode: .reclassify)
        let items = try await reclassificationStore.fetchItems(runID: run.id)

        XCTAssertTrue(items.isEmpty, "manual 소속은 재분류 미리보기에서부터 후보로 안 올라와야 한다")
    }

    func testPreviewNeverProposesAddingBackUserRemovedCapture() async throws {
        try await captureStore.save(makeCapture("c1"))
        try await saveAnalysis(for: "c1")
        try await folderStore.addManually(captureID: "c1", to: "f1")
        try await folderStore.removeManually(captureID: "c1", from: "f1")
        stubDecision(for: "c1", decision: .match)

        let run = try await service.preview(folderID: "f1", mode: .reclassify)
        let items = try await reclassificationStore.fetchItems(runID: run.id)

        XCTAssertTrue(items.isEmpty, "사용자가 직접 뺀 캡처는 다시 추가 후보로 올라오면 안 된다")
    }

    func testPreviewThrowsWhenAnActiveRunAlreadyExists() async throws {
        _ = try await reclassificationStore.createRun(folderID: "f1", criteriaVersion: 1, membershipRevision: 0, mode: .reclassify)

        do {
            _ = try await service.preview(folderID: "f1", mode: .reclassify)
            XCTFail("expected alreadyInProgress")
        } catch ReclassificationError.alreadyInProgress {
            // 기대한 대로
        }
    }

    func testPreviewSkipsCaptureWhoseClassificationCallFailsAndContinues() async throws {
        try await captureStore.save(makeCapture("bad"))
        try await captureStore.save(makeCapture("good"))
        try await saveAnalysis(for: "bad")
        try await saveAnalysis(for: "good")
        apiClient.submitResultsByReference["bad"] = .failure(URLError(.timedOut))
        stubDecision(for: "good", decision: .match)

        let run = try await service.preview(folderID: "f1", mode: .reclassify)
        let items = try await reclassificationStore.fetchItems(runID: run.id)

        XCTAssertEqual(items.map(\.captureID), ["good"])
    }

    func testApplyAddsAndRemovesThenMarksRunApplied() async throws {
        try await captureStore.save(makeCapture("toAdd"))
        try await captureStore.save(makeCapture("toRemove"))
        try await saveAnalysis(for: "toAdd")
        try await saveAnalysis(for: "toRemove")
        _ = try await folderStore.applyAutoMatch(captureID: "toRemove", to: "f1", evidence: nil, criteriaVersion: 1)
        stubDecision(for: "toAdd", decision: .match)
        stubDecision(for: "toRemove", decision: .noMatch)
        let run = try await service.preview(folderID: "f1", mode: .reclassify)

        try await service.apply(runID: run.id)

        let memberIDs = try await folderStore.fetchFolders(containing: "toAdd").map(\.id)
        XCTAssertEqual(memberIDs, ["f1"])
        let removedFolders = try await folderStore.fetchFolders(containing: "toRemove")
        XCTAssertTrue(removedFolders.isEmpty)
        let finishedRun = try await reclassificationStore.fetchRun(id: run.id)
        XCTAssertEqual(finishedRun?.state, ReclassificationRunState.applied)
    }

    func testCancelMarksRunCancelledWithoutChangingMembership() async throws {
        try await captureStore.save(makeCapture("c1"))
        try await saveAnalysis(for: "c1")
        stubDecision(for: "c1", decision: .match)
        let run = try await service.preview(folderID: "f1", mode: .reclassify)

        try await service.cancel(runID: run.id)

        let memberships = try await folderStore.fetchMemberships(of: "f1")
        XCTAssertTrue(memberships.isEmpty)
        let cancelledRun = try await reclassificationStore.fetchRun(id: run.id)
        XCTAssertEqual(cancelledRun?.state, ReclassificationRunState.cancelled)
        // 취소됐으니 같은 폴더로 새 재분류를 다시 시작할 수 있어야 한다.
        let active = try await reclassificationStore.activeRun(folderID: "f1")
        XCTAssertNil(active)
    }
}
