import Foundation
@testable import CapPick

// 테스트는 한 번에 한 흐름만 돌리므로 내부 상태를 잠그지 않는다.
final class FakeScreenshotLibrary: ScreenshotLibrary, @unchecked Sendable {
    var authorization: PhotoAuthorization
    var authorizationAfterRequest: PhotoAuthorization
    var screenshots: [DiscoveredScreenshot]
    private(set) var requestCount = 0
    private(set) var fetchCount = 0

    init(
        authorization: PhotoAuthorization = .authorized,
        authorizationAfterRequest: PhotoAuthorization? = nil,
        screenshots: [DiscoveredScreenshot] = []
    ) {
        self.authorization = authorization
        self.authorizationAfterRequest = authorizationAfterRequest ?? authorization
        self.screenshots = screenshots
    }

    func requestAuthorization() async -> PhotoAuthorization {
        requestCount += 1
        authorization = authorizationAfterRequest
        return authorization
    }

    func fetchScreenshots() async -> [DiscoveredScreenshot] {
        fetchCount += 1
        return screenshots
    }
}

func shot(_ id: String, at seconds: TimeInterval = 1_000) -> DiscoveredScreenshot {
    DiscoveredScreenshot(
        assetID: id,
        capturedAt: Date(timeIntervalSince1970: seconds),
        width: 1170,
        height: 2532
    )
}
