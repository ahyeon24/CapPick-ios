import XCTest
@testable import CapPick

@MainActor
final class SettingsViewModelTests: XCTestCase {
    private var database: AppDatabase!
    private var usageAPIClient: FakeUsageAPIClient!
    private var deletionAPIClient: FakeDeletionAPIClient!
    private var viewModel: SettingsViewModel!

    override func setUp() async throws {
        database = try AppDatabase.makeInMemory()
        usageAPIClient = FakeUsageAPIClient()
        deletionAPIClient = FakeDeletionAPIClient()

        let credentialStore = InMemoryCredentialStore()
        try credentialStore.save("existing-credential")
        let registrar = InstallationRegistrar(
            apiClient: FakeInstallationAPIClient(),
            attestationProvider: FakeAttestationProvider(),
            credentialStore: credentialStore
        )

        let usageService = UsageService(usageAPIClient: usageAPIClient, installationRegistrar: registrar)
        let deletionService = AppDataDeletionService(
            deletionAPIClient: deletionAPIClient, installationRegistrar: registrar, database: database)

        viewModel = SettingsViewModel(usageService: usageService, appDataDeletionService: deletionService)
    }

    func testLoadPopulatesUsage() async throws {
        await viewModel.load()

        XCTAssertEqual(viewModel.usage?.categories.count, 2)
        XCTAssertFalse(viewModel.usageLoadFailed)
    }

    func testLoadMarksFailureWhenServerCallFails() async throws {
        usageAPIClient.usageResult = .failure(URLError(.notConnectedToInternet))

        await viewModel.load()

        XCTAssertNil(viewModel.usage)
        XCTAssertTrue(viewModel.usageLoadFailed)
    }

    func testDeleteAllDataMarksDidDeleteDataOnSuccess() async throws {
        await viewModel.deleteAllData()

        XCTAssertTrue(viewModel.didDeleteData)
        XCTAssertNil(viewModel.deletionError)
    }
}
