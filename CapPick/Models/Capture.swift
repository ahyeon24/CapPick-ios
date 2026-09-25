import Foundation

// ERD v0.2 §2 Capture, §3 상태 규칙 기준.
struct Capture: Identifiable, Equatable, Codable {
    let id: String
    let photoAssetID: String
    let capturedAt: Date
    let width: Int
    let height: Int
    var availability: CaptureAvailability
    var excludedAt: Date?
    var favorite: Bool
    var contentRevision: Int
    var searchState: SearchState
    var classificationState: ClassificationState
    // 사용자가 명시적으로 "다시 분석하기"를 누른 횟수(ContentAnalysisService의 Idempotency-Key에
    // 들어간다). pending 캡처를 자동 큐가 처음 집을 때는 증가시키지 않는다 — AnalysisQueueService.retry
    // 참고.
    var analysisAttempt: Int

    init(
        id: String, photoAssetID: String, capturedAt: Date, width: Int, height: Int,
        availability: CaptureAvailability, excludedAt: Date?, favorite: Bool,
        contentRevision: Int, searchState: SearchState, classificationState: ClassificationState,
        analysisAttempt: Int = 0
    ) {
        self.id = id
        self.photoAssetID = photoAssetID
        self.capturedAt = capturedAt
        self.width = width
        self.height = height
        self.availability = availability
        self.excludedAt = excludedAt
        self.favorite = favorite
        self.contentRevision = contentRevision
        self.searchState = searchState
        self.classificationState = classificationState
        self.analysisAttempt = analysisAttempt
    }
}

enum CaptureAvailability: String, Codable {
    case accessible
    case unavailable
}

enum SearchState: String, Codable {
    case pending
    case processing
    case ready
    case failed
}

enum ClassificationState: String, Codable {
    case pending
    case processing
    case complete
    case failed
    case blocked
}
