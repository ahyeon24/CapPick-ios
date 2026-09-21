import Photos

struct PhotosScreenshotLibrary: ScreenshotLibrary {
    var authorization: PhotoAuthorization {
        Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAuthorization() async -> PhotoAuthorization {
        Self.map(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    func fetchScreenshots() async -> [DiscoveredScreenshot] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "(mediaSubtype & %ld) != 0",
            Int(PHAssetMediaSubtype.photoScreenshot.rawValue)
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var screenshots: [DiscoveredScreenshot] = []
        screenshots.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            screenshots.append(DiscoveredScreenshot(
                assetID: asset.localIdentifier,
                capturedAt: asset.creationDate ?? Date(timeIntervalSince1970: 0),
                width: asset.pixelWidth,
                height: asset.pixelHeight
            ))
        }
        return screenshots
    }

    private static func map(_ status: PHAuthorizationStatus) -> PhotoAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .limited: .limited
        case .authorized: .authorized
        @unknown default: .denied
        }
    }
}
