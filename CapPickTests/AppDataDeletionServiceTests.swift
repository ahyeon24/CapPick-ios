import XCTest
@testable import CapPick

final class AppDataDeletionServiceTests: XCTestCase {
    private var database: AppDatabase!
    private var captureStore: GRDBCaptureStore!
    private var deletionAPIClient: FakeDeletionAPIClient!
    private var service: AppDataDeletionService!

    private let capture = Capture(
        id: "capture-1", photoAssetID: "asset-1", capturedAt: Date(timeIntervalSince1970: 1_000),
        width: 100, height: 200, availability: .accessible, excludedAt: nil, favorite: false,
        contentRevision: 1, searchState: .ready, classificationState: .pending
    )

    override func setUp() async throws {
        database = try AppDatabase.makeInMemory()
        captureStore = GRDBCaptureStore(database: database)
        try await captureStore.save(capture)

        deletionAPIClient = FakeDeletionAPIClient()
        let credentialStore = InMemoryCredentialStore()
        try credentialStore.save("existing-credential")
        let registrar = InstallationRegistrar(
            apiClient: FakeInstallationAPIClient(),
            attestationProvider: FakeAttestationProvider(),
            credentialStore: credentialStore
        )

        service = AppDataDeletionService(
            deletionAPIClient: deletionAPIClient, installationRegistrar: registrar, database: database)
    }

    func testDeleteAllAppDataErasesLocalCaptures() async throws {
        try await service.deleteAllAppData()

        let remaining = try await captureStore.fetchAll()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testDeleteAllAppDataCallsServerWithFreshIdempotencyKey() async throws {
        try await service.deleteAllAppData()

        XCTAssertEqual(deletionAPIClient.requestCallCount, 1)
        XCTAssertFalse(deletionAPIClient.requestedIdempotencyKeys[0].isEmpty)
    }

    // 시스템 설계 §2 "로컬 DB가 기준" — 서버 삭제 요청이 실패해도(오프라인 등) 로컬 삭제는
    // 그대로 진행해야 한다(사용자 결정, 2026-09-26).
    func testDeleteAllAppDataErasesLocalDataEvenWhenServerRequestFails() async throws {
        deletionAPIClient.requestResult = .failure(URLError(.notConnectedToInternet))

        try await service.deleteAllAppData()

        let remaining = try await captureStore.fetchAll()
        XCTAssertTrue(remaining.isEmpty)
    }
}
