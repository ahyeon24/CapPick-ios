import UIKit

// 사진 보관함에서 캡처 썸네일 이미지를 가져오는 경계. ScreenshotLibrary가 "무엇이 있는지"를
// 다룬다면 이쪽은 "그걸 화면에 어떻게 그리는지"를 다룬다 — 책임이 달라 별도 프로토콜로 뗐다.
protocol ThumbnailLoading: Sendable {
    func thumbnail(for photoAssetID: String, targetSize: CGSize) async -> UIImage?
}
