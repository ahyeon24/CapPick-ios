import Photos
import UIKit

struct PhotosImageDataProvider: CaptureImageProviding {
    // 잠정치 — 실제 업로드 크기·품질 기준은 시스템 설계 §4 "품질과 비용 검증 후" 정하는 미정 항목이다.
    private static let maxDimension: CGFloat = 1600
    private static let jpegQuality: CGFloat = 0.8

    private let imageManager = PHCachingImageManager()

    func imageData(for photoAssetID: String) async -> Data? {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [photoAssetID], options: nil)
        guard let asset = fetchResult.firstObject else { return nil }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true

        let targetSize = CGSize(width: Self.maxDimension, height: Self.maxDimension)
        let image: UIImage? = await withCheckedContinuation { continuation in
            imageManager.requestImage(
                for: asset, targetSize: targetSize, contentMode: .aspectFit, options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
        return image?.jpegData(compressionQuality: Self.jpegQuality)
    }
}
