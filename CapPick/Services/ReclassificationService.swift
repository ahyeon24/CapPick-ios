import Foundation

enum ReclassificationError: Error, Equatable {
    /// 화면설계서 §11 "실패·처리 중 중복 실행을 막고" — 같은 폴더에 확정 안 된 실행이 있으면 새로 못 만든다.
    case alreadyInProgress
    case folderNotFound
}

/// RECLASS-01. 폴더 하나의 기준으로 이미 분석된 캡처 전체를 다시 판정해서 추가·제거 예정 목록을
/// 만들고(preview), 사용자가 확인한 뒤에야 실제 소속에 반영한다(apply). content_analysis는 다시
/// 안 돌린다(기능명세서 §3.3.2: "기존 검색·분석 정보를 재사용한다") — ClassificationService의
/// 판정 로직만 폴더 하나로 좁혀 재사용한다.
///
/// ⚠️ 비용 주의: preview()는 후보 캡처 수만큼 실제 Gemini 호출을 만든다(캡처마다 판정 하나씩) —
/// 캡처가 많은 폴더에서 부르면 그만큼 무료 티어 한도를 쓴다. 호출자가 실행 전에 사용자에게 이
/// 비용을 알려야 한다(세션 전체에서 지켜온 "제미나이 호출 전에 먼저 말한다" 규칙과 같은 이유).
actor ReclassificationService {
    private let captureStore: any CaptureStoring
    private let folderStore: any FolderStoring
    private let reclassificationStore: any ReclassificationStoring
    private let classificationService: ClassificationService

    init(
        captureStore: any CaptureStoring,
        folderStore: any FolderStoring,
        reclassificationStore: any ReclassificationStoring,
        classificationService: ClassificationService
    ) {
        self.captureStore = captureStore
        self.folderStore = folderStore
        self.reclassificationStore = reclassificationStore
        self.classificationService = classificationService
    }

    func preview(folderID: String, mode: ReclassificationMode) async throws -> ReclassificationRun {
        guard try await reclassificationStore.activeRun(folderID: folderID) == nil else {
            throw ReclassificationError.alreadyInProgress
        }
        guard let folder = try await folderStore.fetchFolder(id: folderID) else {
            throw ReclassificationError.folderNotFound
        }

        // 폴더의 현재 criteriaVersion·membershipRevision을 그대로 고정한다(ERD: "미리보기 기준과
        // 소속 버전 고정") — apply()는 나중에 이 값이 그때도 여전히 최신인지 확인하고, 그 사이
        // 기준이 바뀌었으면 그 항목만 조용히 건너뛴다(FolderStoring의 스테일 가드 재사용).
        let run = try await reclassificationStore.createRun(
            folderID: folderID, criteriaVersion: folder.criteriaVersion,
            membershipRevision: folder.membershipRevision, mode: mode)

        let candidates = try await captureStore.fetchAnalyzedCaptures()
        let membershipByCapture = Dictionary(
            uniqueKeysWithValues: try await folderStore.fetchMemberships(of: folderID).map { ($0.captureID, $0) })

        var items: [ReclassificationItem] = []
        for capture in candidates {
            // 이 캡처 하나의 판정이 실패해도(예: Gemini 일시적 과부하) 전체를 포기하지 않고 다음
            // 캡처로 넘어간다 — AnalysisQueueService의 "실패해도 다음으로" 패턴과 같은 이유.
            guard let decision = try? await classificationService.evaluateSingleFolder(capture: capture, folder: folder) else {
                continue
            }
            let existing = membershipByCapture[capture.id]

            switch decision.decision {
            case .match:
                if existing?.state == .present { continue } // 이미 소속됨 — 변화 없음
                if existing?.state == .blocked, existing?.source == .manual { continue } // 사용자가 직접 뺀 캡처는 다시 안 올림
                items.append(ReclassificationItem(
                    runID: run.id, captureID: capture.id, action: .add, evidence: decision.evidence,
                    expectedMembershipRevision: folder.membershipRevision, state: ReclassificationItemState.pending))
            case .noMatch, .uncertain:
                // auto + present인 것만 제거 후보 — manual 소속은 미리보기 단계에서부터 절대 안 보여준다.
                guard let existing, existing.state == .present, existing.source == .auto else { continue }
                items.append(ReclassificationItem(
                    runID: run.id, captureID: capture.id, action: .remove, evidence: decision.evidence,
                    expectedMembershipRevision: folder.membershipRevision, state: ReclassificationItemState.pending))
            }
        }

        if items.isEmpty {
            // 바뀔 게 없으면 확인받을 것도 없다 — 빈 실행을 previewing으로 남겨서 다음 재분류
            // 시도를 막지 않는다.
            try await reclassificationStore.setRunState(run.id, state: ReclassificationRunState.applied)
        } else {
            try await reclassificationStore.saveItems(items)
        }
        return run
    }

    /// 사용자가 미리보기를 확인한 뒤 실제로 반영한다. 항목별로 독립적으로 적용하고, 그 사이 폴더
    /// 기준이 바뀐 항목은 조용히 건너뛴다(skipped) — 전체를 실패시키지 않는다.
    func apply(runID: String) async throws {
        guard let run = try await reclassificationStore.fetchRun(id: runID) else { return }
        let items = try await reclassificationStore.fetchItems(runID: runID)

        for item in items {
            let result: AutoMatchResult
            switch item.action {
            case .add:
                result = try await folderStore.applyAutoMatch(
                    captureID: item.captureID, to: run.folderID,
                    evidence: item.evidence, criteriaVersion: run.criteriaVersion)
            case .remove:
                result = try await folderStore.applyAutoMismatchRemoval(
                    captureID: item.captureID, from: run.folderID, criteriaVersion: run.criteriaVersion)
            }
            try await reclassificationStore.setItemState(
                runID: runID, captureID: item.captureID,
                state: result == .applied ? ReclassificationItemState.applied : ReclassificationItemState.skipped)
        }
        try await reclassificationStore.setRunState(runID, state: ReclassificationRunState.applied)
    }

    /// 확인 없이 닫을 때 부른다 — 기존 소속을 그대로 유지한다(화면설계서 §11: "취소 시 기존 소속을
    /// 유지한다"). 계산된 항목은 버려지고, 이 폴더는 다시 재분류를 시작할 수 있다.
    func cancel(runID: String) async throws {
        try await reclassificationStore.setRunState(runID, state: ReclassificationRunState.cancelled)
    }
}
