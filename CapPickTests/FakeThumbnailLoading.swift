import UIKit
@testable import CapPick

final class FakeThumbnailLoading: ThumbnailLoading, @unchecked Sendable {
    var imageToReturn: UIImage?

    func thumbnail(for photoAssetID: String, targetSize: CGSize) async -> UIImage? {
        imageToReturn
    }

    func fullImage(for photoAssetID: String) async -> UIImage? {
        imageToReturn
    }
}
