import Observation

// 화면설계서 HOME-01의 첫 단계: 접근 가능한 스크린샷 수와 분석 진행 상태만 보여준다.
// 검색·폴더 카드는 아직 없다.
@MainActor @Observable
final class HomeViewModel {
    private(set) var progress: AnalysisProgress?
    private(set) var authorization: PhotoAuthorization
    private(set) var errorMessage: String?

    private let library: any ScreenshotLibrary
    private let syncService: ScreenshotSyncService
    private let captureStore: any CaptureStoring

    init(
        library: any ScreenshotLibrary,
        syncService: ScreenshotSyncService,
        captureStore: any CaptureStoring
    ) {
        self.library = library
        self.syncService = syncService
        self.captureStore = captureStore
        self.authorization = library.authorization
    }

    /// 앱 실행·복귀 시 새 캡처를 확인하고 진행 상태를 다시 읽는다 (PHOTO-04).
    func refresh() async {
        authorization = library.authorization
        errorMessage = nil
        do {
            _ = try await syncService.sync()
            progress = try await captureStore.currentProgress()
        } catch {
            errorMessage = "스크린샷을 확인하지 못했어요."
        }
    }
}
