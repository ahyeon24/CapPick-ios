import Foundation
import Observation

/// 재분류(RECLASS-01)를 화면이 아니라 앱 수명 동안 돌린다(2026-10-18 사용자 제보로 바꿈). 전에는
/// 판정이 재분류 시트의 `.task`에 묶여 있어서, 시트를 내리면 계산이 멈추고 미리보기를 확인하지 않으면
/// 아무 것도 반영되지 않았다 — 새로 만든 "뷰티" 폴더가 계속 비어 있던 원인이다.
///
/// - 새 폴더의 "기존 캡처에도 적용"(`.initialApply`): 확인 없이 끝나는 대로 바로 반영한다. 폴더를
///   만들며 이미 켠 선택이라서다. 잘못 들어간 건 폴더에서 빼거나 옮기면 된다.
/// - "기존 캡처 재분류"(`.reclassify`): 빠지는 캡처도 생길 수 있어 지금처럼 결과를 보여주고 확인을
///   받는다. 시트를 닫아도 계산은 계속되고, 결과는 확인할 때까지 남는다.
///
/// 진행 상황은 `jobs`로 노출해 홈 폴더 카드 등이 "분류 중 12/86"을 보여준다.
@MainActor @Observable
final class ReclassificationCoordinator {
    enum Phase: Equatable {
        case running(done: Int, total: Int)
        /// `.reclassify` 결과가 확인을 기다리는 중.
        case awaitingConfirmation(runID: String)
        /// 끝남(반영했거나, 바뀔 게 없었거나, 버렸음).
        case finished(added: Int)
        case failed(message: String)
    }

    struct Job: Equatable {
        let mode: ReclassificationMode
        var phase: Phase
    }

    private(set) var jobs: [String: Job] = [:]
    /// 반영이 끝날 때마다 오른다 — 홈이 지켜보다가 폴더 카드 개수를 새로 고친다.
    private(set) var completedCount = 0

    private let service: ReclassificationService
    private let reclassificationStore: any ReclassificationStoring
    private var tasks: [String: Task<Void, Never>] = [:]

    init(service: ReclassificationService, reclassificationStore: any ReclassificationStoring) {
        self.service = service
        self.reclassificationStore = reclassificationStore
    }

    func job(for folderID: String) -> Job? { jobs[folderID] }

    /// 이미 계산 중이거나 확인을 기다리는 실행이 있으면 새로 시작하지 않는다(그 결과를 보여주면 된다).
    func start(folder: Folder, mode: ReclassificationMode) {
        if let job = jobs[folder.id] {
            switch job.phase {
            case .running, .awaitingConfirmation: return
            case .finished, .failed: break
            }
        }
        jobs[folder.id] = Job(mode: mode, phase: .running(done: 0, total: 0))
        tasks[folder.id] = Task { [weak self] in
            await self?.run(folder: folder, mode: mode)
        }
    }

    func confirm(folderID: String) async {
        guard case .awaitingConfirmation(let runID) = jobs[folderID]?.phase else { return }
        do {
            let added = try await addCount(runID: runID)
            try await service.apply(runID: runID)
            jobs[folderID]?.phase = .finished(added: added)
            completedCount += 1
        } catch {
            jobs[folderID]?.phase = .failed(message: "적용하지 못했어요.")
        }
    }

    func discard(folderID: String) async {
        guard case .awaitingConfirmation(let runID) = jobs[folderID]?.phase else { return }
        try? await service.cancel(runID: runID)
        jobs[folderID]?.phase = .finished(added: 0)
    }

    private func run(folder: Folder, mode: ReclassificationMode) async {
        defer { tasks[folder.id] = nil }
        do {
            // 이 앱 실행에서 계산 중인 게 없는데 previewing으로 남은 실행은 이전에 중단된 것이다.
            try await service.cancelStaleRun(folderID: folder.id)
            let run = try await service.preview(folderID: folder.id, mode: mode) { [weak self] done, total in
                await self?.setProgress(folderID: folder.id, done: done, total: total)
            }
            let items = try await reclassificationStore.fetchItems(runID: run.id)
            if items.isEmpty {
                jobs[folder.id]?.phase = .finished(added: 0)
                return
            }
            switch mode {
            case .initialApply:
                let added = items.filter { $0.action == .add }.count
                try await service.apply(runID: run.id)
                jobs[folder.id]?.phase = .finished(added: added)
                completedCount += 1
            case .reclassify:
                jobs[folder.id]?.phase = .awaitingConfirmation(runID: run.id)
            }
        } catch {
            jobs[folder.id]?.phase = .failed(message: "기존 캡처를 분류하지 못했어요.")
        }
    }

    private func setProgress(folderID: String, done: Int, total: Int) {
        guard case .running = jobs[folderID]?.phase else { return }
        jobs[folderID]?.phase = .running(done: done, total: total)
    }

    private func addCount(runID: String) async throws -> Int {
        try await reclassificationStore.fetchItems(runID: runID).filter { $0.action == .add }.count
    }
}
