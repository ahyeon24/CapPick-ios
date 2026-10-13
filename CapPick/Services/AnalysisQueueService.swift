import Foundation

/// 서버가 한도 때문에 작업 접수를 거부한 이유(API 명세 §2의 429 오류 코드).
enum AnalysisPauseReason: Equatable, Sendable {
    /// 이 설치가 분석할 수 있는 총 장수를 다 썼다. 시간이 지나도 풀리지 않는다.
    case quotaExceeded
    /// 서버 전체의 오늘 AI 예산이 소진됐다. 다음 날 풀린다.
    case dailyBudgetExhausted

    init?(serverError error: Error) {
        guard case CapPickAPIError.server(_, let code, _, _) = error else { return nil }
        switch code {
        case "QUOTA_EXCEEDED": self = .quotaExceeded
        case "DAILY_BUDGET_EXHAUSTED": self = .dailyBudgetExhausted
        default: return nil
        }
    }

    var userMessage: String {
        switch self {
        case .quotaExceeded: "분석할 수 있는 장수를 모두 사용했어요. 남은 캡처는 아직 검색되지 않아요."
        case .dailyBudgetExhausted: "오늘 분석할 수 있는 양을 모두 사용했어요. 내일 이어서 분석할게요."
        }
    }
}

/// ON-03("전체 캡처 분석 시작") 이후 pending 캡처를 최근 것부터 순서대로 끝까지 자동 처리한다
/// (기능명세서 §1.4, AI-04/05/06). 재개는 새 상태를 따로 안 두고 Capture.searchState만으로
/// 이뤄진다 — "다음에 처리할 캡처"는 항상 pending 쿼리 하나로 구해진다.
/// ContentAnalysisService(제출→폴링→저장, 한 장 처리) 자체는 건드리지 않는다 — processing/failed
/// 마킹은 이 레이어의 책임으로 분리돼 있다(ContentAnalysisServiceTests가 "실패해도 searchState를
/// 건드리지 않는다"를 이미 고정해뒀기 때문).
///
/// 분석이 끝나면 같은 캡처를 바로 이어서 자동 분류(AI-03, ClassificationService)까지 돌린다 —
/// "갤러리의 모든 스크린샷을 서비스가 다 처리해준다"는 제품 방향(§1.4)에 맞춰 사용자가 분류를
/// 따로 트리거할 필요가 없게 한다. 분류 실패는 분석 자체의 성공 여부에 영향을 주지 않는다(별도
/// classificationState). classificationState=pending인데 searchState는 이미 ready인 캡처
/// (이 기능이 생기기 전에 분석만 끝났던 캡처 포함)는 nextPendingForClassification()이 따로 잡는다.
///
/// **한도에 걸리면 멈춘다(2026-10-13).** 서버가 설치별 한도(QUOTA_EXCEEDED)나 하루 예산
/// (DAILY_BUDGET_EXHAUSTED)으로 접수를 거부하면, 그 캡처를 failed로 만들지 않고 pending으로
/// 되돌린 뒤 큐 전체를 잠시 멈춘다. 이 처리가 없던 때는 한도 소진 뒤 남은 캡처가 전부 줄줄이
/// failed로 바뀌어 하나씩 수동 재시도해야 했다(실기기처럼 캡처가 수천 장이면 치명적).
actor AnalysisQueueService {
    /// 한도 거부 뒤 다시 서버에 물어보기까지의 간격. Home이 보일 때마다 resumeIfNeeded가 불리므로,
    /// 이 간격이 없으면 한도가 그대로인데도 계속 요청을 보낸다. 잠정치.
    static let pauseCooldown: TimeInterval = 600

    private let captureStore: any CaptureStoring
    private let contentAnalysisService: ContentAnalysisService
    private let classificationService: ClassificationService
    private let appStateStore: any AppStateStoring

    private let now: @Sendable () -> Date

    private var isRunning = false
    private var pause: (reason: AnalysisPauseReason, until: Date)?

    init(
        captureStore: any CaptureStoring,
        contentAnalysisService: ContentAnalysisService,
        classificationService: ClassificationService,
        appStateStore: any AppStateStoring,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.now = now
        self.captureStore = captureStore
        self.contentAnalysisService = contentAnalysisService
        self.classificationService = classificationService
        self.appStateStore = appStateStore
    }

    /// 큐가 한도 때문에 멈춰 있으면 그 이유. 멈춘 지 pauseCooldown이 지나면 nil이 된다(다음
    /// resumeIfNeeded가 다시 시도한다).
    func pauseReason() -> AnalysisPauseReason? {
        guard let pause, now() < pause.until else { return nil }
        return pause.reason
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

        // 한도 때문에 멈춘 지 얼마 안 됐으면 서버에 다시 묻지 않는다.
        guard pauseReason() == nil else { return }
        pause = nil

        while pause == nil, let capture = try? await captureStore.nextPendingForAnalysis() {
            // 실패해도 무시하고 다음 캡처로 넘어간다 — pending만 다시 집히므로(AI-05), 이 캡처를
            // 같은 실행에서 무한히 재시도하지 않는다. 한도 거부는 예외다: 그 캡처는 pending으로
            // 돌아가 다시 집히므로, pause가 걸리면 루프를 끝내야 무한 반복하지 않는다.
            try? await analyzeOneCapture(capture)
        }
        // 분석은 끝났지만(searchState=ready) 아직 분류가 안 된 캡처를 마저 처리한다 — 위 루프에서
        // 방금 분석된 것들과, 이 기능이 생기기 전에 분석만 끝나 있던 것들 둘 다 여기서 잡힌다.
        while pause == nil, let capture = try? await captureStore.nextPendingForClassification() {
            try? await classifyOneCapture(capture)
        }
    }

    /// 실패한 캡처를 사용자가 명시적으로 재시도할 때(Browse의 재시도 버튼). 실패하면 다시
    /// failed로 남기고 에러를 그대로 던져 호출자가 이유를 보여줄 수 있게 한다.
    ///
    /// analysisAttempt를 여기서 증가시킨다 — 같은 캡처·같은 content_revision이라도 서버가 이전
    /// 실패 작업을 그대로 돌려주지 않고 실제로 다시 분석하게 하려면 Idempotency-Key가 매번
    /// 달라져야 한다(서버 job 테이블에 영원히 QUEUED로 멈춘 옛 작업이 재시도를 계속 가로채던
    /// 버그를 2026-09-25에 이렇게 고쳤다).
    func retry(_ capture: Capture) async throws {
        try await captureStore.incrementAnalysisAttempt(capture.id)
        let refreshed = try await captureStore.fetchCapture(id: capture.id) ?? capture
        try await analyzeOneCapture(refreshed)
    }

    private func analyzeOneCapture(_ capture: Capture) async throws {
        try await captureStore.markSearchProcessing(capture.id)
        do {
            try await contentAnalysisService.analyze(capture)
        } catch {
            if let reason = AnalysisPauseReason(serverError: error) {
                try? await captureStore.markSearchPending(capture.id)
                pause = (reason, now().addingTimeInterval(Self.pauseCooldown))
            } else {
                try? await captureStore.markSearchFailed(capture.id)
            }
            throw error
        }
        // 분석 성공 직후 바로 분류까지 이어간다. 분류가 실패해도 분석 자체는 이미 성공했으니
        // 그 결과를 던지지 않는다 — 호출자(retry() 등)는 분석 성공/실패만 신경 쓰면 된다.
        if let refreshed = try? await captureStore.fetchCapture(id: capture.id) {
            try? await classifyOneCapture(refreshed)
        }
    }

    private func classifyOneCapture(_ capture: Capture) async throws {
        try await captureStore.markClassificationProcessing(capture.id)
        do {
            try await classificationService.classify(capture)
            try await captureStore.markClassificationComplete(capture.id)
        } catch {
            if let reason = AnalysisPauseReason(serverError: error) {
                try? await captureStore.markClassificationPending(capture.id)
                pause = (reason, now().addingTimeInterval(Self.pauseCooldown))
            } else {
                try? await captureStore.markClassificationFailed(capture.id)
            }
            throw error
        }
    }
}
