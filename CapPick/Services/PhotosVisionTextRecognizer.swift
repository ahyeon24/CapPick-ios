import Photos
import Vision

/// Apple Vision으로 기기 안에서 글자를 읽는다(2026-10-08, AI 출력 토큰 절감 목적 — 사용자 결정).
/// DETAIL-01의 Live Text와 같은 계열의 온디바이스 인식이라 서버·AI 비용이 들지 않는다.
struct PhotosVisionTextRecognizer: TextRecognizing {
    // 한국어를 먼저 둔다 — Vision은 이 순서를 우선순위로 쓴다. 스크린샷에 흔한 영어를 같이 받는다.
    private static let languages = ["ko-KR", "en-US"]

    func recognizeText(for photoAssetID: String) async -> String? {
        guard let (data, orientation) = await Self.originalImageData(for: photoAssetID) else { return nil }
        // Vision의 perform은 동기 호출이고 큰 스크린샷은 1초 넘게 걸린다 — 호출한 actor를 막지 않게 뺀다.
        return await Task.detached(priority: .utility) {
            Self.recognize(data: data, orientation: orientation)
        }.value
    }

    private static func originalImageData(for photoAssetID: String) async -> (Data, CGImagePropertyOrientation)? {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [photoAssetID], options: nil)
        guard let asset = fetchResult.firstObject else { return nil }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true

        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, orientation, _ in
                continuation.resume(returning: data.map { ($0, orientation) })
            }
        }
    }

    private static func recognize(data: Data, orientation: CGImagePropertyOrientation) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true

        do {
            try VNImageRequestHandler(data: data, orientation: orientation).perform([request])
        } catch {
            return nil
        }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
}
