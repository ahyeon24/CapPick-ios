// 앱에서 쓰는 저장소·서비스를 한 곳에서 조립한다. 화면은 여기서 만든 인스턴스를 주입받는다.
struct AppEnvironment: Sendable {
    let library: any ScreenshotLibrary
    let captureStore: any CaptureStoring
    let folderStore: any FolderStoring
    let appStateStore: any AppStateStoring
    let syncService: ScreenshotSyncService

    static func live() throws -> AppEnvironment {
        let database = try AppDatabase.makeOnDisk()
        let library = PhotosScreenshotLibrary()
        let captureStore = GRDBCaptureStore(database: database)
        return AppEnvironment(
            library: library,
            captureStore: captureStore,
            folderStore: GRDBFolderStore(database: database),
            appStateStore: GRDBAppStateStore(database: database),
            syncService: ScreenshotSyncService(library: library, captureStore: captureStore)
        )
    }
}
