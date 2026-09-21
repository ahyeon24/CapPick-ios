import Observation

// 화면설계서 ON-01 시작 안내 → ON-02 사진 접근 → ON-03 전체 분석 시작.
@MainActor @Observable
final class OnboardingViewModel {
    enum Step: Equatable {
        case welcome
        case photoAccess
        case analysisStart
    }

    private(set) var step: Step = .welcome
    private(set) var authorization: PhotoAuthorization
    private(set) var isWorking = false
    private(set) var screenshotCount = 0
    private(set) var errorMessage: String?

    private let library: any ScreenshotLibrary
    private let syncService: ScreenshotSyncService
    private let captureStore: any CaptureStoring
    private let appStateStore: any AppStateStoring
    private let onFinished: @MainActor () -> Void

    init(
        library: any ScreenshotLibrary,
        syncService: ScreenshotSyncService,
        captureStore: any CaptureStoring,
        appStateStore: any AppStateStoring,
        onFinished: @escaping @MainActor () -> Void
    ) {
        self.library = library
        self.syncService = syncService
        self.captureStore = captureStore
        self.appStateStore = appStateStore
        self.onFinished = onFinished
        self.authorization = library.authorization
    }

    /// ON-01 "시작하기". 이 시점엔 외부 AI 분석을 시작하지 않는다.
    func start() async {
        step = .photoAccess
        authorization = library.authorization
        await scanIfAllowed()
    }

    /// ON-02 "사진 접근 허용". 이미 결정된 상태면 권한 창 없이 현재 상태로 진행한다.
    func requestPhotoAccess() async {
        guard !isWorking else { return }
        authorization = await library.requestAuthorization()
        await scanIfAllowed()
    }

    /// 설정 앱에서 권한을 바꾸고 돌아왔을 때 호출한다.
    func refreshAfterReturning() async {
        guard step == .photoAccess else { return }
        let current = library.authorization
        guard current != authorization else { return }
        authorization = current
        await scanIfAllowed()
    }

    /// ON-02 "지금은 건너뛰기".
    func skipPhotoAccess() async {
        await finish(analysisRequested: false)
    }

    /// ON-03 "전체 캡처 분석 시작". 분석 대기열은 등록된 캡처(pending)이며 실제 분석 기능은 아직 연결 전이다.
    func startAnalysis() async {
        await finish(analysisRequested: true)
    }

    /// ON-03 "나중에 시작하기".
    func postponeAnalysis() async {
        await finish(analysisRequested: false)
    }

    private func scanIfAllowed() async {
        guard authorization.canReadPhotos else { return }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        do {
            _ = try await syncService.sync()
            screenshotCount = try await captureStore.currentProgress().total
            step = .analysisStart
        } catch {
            errorMessage = "스크린샷을 확인하지 못했어요. 다시 시도해 주세요."
        }
    }

    private func finish(analysisRequested: Bool) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        do {
            try await appStateStore.setValue(
                analysisRequested ? "true" : "false",
                for: AppStateKey.analysisStartRequested
            )
            try await appStateStore.setValue("true", for: AppStateKey.onboardingCompleted)
            onFinished()
        } catch {
            errorMessage = "설정을 저장하지 못했어요. 다시 시도해 주세요."
        }
    }
}
