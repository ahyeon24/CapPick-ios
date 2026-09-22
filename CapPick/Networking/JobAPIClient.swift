import Foundation

// API 명세 §4. content_analysis만 구현 — 서버 JobController와 짝(CapPick-server/CLAUDE.md
// "Job 도메인" 절 참고). Job 등 다른 kind가 생기면 이 프로토콜에 메서드를 추가한다.
protocol JobAPIClient: Sendable {
    func submitContentAnalysis(
        clientReference: String,
        contentRevision: Int,
        ocrTextHint: String?,
        imageData: Data,
        credential: String,
        idempotencyKey: String
    ) async throws -> JobSubmitted

    func fetchJobStatus(jobId: String, credential: String) async throws -> JobStatusResult
}

enum RemoteJobStatus: String, Equatable, Sendable, Decodable {
    case queued
    case running
    case succeeded
    case failed
}

struct JobSubmitted: Equatable, Sendable {
    let jobId: String
    let status: RemoteJobStatus
    let pollAfterSeconds: Int
}

struct JobStatusResult: Equatable, Sendable {
    let jobId: String
    let status: RemoteJobStatus
    let clientReference: String
    let result: ContentAnalysisResultDTO?
    let resultExpiresAt: Date?
    let error: JobErrorDTO?
}

// API 명세 §4 content_analysis 완료 result와 같은 모양(서버 ContentAnalysisResultDTO와 짝).
struct ContentAnalysisResultDTO: Equatable, Sendable, Decodable {
    let analysisRevision: Int
    let ocrText: String
    let observedEvidence: [String]
    let searchText: String
    let embedding: [Double]
    let embeddingModelVersion: String
}

struct JobErrorDTO: Equatable, Sendable, Decodable {
    let code: String
    let message: String
    let retryable: Bool
}
