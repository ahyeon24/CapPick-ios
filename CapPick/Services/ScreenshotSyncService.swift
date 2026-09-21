// 사진 보관함의 스크린샷을 로컬 캡처 목록에 맞춘다 (기능명세서 PHOTO-02·04·06).
struct ScreenshotSyncService: Sendable {
    enum Outcome: Equatable, Sendable {
        /// 사진을 읽을 수 없는 상태 — 아무것도 바꾸지 않는다.
        case skipped(PhotoAuthorization)
        case synced(ScreenshotSyncResult)
    }

    let library: any ScreenshotLibrary
    let captureStore: any CaptureStoring

    func sync() async throws -> Outcome {
        let authorization = library.authorization
        // 권한이 없을 때 빈 목록으로 맞추면 기존 캡처가 전부 접근 불가로 바뀌므로 여기서 막는다.
        guard authorization.canReadPhotos else { return .skipped(authorization) }
        let screenshots = await library.fetchScreenshots()
        return .synced(try await captureStore.registerDiscovered(screenshots))
    }
}
