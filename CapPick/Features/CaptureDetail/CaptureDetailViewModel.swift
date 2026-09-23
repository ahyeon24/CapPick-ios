import Foundation
import UIKit

// 화면설계서 DETAIL-01~06. DETAIL-03(글자 복사)은 서버 OCR을 안 쓴다 — LiveTextImageView가
// 이미지 위에서 기기 자체 Live Text로 바로 처리한다(CaptureDetailView 참고).
@MainActor @Observable
final class CaptureDetailViewModel {
    private(set) var capture: Capture
    private(set) var folders: [Folder] = []
    private(set) var fullImage: UIImage?
    private(set) var isLoadingImage = false
    private(set) var isRetrying = false
    private(set) var errorMessage: String?
    /// true가 되면 View가 dismiss한다 — 제외 후 이전 BROWSE-01로 복귀(화면설계서 §9).
    private(set) var didExclude = false

    private let captureStore: any CaptureStoring
    private let folderStore: any FolderStoring
    private let analysisQueueService: AnalysisQueueService
    private let thumbnailLoader: any ThumbnailLoading

    init(
        capture: Capture, captureStore: any CaptureStoring, folderStore: any FolderStoring,
        analysisQueueService: AnalysisQueueService, thumbnailLoader: any ThumbnailLoading
    ) {
        self.capture = capture
        self.captureStore = captureStore
        self.folderStore = folderStore
        self.analysisQueueService = analysisQueueService
        self.thumbnailLoader = thumbnailLoader
    }

    /// 목록에서 넘어온 capture는 오래됐을 수 있어 최신 상태로 다시 읽는다. 원본 이미지는 본문
    /// 표시를 막지 않도록 별도로 불러온다(§9: "원본 다운로드 중에는 진행 표시").
    func load() async {
        errorMessage = nil
        do {
            if let latest = try await captureStore.fetchCapture(id: capture.id) {
                capture = latest
            }
            folders = try await folderStore.fetchFolders(containing: capture.id)
        } catch {
            errorMessage = "정보를 불러오지 못했어요."
        }

        isLoadingImage = true
        fullImage = await thumbnailLoader.fullImage(for: capture.photoAssetID)
        isLoadingImage = false
    }

    func toggleFavorite() async {
        let newValue = !capture.favorite
        do {
            try await captureStore.setFavorite(capture.id, favorite: newValue)
            capture.favorite = newValue
        } catch {
            errorMessage = "즐겨찾기를 바꾸지 못했어요."
        }
    }

    /// pending 캡처는 자동 큐가 처리하므로 이 화면에서는 failed 상태의 수동 재시도만 의미가
    /// 있다(BrowseViewModel.retry와 같은 이유·같은 패턴).
    func retry() async {
        guard !isRetrying else { return }
        isRetrying = true
        defer { isRetrying = false }
        errorMessage = nil
        do {
            try await analysisQueueService.retry(capture)
            await load()
        } catch {
            errorMessage = "분석에 실패했어요: \(error)"
        }
    }

    /// DETAIL-06. 원본 사진은 건드리지 않는다 — capture.excludedAt만 채운다.
    func exclude() async {
        errorMessage = nil
        do {
            try await captureStore.exclude(capture.id, at: Date())
            didExclude = true
        } catch {
            errorMessage = "제외하지 못했어요."
        }
    }
}
