import Foundation
import Observation

// FolderEditView·FolderListView 두 진입점이 시트 아이템으로 공유한다.
struct ReclassificationTarget: Identifiable {
    let folder: Folder
    let mode: ReclassificationMode
    var id: String { folder.id }
}

// 화면설계서 §11 RECLASS-01. FolderEditView("기존 캡처에도 적용")와 FolderListView("재분류"
// 스와이프 액션) 두 진입점이 같은 화면·뷰모델을 쓴다 — mode로만 문구를 구분한다.
@MainActor @Observable
final class ReclassificationViewModel {
    struct PreviewItem: Identifiable {
        let capture: Capture
        let evidence: String?
        var id: String { capture.id }
    }

    let folder: Folder
    let mode: ReclassificationMode
    let thumbnailLoader: any ThumbnailLoading

    private(set) var toAdd: [PreviewItem] = []
    private(set) var toRemove: [PreviewItem] = []
    private(set) var isLoading = false
    private(set) var isApplying = false
    private(set) var errorMessage: String?
    /// true가 되면 View가 화면을 닫는다 — 적용·취소·"바뀔 것 없음" 세 경우 모두 여기로 온다.
    private(set) var didFinish = false

    private var runID: String?
    private let reclassificationService: ReclassificationService
    private let reclassificationStore: any ReclassificationStoring
    private let captureStore: any CaptureStoring

    init(
        folder: Folder, mode: ReclassificationMode, reclassificationService: ReclassificationService,
        reclassificationStore: any ReclassificationStoring, captureStore: any CaptureStoring,
        thumbnailLoader: any ThumbnailLoading
    ) {
        self.folder = folder
        self.mode = mode
        self.reclassificationService = reclassificationService
        self.reclassificationStore = reclassificationStore
        self.captureStore = captureStore
        self.thumbnailLoader = thumbnailLoader
    }

    /// 후보 캡처 수만큼 실제 Gemini 호출이 나간다(ReclassificationService 주석 참고) — 이 화면에
    /// 들어오는 것 자체(폴더 메뉴의 "재분류", 생성 시트의 "기존 캡처에도 적용")가 이미 사용자의
    /// 명시적인 트리거라 별도 확인 알럿은 두지 않는다. 다른 AI 트리거 액션들(검색·재시도)과 같은 패턴.
    func loadPreview() async {
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        do {
            let run = try await reclassificationService.preview(folderID: folder.id, mode: mode)
            runID = run.id
            let items = try await reclassificationStore.fetchItems(runID: run.id)
            guard !items.isEmpty else {
                didFinish = true
                return
            }

            var add: [PreviewItem] = []
            var remove: [PreviewItem] = []
            for item in items {
                guard let capture = try await captureStore.fetchCapture(id: item.captureID) else { continue }
                let previewItem = PreviewItem(capture: capture, evidence: item.evidence)
                switch item.action {
                case .add: add.append(previewItem)
                case .remove: remove.append(previewItem)
                }
            }
            toAdd = add
            toRemove = remove
        } catch ReclassificationError.alreadyInProgress {
            errorMessage = "이미 진행 중인 재분류가 있어요. 잠시 후 다시 시도해주세요."
        } catch {
            errorMessage = "재분류 판정에 실패했어요."
        }
    }

    func confirm() async {
        guard let runID, !isApplying else { return }
        isApplying = true
        defer { isApplying = false }
        errorMessage = nil
        do {
            try await reclassificationService.apply(runID: runID)
            didFinish = true
        } catch {
            errorMessage = "적용하지 못했어요."
        }
    }

    /// 확인 없이 닫을 때 — 기존 소속을 그대로 유지한다.
    func discard() async {
        if let runID {
            try? await reclassificationService.cancel(runID: runID)
        }
        didFinish = true
    }
}
