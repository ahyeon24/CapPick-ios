import Foundation

// ThumbnailLoading과 별개인 이유: 썸네일은 화면 표시용 작은 UIImage, 이쪽은 서버 업로드용
// 압축 바이트다. 화면 크기와 업로드 크기는 서로 다른 정책이라 프로토콜을 나눴다.
protocol CaptureImageProviding: Sendable {
    /// 업로드에 적합한 크기로 리사이즈·압축한 JPEG 바이트. 원본을 그대로 올리지 않는다
    /// (시스템 설계 §4: "필요한 작업 범위만 전송; 상시 원본 업로드 아님").
    func imageData(for photoAssetID: String) async -> Data?
}
