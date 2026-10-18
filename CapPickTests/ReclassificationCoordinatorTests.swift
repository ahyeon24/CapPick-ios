import XCTest
@testable import CapPick

@MainActor
final class ReclassificationCoordinatorTests: XCTestCase {
    private var captureStore: GRDBCaptureStore!
    private var folderStore: GRDBFolderStore!
    private var reclassificationStore: GRDBReclassificationStore!
    private var apiClient: FakeClassificationAPIClient!
    private var service: ReclassificationService!
    private var coordinator: ReclassificationCoordinator!

    private let folder = Folder(
        id: "f1", displayName: "뷰티", criteriaText: nil, criteriaVersion: 1,
        criteriaState: .pending, membershipRevision: 0)

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
            apiClient: FakeInstallationAPIClient(), attestationProvider: FakeAttestationProvider(),
            credentialStore: credentialStore)
        let classificationService = ClassificationService(
            classificationAPIClient: apiClient, installationRegistrar: registrar,
            captureStore: captureStore, folderStore: folderStore)
        service = ReclassificationService(
            captureStore: captureStore, folderStore: folderStore,
            reclassificationStore: reclassificationStore, classificationService: classificationService)
        coordinator = ReclassificationCoordinator(service: service, reclassificationStore: reclassificationStore)
    }

    private func addAnalyzedCapture(_ id: String, decision: ClassificationDecision) async throws {
        try await captureStore.save(Capture(
            id: id, photoAssetID: "asset-\(id)", capturedAt: Date(timeIntervalSince1970: 1_000),
            width: 100, height: 200, availability: .accessible, excludedAt: nil, favorite: false,
            contentRevision: 1, searchState: .ready, classificationState: .complete))
        try await captureStore.saveAnalysis(
            CaptureAnalysis(captureID: id, contentRevision: 1, analysisRevision: 1, ocrText: "립스틱", observedEvidence: [], modelVersion: "v1"),
            searchDocument: SearchDocument(captureID: id, sourceAnalysisRevision: 1, searchText: "s", embedding: [0.1], embeddingModelVersion: "v1", state: "ready"))
        apiClient.submitResultsByReference[id] = .success(JobSubmitted(jobId: "job-\(id)", status: .queued, pollAfterSeconds: 0))
        apiClient.statusResultsByJobId["job-\(id)"] = [
            .success(ClassificationJobStatusResult(
                jobId: "job-\(id)", status: .succeeded, clientReference: id,
                result: ClassificationResultDTO(decisions: [
                    ClassificationDecisionDTO(folderId: "f1", criteriaVersion: 1, decision: decision, evidence: "근거"),
                ]),
                resultExpiresAt: nil, error: nil))
        ]
    }

    /// 코디네이터는 백그라운드로 돈다 — 원하는 단계에 이를 때까지 기다린다.
    private func waitForPhase(_ matches: (ReclassificationCoordinator.Phase?) -> Bool) async throws {
        for _ in 0..<200 {
            if matches(coordinator.job(for: "f1")?.phase) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("단계에 이르지 못함: \(String(describing: coordinator.job(for: "f1")?.phase))")
    }

    private func memberIDs() async throws -> Set<String> {
        Set(try await folderStore.fetchMemberships(of: "f1").filter { $0.state == .present }.map(\.captureID))
    }

    // 새 폴더의 "기존 캡처에도 적용"은 확인 없이 바로 반영한다 — 창을 내려도 결과가 남는다.
    func testInitialApplyAddsMatchesWithoutConfirmation() async throws {
        try await addAnalyzedCapture("c1", decision: .match)
        try await addAnalyzedCapture("c2", decision: .noMatch)
        try await addAnalyzedCapture("c3", decision: .match)

        coordinator.start(folder: folder, mode: .initialApply)
        try await waitForPhase { if case .finished = $0 { return true } else { return false } }

        XCTAssertEqual(coordinator.job(for: "f1")?.phase, .finished(added: 2))
        let members = try await memberIDs()
        XCTAssertEqual(members, ["c1", "c3"])
        XCTAssertEqual(coordinator.completedCount, 1)
    }

    // "기존 캡처 재분류"는 결과를 남겨 두고 확인을 기다린다. 확인해야 반영된다.
    func testReclassifyWaitsForConfirmationThenApplies() async throws {
        try await addAnalyzedCapture("c1", decision: .match)

        coordinator.start(folder: folder, mode: .reclassify)
        try await waitForPhase { if case .awaitingConfirmation = $0 { return true } else { return false } }
        let before = try await memberIDs()
        XCTAssertTrue(before.isEmpty)

        await coordinator.confirm(folderID: "f1")

        XCTAssertEqual(coordinator.job(for: "f1")?.phase, .finished(added: 1))
        let after = try await memberIDs()
        XCTAssertEqual(after, ["c1"])
    }

    // 이전에 중단돼 previewing으로 남은 실행이 있어도 막히지 않고 새로 시작한다(2026-10-18 실제 버그).
    func testStaleRunLeftFromInterruptedPreviewDoesNotBlockNewRun() async throws {
        try await addAnalyzedCapture("c1", decision: .match)
        _ = try await reclassificationStore.createRun(
            folderID: "f1", criteriaVersion: 1, membershipRevision: 0, mode: .initialApply)

        coordinator.start(folder: folder, mode: .initialApply)
        try await waitForPhase { if case .finished = $0 { return true } else { return false } }

        let members = try await memberIDs()
        XCTAssertEqual(members, ["c1"])
    }

    // 같은 폴더의 계산이 이미 돌고 있으면 다시 눌러도 새로 시작하지 않는다.
    func testStartWhileRunningDoesNotStartSecondRun() async throws {
        try await addAnalyzedCapture("c1", decision: .match)

        coordinator.start(folder: folder, mode: .reclassify)
        coordinator.start(folder: folder, mode: .reclassify)
        try await waitForPhase { if case .awaitingConfirmation = $0 { return true } else { return false } }

        XCTAssertEqual(apiClient.submitCalls.count, 1)
    }
}
