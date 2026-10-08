import Foundation

enum ContentAnalysisError: Error, Equatable {
    case imageUnavailable
    case jobFailed(code: String)
    case timedOut
}

/// 캡처 하나를 서버에 제출→폴링→로컬 저장까지 잇는다 (API 명세 §4 content_analysis,
/// CapPick-server/CLAUDE.md "Job 도메인" 절과 짝). 아직 여러 캡처를 순서대로 처리하는
/// 대기열(AI-04/05/06)은 없다 — 캡처 한 장을 수동으로 트리거하는 첫 조각이다.
actor ContentAnalysisService {
    private let jobAPIClient: any JobAPIClient
    private let installationRegistrar: InstallationRegistrar
    private let captureStore: any CaptureStoring
    private let imageProvider: any CaptureImageProviding
    private let textRecognizer: any TextRecognizing

    // 잠정치 — poll_after_seconds 사이 재시도 횟수 상한. 서버가 응답 없이 영원히 queued를
    // 돌려주는 경우에도 무한 대기하지 않는다.
    private let maxPollAttempts = 30

    init(
        jobAPIClient: any JobAPIClient,
        installationRegistrar: InstallationRegistrar,
        captureStore: any CaptureStoring,
        imageProvider: any CaptureImageProviding,
        textRecognizer: any TextRecognizing
    ) {
        self.jobAPIClient = jobAPIClient
        self.installationRegistrar = installationRegistrar
        self.captureStore = captureStore
        self.imageProvider = imageProvider
        self.textRecognizer = textRecognizer
    }

    func analyze(_ capture: Capture) async throws {
        guard let imageData = await imageProvider.imageData(for: capture.photoAssetID) else {
            throw ContentAnalysisError.imageUnavailable
        }

        // OCR은 기기에서 한다(2026-10-08) — 서버는 이 텍스트를 받으면 AI 모델에게 OCR을 시키지 않고
        // 그대로 결과의 ocr_text로 돌려준다(출력 토큰 절감). nil이면 서버가 예전처럼 모델 OCR로 대신한다.
        let ocrText = await textRecognizer.recognizeText(for: capture.photoAssetID)

        let credential = try await installationRegistrar.ensureRegistered()
        // capture·content_revision·analysisAttempt로 키를 만든다. attempt를 포함하지 않으면
        // 실패 후 재시도가 서버 입장에서 "완전히 같은 요청"이 돼버려서, 예전에 멈춰버린 작업이든
        // 이미 실패로 끝난 작업이든 그걸 그대로 돌려주기만 하고 절대 다시 분석하지 않는다(API
        // 명세 §2 Idempotency-Key는 "같은 논리 작업"에만 재사용하라는 뜻인데, 자동 큐가 pending을
        // 처음 집을 때는 attempt를 안 올려서 앱이 죽었다 살아난 경우엔 여전히 같은 키를 재사용한다
        // — AnalysisQueueService.retry 참고).
        let idempotencyKey = "content-analysis-\(capture.id)-r\(capture.contentRevision)-a\(capture.analysisAttempt)"

        let submitted = try await jobAPIClient.submitContentAnalysis(
            clientReference: capture.id,
            contentRevision: capture.contentRevision,
            ocrTextHint: ocrText,
            imageData: imageData,
            credential: credential,
            idempotencyKey: idempotencyKey
        )

        try await poll(jobId: submitted.jobId, initialDelay: submitted.pollAfterSeconds, credential: credential, capture: capture)
    }

    private func poll(jobId: String, initialDelay: Int, credential: String, capture: Capture) async throws {
        var delaySeconds = max(initialDelay, 1)
        for _ in 0..<maxPollAttempts {
            try await Task.sleep(for: .seconds(delaySeconds))
            let status = try await jobAPIClient.fetchJobStatus(jobId: jobId, credential: credential)

            switch status.status {
            case .succeeded:
                guard let result = status.result else {
                    throw ContentAnalysisError.jobFailed(code: "MISSING_RESULT")
                }
                try await save(result, for: capture)
                return
            case .failed:
                throw ContentAnalysisError.jobFailed(code: status.error?.code ?? "UNKNOWN")
            case .queued, .running:
                delaySeconds = 2
            }
        }
        throw ContentAnalysisError.timedOut
    }

    private func save(_ result: ContentAnalysisResultDTO, for capture: Capture) async throws {
        let analysis = CaptureAnalysis(
            captureID: capture.id,
            contentRevision: capture.contentRevision,
            analysisRevision: result.analysisRevision,
            ocrText: result.ocrText.isEmpty ? nil : result.ocrText,
            observedEvidence: result.observedEvidence,
            modelVersion: result.embeddingModelVersion
        )
        let document = SearchDocument(
            captureID: capture.id,
            sourceAnalysisRevision: result.analysisRevision,
            searchText: result.searchText,
            embedding: result.embedding,
            embeddingModelVersion: result.embeddingModelVersion,
            state: "ready"
        )
        try await captureStore.saveAnalysis(analysis, searchDocument: document)
    }
}
