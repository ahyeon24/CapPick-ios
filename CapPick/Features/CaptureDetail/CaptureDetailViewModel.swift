import Foundation
import UIKit

// 화면설계서 DETAIL-01~06. DETAIL-03(글자 복사)은 서버 OCR을 안 쓴다 — LiveTextImageView가
// 이미지 위에서 기기 자체 Live Text로 바로 처리한다(CaptureDetailView 참고).
@MainActor @Observable
final class CaptureDetailViewModel {
    private(set) var capture: Capture
    private(set) var folders: [Folder] = []
    /// ··· > 폴더로 이동 메뉴에 보여줄 사용자 폴더 전체.
    private(set) var allFolders: [Folder] = []
    private(set) var fullImage: UIImage?
    /// 원본이 오기 전에 먼저 보여주는 작은 이미지(목록 썸네일과 같은 수준) — 넘길 때 로딩 표시
    /// 대신 흐릿한 사진이 먼저 보이게 한다(2026-10-17).
    private(set) var previewImage: UIImage?
    private var hasRequestedImage = false
    private(set) var isLoadingImage = false
    private(set) var isRetrying = false
    private(set) var errorMessage: String?
    /// true가 되면 View가 dismiss한다 — 제외 후 이전 BROWSE-01로 복귀(화면설계서 §9).
    private(set) var didExclude = false

    private let captureStore: any CaptureStoring
    private let folderStore: any FolderStoring
    private let analysisQueueService: AnalysisQueueService
    private let thumbnailLoader: any ThumbnailLoading
    /// 어느 폴더 화면에서 들어왔는지. 이동할 때 이 폴더에서만 뺀다 — nil(전체·미분류·검색)이면
    /// 지금 속한 폴더 전부에서 뺀다.
    private let sourceFolderID: String?

    init(
        capture: Capture, captureStore: any CaptureStoring, folderStore: any FolderStoring,
        analysisQueueService: AnalysisQueueService, thumbnailLoader: any ThumbnailLoading,
        sourceFolderID: String? = nil
    ) {
        self.capture = capture
        self.sourceFolderID = sourceFolderID
        self.captureStore = captureStore
        self.folderStore = folderStore
        self.analysisQueueService = analysisQueueService
        self.thumbnailLoader = thumbnailLoader
    }

    /// 목록에서 넘어온 capture는 오래됐을 수 있어 최신 상태로 다시 읽는다. 원본 이미지는 본문
    /// 표시를 막지 않도록 별도로 불러온다(§9: "원본 다운로드 중에는 진행 표시").
    /// fitting: 화면에 그릴 영역의 픽셀 크기. 이미지는 한 번만 불러온다 — 옆 사진 미리 불러오기와
    /// 화면에 나타날 때의 호출이 겹쳐도 다시 받지 않는다.
    func load(fitting targetSize: CGSize? = nil) async {
        errorMessage = nil
        do {
            if let latest = try await captureStore.fetchCapture(id: capture.id) {
                capture = latest
            }
            folders = try await folderStore.fetchFolders(containing: capture.id)
            allFolders = try await folderStore.fetchAll()
        } catch {
            errorMessage = "정보를 불러오지 못했어요."
        }

        guard !hasRequestedImage else { return }
        hasRequestedImage = true
        isLoadingImage = true
        previewImage = await thumbnailLoader.thumbnail(
            for: capture.photoAssetID, targetSize: CGSize(width: 360, height: 780))
        fullImage = await thumbnailLoader.fullImage(for: capture.photoAssetID, fitting: targetSize)
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

    /// pending 캡처는 자동 큐가 처리하므로 이 화면의 버튼은 그 상태에서는 안 보인다(View 참고).
    /// failed뿐 아니라 이미 성공(ready)한 캡처도 사용자가 원하면 다시 돌릴 수 있다(2026-09-25
    /// 사용자 결정) — 분석·분류를 처음부터 다시 하므로 폴더를 새로 만든 뒤 기존 캡처에 적용해보고
    /// 싶을 때도 이걸로 해결된다(RECLASS-01의 정식 "기존 캡처 일괄 적용"이 생기기 전 임시 대안).
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

    /// 다른 폴더로 옮긴다(2026-10-18 사용자 요청). 원래 폴더에서는 직접 제거(blocked + manual)로
    /// 빼서 자동 분류가 다시 넣지 않게 하고, 대상 폴더에는 직접 추가한다. 원본 사진은 그대로다.
    func move(to target: Folder) async {
        errorMessage = nil
        let sources = sourceFolderID.map { [$0] } ?? folders.map(\.id)
        do {
            for folderID in sources where folderID != target.id {
                try await folderStore.removeManually(captureID: capture.id, from: folderID)
            }
            try await folderStore.addManually(captureID: capture.id, to: target.id)
            folders = try await folderStore.fetchFolders(containing: capture.id)
        } catch {
            errorMessage = "폴더를 옮기지 못했어요."
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
