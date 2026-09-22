import Foundation

// 앱에서 쓰는 저장소·서비스를 한 곳에서 조립한다. 화면은 여기서 만든 인스턴스를 주입받는다.
struct AppEnvironment: Sendable {
    let library: any ScreenshotLibrary
    let captureStore: any CaptureStoring
    let folderStore: any FolderStoring
    let appStateStore: any AppStateStoring
    let syncService: ScreenshotSyncService
    let installationRegistrar: InstallationRegistrar
    let thumbnailLoader: any ThumbnailLoading

    // 로컬 개발 전용 기본값 — 시뮬레이터에서 Mac의 localhost를 그대로 가리킨다. 배포 주소는
    // 아직 없다(API 명세 §1: "배포 주소 없음"). 실기기로 테스트하려면 Mac의 LAN IP로 바꿔야 한다.
    private static let developmentServerURL = URL(string: "http://localhost:8080")!

    static func live() throws -> AppEnvironment {
        let database = try AppDatabase.makeOnDisk()
        let library = PhotosScreenshotLibrary()
        let captureStore = GRDBCaptureStore(database: database)
        let appStateStore = GRDBAppStateStore(database: database)

        let apiClient = URLSessionInstallationAPIClient(baseURL: developmentServerURL)
        // Apple Developer Program 미가입 상태라 AppAttestProvider 대신 우회 구현을 쓴다
        // (서버 cappick.attestation.mode=bypass와 짝). 계정이 생기면 여기만 바꾸면 된다.
        let attestationProvider = DevBypassAttestationProvider(appStateStore: appStateStore)
        let installationRegistrar = InstallationRegistrar(
            apiClient: apiClient,
            attestationProvider: attestationProvider,
            credentialStore: KeychainCredentialStore()
        )

        return AppEnvironment(
            library: library,
            captureStore: captureStore,
            folderStore: GRDBFolderStore(database: database),
            appStateStore: appStateStore,
            syncService: ScreenshotSyncService(library: library, captureStore: captureStore),
            installationRegistrar: installationRegistrar,
            thumbnailLoader: PhotosThumbnailLoader()
        )
    }
}
