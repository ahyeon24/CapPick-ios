import XCTest
@testable import CapPick

@MainActor
final class OnboardingViewModelTests: XCTestCase {
    private var captures: GRDBCaptureStore!
    private var appState: GRDBAppStateStore!
    private var finished = false

    override func setUp() async throws {
        let database = try AppDatabase.makeInMemory()
        captures = GRDBCaptureStore(database: database)
        appState = GRDBAppStateStore(database: database)
        finished = false
    }

    private func makeViewModel(_ library: FakeScreenshotLibrary) -> OnboardingViewModel {
        OnboardingViewModel(
            library: library,
            syncService: ScreenshotSyncService(library: library, captureStore: captures),
            captureStore: captures,
            appStateStore: appState,
            onFinished: { [unowned self] in finished = true }
        )
    }

    func testAlreadyAuthorizedScansOnStartAndShowsCount() async {
        let library = FakeScreenshotLibrary(authorization: .authorized, screenshots: [shot("a"), shot("b"), shot("c")])
        let viewModel = makeViewModel(library)

        await viewModel.start()

        XCTAssertEqual(viewModel.step, .analysisStart)
        XCTAssertEqual(viewModel.screenshotCount, 3)
        XCTAssertEqual(library.requestCount, 0, "이미 허용된 상태에서는 권한 창을 다시 띄우지 않는다")
    }

    func testFirstRunWaitsForUserThenScansAfterGrant() async {
        let library = FakeScreenshotLibrary(
            authorization: .notDetermined,
            authorizationAfterRequest: .authorized,
            screenshots: [shot("a"), shot("b")]
        )
        let viewModel = makeViewModel(library)

        await viewModel.start()
        XCTAssertEqual(viewModel.step, .photoAccess)
        XCTAssertEqual(library.fetchCount, 0, "시작하기만으로는 사진을 읽지 않는다")

        await viewModel.requestPhotoAccess()
        XCTAssertEqual(viewModel.step, .analysisStart)
        XCTAssertEqual(viewModel.screenshotCount, 2)
    }

    func testLimitedAccessStillScansAndKeepsLimitedState() async {
        let library = FakeScreenshotLibrary(authorization: .limited, screenshots: [shot("a")])
        let viewModel = makeViewModel(library)

        await viewModel.start()

        XCTAssertEqual(viewModel.authorization, .limited)
        XCTAssertEqual(viewModel.step, .analysisStart)
        XCTAssertEqual(viewModel.screenshotCount, 1)
    }

    func testDeniedStaysOnPhotoAccessWithoutScanning() async {
        let library = FakeScreenshotLibrary(
            authorization: .notDetermined,
            authorizationAfterRequest: .denied,
            screenshots: [shot("a")]
        )
        let viewModel = makeViewModel(library)

        await viewModel.start()
        await viewModel.requestPhotoAccess()

        XCTAssertEqual(viewModel.step, .photoAccess)
        XCTAssertEqual(viewModel.authorization, .denied)
        XCTAssertEqual(library.fetchCount, 0)
    }

    func testReturningFromSettingsAfterAllowingScansAutomatically() async {
        let library = FakeScreenshotLibrary(authorization: .denied, screenshots: [shot("a")])
        let viewModel = makeViewModel(library)
        await viewModel.start()
        XCTAssertEqual(viewModel.step, .photoAccess)

        library.authorization = .authorized
        await viewModel.refreshAfterReturning()

        XCTAssertEqual(viewModel.step, .analysisStart)
        XCTAssertEqual(viewModel.screenshotCount, 1)
    }

    func testZeroScreenshotsStillReachesAnalysisStartWithZeroCount() async {
        let library = FakeScreenshotLibrary(authorization: .authorized, screenshots: [])
        let viewModel = makeViewModel(library)

        await viewModel.start()

        XCTAssertEqual(viewModel.step, .analysisStart)
        XCTAssertEqual(viewModel.screenshotCount, 0)
    }

    func testStartAnalysisRecordsRequestAndFinishesOnboarding() async throws {
        let library = FakeScreenshotLibrary(authorization: .authorized, screenshots: [shot("a")])
        let viewModel = makeViewModel(library)
        await viewModel.start()

        await viewModel.startAnalysis()

        XCTAssertTrue(finished)
        let completed = try await appState.value(for: AppStateKey.onboardingCompleted)
        let requested = try await appState.value(for: AppStateKey.analysisStartRequested)
        XCTAssertEqual(completed, "true")
        XCTAssertEqual(requested, "true")
    }

    func testPostponingAndSkippingFinishWithoutAnalysisRequest() async throws {
        let library = FakeScreenshotLibrary(authorization: .authorized, screenshots: [shot("a")])
        let postponed = makeViewModel(library)
        await postponed.start()
        await postponed.postponeAnalysis()
        XCTAssertTrue(finished)
        var requested = try await appState.value(for: AppStateKey.analysisStartRequested)
        XCTAssertEqual(requested, "false")

        finished = false
        let denied = FakeScreenshotLibrary(authorization: .denied)
        let skipped = makeViewModel(denied)
        await skipped.start()
        await skipped.skipPhotoAccess()
        XCTAssertTrue(finished)
        requested = try await appState.value(for: AppStateKey.analysisStartRequested)
        XCTAssertEqual(requested, "false")
    }

    // MARK: - Home

    func testHomeRefreshSyncsAndLoadsProgress() async throws {
        let library = FakeScreenshotLibrary(authorization: .authorized, screenshots: [shot("a"), shot("b")])
        let credentialStore = InMemoryCredentialStore()
        try credentialStore.save("existing-credential")
        let registrar = InstallationRegistrar(
            apiClient: FakeInstallationAPIClient(),
            attestationProvider: FakeAttestationProvider(),
            credentialStore: credentialStore
        )
        let contentAnalysisService = ContentAnalysisService(
            jobAPIClient: FakeJobAPIClient(), installationRegistrar: registrar,
            captureStore: captures, imageProvider: FakeCaptureImageProviding()
        )
        let viewModel = HomeViewModel(
            library: library,
            syncService: ScreenshotSyncService(library: library, captureStore: captures),
            captureStore: captures,
            appStateStore: appState,
            analysisQueueService: AnalysisQueueService(
                captureStore: captures, contentAnalysisService: contentAnalysisService, appStateStore: appState)
        )

        await viewModel.refresh()

        XCTAssertEqual(viewModel.progress?.total, 2)
        XCTAssertEqual(viewModel.progress?.searchReady, 0)
        XCTAssertNil(viewModel.errorMessage)
    }
}
