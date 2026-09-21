enum PhotoAuthorization: Equatable, Sendable {
    case notDetermined
    case denied
    /// 자녀 보호 기능 등으로 앱이 요청을 바꿀 수 없는 상태.
    case restricted
    /// 사용자가 일부 사진만 허용했다 — 허용된 사진 중 스크린샷만 대상이다 (화면설계서 ON-02).
    case limited
    case authorized

    var canReadPhotos: Bool { self == .authorized || self == .limited }
}

// 사진 보관함(원본 소유자)에 접근하는 경계. 실제 구현은 Photos 프레임워크, 테스트에서는 가짜로 교체한다.
protocol ScreenshotLibrary: Sendable {
    var authorization: PhotoAuthorization { get }
    /// 이미 결정된 상태라면 권한 창을 다시 띄우지 않고 현재 상태를 돌려준다.
    func requestAuthorization() async -> PhotoAuthorization
    /// 접근 가능한 스크린샷 전체, 최근순.
    func fetchScreenshots() async -> [DiscoveredScreenshot]
}
