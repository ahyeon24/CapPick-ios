import Photos
import UIKit

struct PhotosThumbnailLoader: ThumbnailLoading {
    private let imageManager = PHCachingImageManager()

    func thumbnail(for photoAssetID: String, targetSize: CGSize) async -> UIImage? {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [photoAssetID], options: nil)
        guard let asset = fetchResult.firstObject else { return nil }

        let options = PHImageRequestOptions()
        // .highQualityFormat은 콜백이 정확히 한 번만 온다 — .opportunistic처럼 저화질 프리뷰를
        // 먼저 주는 모드는 두 번째 콜백을 기다리다 continuation이 중복 resume될 위험이 있어 피한다.
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true

        return await withCheckedContinuation { continuation in
            imageManager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    func fullImage(for photoAssetID: String) async -> UIImage? {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [photoAssetID], options: nil)
        guard let asset = fetchResult.firstObject else { return nil }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat // 위 thumbnail(for:targetSize:)와 같은 이유로 단일 콜백 보장.
        options.isNetworkAccessAllowed = true

        return await withCheckedContinuation { continuation in
            imageManager.requestImage(
                for: asset,
                targetSize: PHImageManagerMaximumSize,
                contentMode: .aspectFit, // 정사각형으로 안 자르고 원본 비율을 유지한다 — 그리드 썸네일과의 차이.
                options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}
