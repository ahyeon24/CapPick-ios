import Foundation

enum ClassificationError: Error, Equatable {
    case jobFailed(code: String)
    case timedOut
}

/// AI-03 자동 분류. content_analysis가 끝난 캡처 하나를 실제 사용자 폴더들의 분류 기준과 비교해서
/// 직접 근거가 있는 폴더에 자동으로 추가한다(기능명세서 §3.3.1). 사용자가 기준 텍스트를 안 적은
/// 폴더는 폴더 이름을 기준으로 대신 쓴다(effectiveCriteria(for:), 2026-09-25 사용자 결정 — 기준을
/// 입력하는 걸 귀찮아할 사용자가 많을 거라 판단). classificationState 마킹은 ContentAnalysisService와
/// 같은 이유로 이 서비스의 책임이 아니다 — AnalysisQueueService가 한다.
actor ClassificationService {
    private let classificationAPIClient: any ClassificationAPIClient
    private let installationRegistrar: InstallationRegistrar
    private let captureStore: any CaptureStoring
    private let folderStore: any FolderStoring

    // ContentAnalysisService와 같은 잠정치 — poll_after_seconds 사이 재시도 횟수 상한.
    private let maxPollAttempts = 30

    init(
        classificationAPIClient: any ClassificationAPIClient,
        installationRegistrar: InstallationRegistrar,
        captureStore: any CaptureStoring,
        folderStore: any FolderStoring
    ) {
        self.classificationAPIClient = classificationAPIClient
        self.installationRegistrar = installationRegistrar
        self.captureStore = captureStore
        self.folderStore = folderStore
    }

    func classify(_ capture: Capture) async throws {
        guard let analysis = try await captureStore.fetchAnalysis(for: capture.id) else {
            // content_analysis가 성공한 캡처만 분류 대상이라 원래 없으면 안 되는 상태 — 방어적으로 끝낸다.
            return
        }

        // 폴더 기준 텍스트를 안 적은 사용자도 많을 거라(2026-09-25 사용자 결정), 비어있으면 폴더
        // 이름을 그대로 기준으로 쓴다 — 이름이 "중요"처럼 모호해서 잘못 판단될 위험은 AI가 그
        // 경우 uncertain을 내도록 프롬프트에 맡긴다(서버 GeminiClassificationClient 참고). 사용자가
        // 명시적으로 적은 기준은 항상 그대로 우선한다.
        let folders = try await folderStore.fetchAll()
        // 폴더가 하나도 없으면 판정할 것도 없다 — 네트워크를 아예 안 탄다(무료 티어 비용 절약,
        // SearchService가 임베딩 버전 없을 때 서버를 안 부르는 것과 같은 패턴).
        guard !folders.isEmpty else { return }

        let credential = try await installationRegistrar.ensureRegistered()
        // capture.analysisAttempt를 그대로 재사용한다(content_analysis의 Idempotency-Key와 같은
        // 값) — analysisRevision만으로는 부족하다: Gemini의 OCR·관찰 내용 문구는 같은 이미지를
        // 다시 분석해도 토씨까지 똑같다는 보장이 없어서, "다시 분석하기"로 content_analysis를
        // 재실행하면 분석 결과 텍스트가 살짝 달라질 수 있는데 옛 분류 요청과 같은 키를 쓰면
        // 서버가 "같은 키, 다른 내용"으로 보고 409 IDEMPOTENCY_CONFLICT를 낸다(2026-09-25 실제
        // 발견 — 재분석은 성공했는데 분류만 "보류"로 떨어지는 것으로 나타났다). attempt를 같이
        // 쓰면 재시도할 때마다 content_analysis와 classification의 키가 함께 새로워진다.
        let idempotencyKey = "classification-\(capture.id)-r\(analysis.analysisRevision)-a\(capture.analysisAttempt)"
        let folderInputs = folders.map {
            ClassificationFolderInput(id: $0.id, criteriaText: Self.effectiveCriteria(for: $0), criteriaVersion: $0.criteriaVersion)
        }

        let decisions = try await submitAndPoll(
            capture: capture, analysis: analysis, folders: folderInputs,
            idempotencyKey: idempotencyKey, credential: credential)

        // classification은 소속을 저장하는 API가 아니다(API 명세 §4) — 실제 반영은 여기, 로컬에서 한다.
        // no_match·uncertain은 아무 것도 안 한다(추가도 제거도 없음 — 기존 수동 소속은 항상 유지).
        for decision in decisions where decision.decision == .match {
            _ = try await folderStore.applyAutoMatch(
                captureID: capture.id, to: decision.folderId,
                evidence: decision.evidence, criteriaVersion: decision.criteriaVersion)
        }
    }

    /// RECLASS-01(ReclassificationService)이 쓴다 — 이미 분석된 캡처를 폴더 하나의 기준으로만
    /// 다시 판정한다. classify(_:)와 달리 판정만 돌려주고 FolderCapture·classificationState
    /// 어느 쪽도 건드리지 않는다 — 사용자가 미리보기를 확인한 뒤에야 반영된다.
    func evaluateSingleFolder(capture: Capture, folder: Folder) async throws -> ClassificationDecisionDTO? {
        guard let analysis = try await captureStore.fetchAnalysis(for: capture.id) else { return nil }

        let credential = try await installationRegistrar.ensureRegistered()
        // classify(_:)의 키와 형식은 같은 원리(capture+analysisRevision만으로는 재요청을 구분 못 함)
        // 지만 folder.id·criteriaVersion을 넣는다 — 폴더 하나만 보내는 완전히 다른 요청이라 같은
        // 캡처의 전체-폴더 classify(_:) 키와 절대 충돌하면 안 된다. 같은 폴더·같은 기준으로 미리보기를
        // 다시 열어도(변경 없이) 같은 키라 서버가 캐시된 판정을 돌려줘서 Gemini를 또 안 부른다.
        let idempotencyKey = "reclassify-\(capture.id)-\(folder.id)-cv\(folder.criteriaVersion)-r\(analysis.analysisRevision)"
        let folderInput = ClassificationFolderInput(
            id: folder.id, criteriaText: Self.effectiveCriteria(for: folder), criteriaVersion: folder.criteriaVersion)

        let decisions = try await submitAndPoll(
            capture: capture, analysis: analysis, folders: [folderInput],
            idempotencyKey: idempotencyKey, credential: credential)
        return decisions.first { $0.folderId == folder.id }
    }

    private func submitAndPoll(
        capture: Capture, analysis: CaptureAnalysis, folders: [ClassificationFolderInput],
        idempotencyKey: String, credential: String
    ) async throws -> [ClassificationDecisionDTO] {
        let submitted = try await classificationAPIClient.submitClassification(
            clientReference: capture.id,
            analysisRevision: analysis.analysisRevision,
            ocrText: analysis.ocrText ?? "",
            observedEvidence: analysis.observedEvidence,
            folders: folders,
            credential: credential,
            idempotencyKey: idempotencyKey
        )
        return try await poll(jobId: submitted.jobId, initialDelay: submitted.pollAfterSeconds, credential: credential)
    }

    private static func effectiveCriteria(for folder: Folder) -> String {
        if let text = folder.criteriaText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text
        }
        return folder.displayName
    }

    private func poll(jobId: String, initialDelay: Int, credential: String) async throws -> [ClassificationDecisionDTO] {
        var delaySeconds = max(initialDelay, 1)
        for _ in 0..<maxPollAttempts {
            try await Task.sleep(for: .seconds(delaySeconds))
            let status = try await classificationAPIClient.fetchClassificationStatus(jobId: jobId, credential: credential)

            switch status.status {
            case .succeeded:
                return status.result?.decisions ?? []
            case .failed:
                throw ClassificationError.jobFailed(code: status.error?.code ?? "UNKNOWN")
            case .queued, .running:
                delaySeconds = 2
            }
        }
        throw ClassificationError.timedOut
    }
}
