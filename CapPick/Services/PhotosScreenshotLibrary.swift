import Photos

struct PhotosScreenshotLibrary: ScreenshotLibrary {
    /// 어떤 스크린샷을 불러올지. 시연 영상 녹화 때만 `.demo`를 쓴다(AppEnvironment 참고) — 개인
    /// 스크린샷이 화면에 나오지 않게 지정한 앨범 것과, 녹화 중에 새로 찍은 것만 본다.
    enum Scope: Sendable {
        case all
        case demo(albumTitle: String, newSince: Date)
    }

    var scope: Scope = .all

    var authorization: PhotoAuthorization {
        Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAuthorization() async -> PhotoAuthorization {
        Self.map(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    func fetchScreenshots() async -> [DiscoveredScreenshot] {
        switch scope {
        case .all:
            return Self.screenshots(PHAsset.fetchAssets(with: .image, options: Self.options()))
        case .demo(let albumTitle, let newSince):
            var byID: [String: DiscoveredScreenshot] = [:]
            let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
            albums.enumerateObjects { album, _, _ in
                guard album.localizedTitle == albumTitle else { return }
                for shot in Self.screenshots(PHAsset.fetchAssets(in: album, options: Self.options())) {
                    byID[shot.assetID] = shot
                }
            }
            let recent = Self.options(extra: NSPredicate(format: "creationDate >= %@", newSince as NSDate))
            for shot in Self.screenshots(PHAsset.fetchAssets(with: .image, options: recent)) {
                byID[shot.assetID] = shot
            }
            return byID.values.sorted { $0.capturedAt > $1.capturedAt }
        }
    }

    private static func options(extra: NSPredicate? = nil) -> PHFetchOptions {
        let options = PHFetchOptions()
        let screenshot = NSPredicate(
            format: "(mediaSubtype & %ld) != 0",
            Int(PHAssetMediaSubtype.photoScreenshot.rawValue)
        )
        options.predicate = extra.map { NSCompoundPredicate(andPredicateWithSubpredicates: [screenshot, $0]) } ?? screenshot
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return options
    }

    private static func screenshots(_ assets: PHFetchResult<PHAsset>) -> [DiscoveredScreenshot] {
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
