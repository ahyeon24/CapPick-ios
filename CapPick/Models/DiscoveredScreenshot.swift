import Foundation

// 사진 보관함에서 방금 찾아낸 스크린샷 한 장. 아직 캡픽에 등록되기 전의 정보다.
struct DiscoveredScreenshot: Equatable, Sendable {
    let assetID: String
    let capturedAt: Date
    let width: Int
    let height: Int
}

// 사진 보관함과 로컬 캡처 목록을 맞춘 결과 (기능명세서 PHOTO-04·PHOTO-06).
struct ScreenshotSyncResult: Equatable, Sendable {
    let registered: Int
    let restored: Int
    let becameUnavailable: Int
}
