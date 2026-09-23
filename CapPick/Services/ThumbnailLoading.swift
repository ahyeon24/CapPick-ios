import UIKit

// 사진 보관함에서 캡처 썸네일 이미지를 가져오는 경계. ScreenshotLibrary가 "무엇이 있는지"를
// 다룬다면 이쪽은 "그걸 화면에 어떻게 그리는지"를 다룬다 — 책임이 달라 별도 프로토콜로 뗐다.
protocol ThumbnailLoading: Sendable {
    func thumbnail(for photoAssetID: String, targetSize: CGSize) async -> UIImage?

    /// DETAIL-01 확대 보기용 — 그리드 썸네일(정사각형으로 자름)과 달리 원본 가로세로 비율을
    /// 유지한 화면 표시용 고화질 이미지.
    func fullImage(for photoAssetID: String) async -> UIImage?
}
