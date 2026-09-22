import Foundation

/// ON-03("전체 캡처 분석 시작") 이후 pending 캡처를 최근 것부터 순서대로 끝까지 자동 처리한다
/// (기능명세서 §1.4, AI-04/05/06). 재개는 새 상태를 따로 안 두고 Capture.searchState만으로
/// 이뤄진다 — "다음에 처리할 캡처"는 항상 pending 쿼리 하나로 구해진다.
/// ContentAnalysisService(제출→폴링→저장, 한 장 처리) 자체는 건드리지 않는다 — processing/failed
/// 마킹은 이 레이어의 책임으로 분리돼 있다(ContentAnalysisServiceTests가 "실패해도 searchState를
/// 건드리지 않는다"를 이미 고정해뒀기 때문).
actor AnalysisQueueService {
    private let captureStore: any CaptureStoring
    private let contentAnalysisService: ContentAnalysisService
    private let appStateStore: any AppStateStoring

    private var isRunning = false

    init(
        captureStore: any CaptureStoring,
        contentAnalysisService: ContentAnalysisService,
        appStateStore: any AppStateStoring
    ) {
        self.captureStore = captureStore
        self.contentAnalysisService = contentAnalysisService
        self.appStateStore = appStateStore
    }

    /// ON-03에서 동의했다면(analysisStartRequested == "true") pending 전체를 처리한다.
    /// 이미 실행 중이면 즉시 반환한다(중복 실행 방지) — Home이 보일 때마다 안전하게 부를 수 있다.
    func resumeIfNeeded() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        // 지난 실행이 처리 도중 끊겼다면 processing에 멈춰있던 캡처를 되돌려 다시 집어갈 수 있게 한다.
        try? await captureStore.resetStuckProcessing()

        guard (try? await appStateStore.value(for: AppStateKey.analysisStartRequested)) == "true" else { return }

        while let capture = try? await captureStore.nextPendingForAnalysis() {
            // 실패해도 무시하고 다음 캡처로 넘어간다 — pending만 다시 집히므로(AI-05), 이 캡처를
            // 같은 실행에서 무한히 재시도하지 않는다.
            try? await analyzeOneCapture(capture)
        }
    }

    /// 실패한 캡처를 사용자가 명시적으로 재시도할 때(Browse의 재시도 버튼). 실패하면 다시
    /// failed로 남기고 에러를 그대로 던져 호출자가 이유를 보여줄 수 있게 한다.
    func retry(_ capture: Capture) async throws {
        try await analyzeOneCapture(capture)
    }

    private func analyzeOneCapture(_ capture: Capture) async throws {
        try await captureStore.markSearchProcessing(capture.id)
        do {
            try await contentAnalysisService.analyze(capture)
        } catch {
            try? await captureStore.markSearchFailed(capture.id)
            throw error
        }
    }
}
