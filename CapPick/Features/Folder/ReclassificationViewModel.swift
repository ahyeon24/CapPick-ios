import Foundation
import Observation

// FolderEditView·FolderListView 두 진입점이 시트 아이템으로 공유한다.
struct ReclassificationTarget: Identifiable {
    let folder: Folder
    let mode: ReclassificationMode
    var id: String { folder.id }
}

// 화면설계서 §11 RECLASS-01 "기존 캡처 재분류" 확인 화면의 뷰모델. 계산 자체는
// ReclassificationCoordinator가 앱 수명 동안 돌린다 — 이 화면은 진행 상황과 결과를 보여주고 확인·
// 취소만 전달한다. 화면을 닫아도 계산은 계속되고, 다시 열면 같은 진행 상황·결과가 보인다.
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
    private(set) var isApplying = false
    /// true가 되면 View가 화면을 닫는다 — 적용·취소·"바뀔 것 없음" 모두 여기로 온다.
    private(set) var didFinish = false
    private var loadedRunID: String?

    private let coordinator: ReclassificationCoordinator
    private let reclassificationStore: any ReclassificationStoring
    private let captureStore: any CaptureStoring

    init(
        folder: Folder, mode: ReclassificationMode, coordinator: ReclassificationCoordinator,
        reclassificationStore: any ReclassificationStoring, captureStore: any CaptureStoring,
        thumbnailLoader: any ThumbnailLoading
    ) {
        self.folder = folder
        self.mode = mode
        self.coordinator = coordinator
        self.reclassificationStore = reclassificationStore
        self.captureStore = captureStore
        self.thumbnailLoader = thumbnailLoader
    }

    var phase: ReclassificationCoordinator.Phase? { coordinator.job(for: folder.id)?.phase }

    var isLoading: Bool {
        if case .running = phase { return true }
        return false
    }

    var progressText: String? {
        guard case .running(let done, let total) = phase, total > 0 else { return nil }
        return "\(done) / \(total)장 판정"
    }

    var errorMessage: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    /// 화면이 나타날 때 — 진행 중이거나 확인을 기다리는 실행이 있으면 그걸 이어서 보여준다.
    func start() {
        coordinator.start(folder: folder, mode: mode)
    }

    /// phase가 바뀔 때마다 부른다. 결과가 나오면 미리보기 목록을 채우고, 끝났으면 화면을 닫는다.
    func phaseChanged() async {
        switch phase {
        case .awaitingConfirmation(let runID):
            guard loadedRunID != runID else { return }
            loadedRunID = runID
            await loadItems(runID: runID)
        case .finished:
            didFinish = true
        case .running, .failed, .none:
            break
        }
    }

    func confirm() async {
        guard !isApplying else { return }
        isApplying = true
        defer { isApplying = false }
        await coordinator.confirm(folderID: folder.id)
    }

    /// 결과를 적용하지 않고 버린다 — 기존 소속을 그대로 유지한다.
    func discard() async {
        await coordinator.discard(folderID: folder.id)
        didFinish = true
    }

    private func loadItems(runID: String) async {
        guard let items = try? await reclassificationStore.fetchItems(runID: runID) else { return }
        var add: [PreviewItem] = []
        var remove: [PreviewItem] = []
        for item in items {
            guard let capture = try? await captureStore.fetchCapture(id: item.captureID) else { continue }
            let previewItem = PreviewItem(capture: capture, evidence: item.evidence)
            switch item.action {
            case .add: add.append(previewItem)
            case .remove: remove.append(previewItem)
            }
        }
        toAdd = add
        toRemove = remove
    }
}
