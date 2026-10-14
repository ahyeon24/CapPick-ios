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
    let analysisQueueService: AnalysisQueueService
    let searchService: SearchService
    let reclassificationStore: any ReclassificationStoring
    let reclassificationService: ReclassificationService
    let usageService: UsageService
    let appDataDeletionService: AppDataDeletionService

    // 로컬 개발 전용 주소 — 배포 주소는 아직 없다(API 명세 §1: "배포 주소 없음").
    // 시뮬레이터는 Mac의 localhost를 그대로 가리키고, 실기기는 같은 와이파이에 있는 Mac을
    // 로컬 네트워크 이름(Info.plist의 CapPickDevServerHost, project.yml에서 설정)으로 찾는다.
    private static let developmentServerURL: URL = {
        #if targetEnvironment(simulator)
        return URL(string: "http://localhost:8080")!
        #else
        let host = Bundle.main.object(forInfoDictionaryKey: "CapPickDevServerHost") as? String
        return URL(string: "http://\(host ?? "localhost"):8080")!
        #endif
    }()

    static func live() throws -> AppEnvironment {
        let database = try AppDatabase.makeOnDisk()
        let library = PhotosScreenshotLibrary()
        let captureStore = GRDBCaptureStore(database: database)
        let folderStore = GRDBFolderStore(database: database)
        let appStateStore = GRDBAppStateStore(database: database)

        let installationAPIClient = URLSessionInstallationAPIClient(baseURL: developmentServerURL)
        // Apple Developer Program 미가입 상태라 AppAttestProvider 대신 우회 구현을 쓴다
        // (서버 cappick.attestation.mode=bypass와 짝). 계정이 생기면 여기만 바꾸면 된다.
        let attestationProvider = DevBypassAttestationProvider(appStateStore: appStateStore)
        let installationRegistrar = InstallationRegistrar(
            apiClient: installationAPIClient,
            attestationProvider: attestationProvider,
            credentialStore: KeychainCredentialStore()
        )

        // 분석(색인)과 검색이 같은 인스턴스를 써야 113MB 모델을 한 번만 띄운다.
        let embeddingService = OnnxEmbeddingService()
        let contentAnalysisService = ContentAnalysisService(
            jobAPIClient: URLSessionJobAPIClient(baseURL: developmentServerURL),
            installationRegistrar: installationRegistrar,
            captureStore: captureStore,
            imageProvider: PhotosImageDataProvider(),
            textRecognizer: PhotosVisionTextRecognizer(),
            embedder: embeddingService
        )
        let classificationService = ClassificationService(
            classificationAPIClient: URLSessionClassificationAPIClient(baseURL: developmentServerURL),
            installationRegistrar: installationRegistrar,
            captureStore: captureStore,
            folderStore: folderStore
        )
        let analysisQueueService = AnalysisQueueService(
            captureStore: captureStore,
            contentAnalysisService: contentAnalysisService,
            classificationService: classificationService,
            appStateStore: appStateStore
        )
        let searchService = SearchService(embedder: embeddingService, captureStore: captureStore)
        let reclassificationStore = GRDBReclassificationStore(database: database)
        let reclassificationService = ReclassificationService(
            captureStore: captureStore,
            folderStore: folderStore,
            reclassificationStore: reclassificationStore,
            classificationService: classificationService
        )
        let usageService = UsageService(
            usageAPIClient: URLSessionUsageAPIClient(baseURL: developmentServerURL),
            installationRegistrar: installationRegistrar
        )
        let appDataDeletionService = AppDataDeletionService(
            deletionAPIClient: URLSessionDeletionAPIClient(baseURL: developmentServerURL),
            installationRegistrar: installationRegistrar,
            database: database
        )

        return AppEnvironment(
            library: library,
            captureStore: captureStore,
            folderStore: folderStore,
            appStateStore: appStateStore,
            syncService: ScreenshotSyncService(library: library, captureStore: captureStore),
            installationRegistrar: installationRegistrar,
            thumbnailLoader: PhotosThumbnailLoader(),
            analysisQueueService: analysisQueueService,
            searchService: searchService,
            reclassificationStore: reclassificationStore,
            reclassificationService: reclassificationService,
            usageService: usageService,
            appDataDeletionService: appDataDeletionService
        )
    }
}
