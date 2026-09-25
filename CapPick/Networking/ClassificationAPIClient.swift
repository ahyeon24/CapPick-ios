import Foundation

// API 명세 §4 classification. content_analysis(JobAPIClient)와 별도 프로토콜로 둔다 —
// content_analysis는 이미지 멀티파트, classification은 JSON이라 요청 모양이 다르고,
// GET /v1/jobs/{id}의 result 모양도 kind마다 달라서 같은 JobStatusResult를 못 쓴다
// (서버 JobStatusResponse.result가 Object로 일반화된 이유와 같다 — CapPick-server/CLAUDE.md
// "자동 분류" 절 참고).
protocol ClassificationAPIClient: Sendable {
    func submitClassification(
        clientReference: String,
        analysisRevision: Int,
        ocrText: String,
        observedEvidence: [String],
        folders: [ClassificationFolderInput],
        credential: String,
        idempotencyKey: String
    ) async throws -> JobSubmitted

    func fetchClassificationStatus(jobId: String, credential: String) async throws -> ClassificationJobStatusResult
}

// 판정 대상 폴더 하나 — 서버 ClassificationFolderCriteria와 짝.
struct ClassificationFolderInput: Equatable, Sendable {
    let id: String
    let criteriaText: String
    let criteriaVersion: Int
}

struct ClassificationJobStatusResult: Equatable, Sendable {
    let jobId: String
    let status: RemoteJobStatus
    let clientReference: String
    let result: ClassificationResultDTO?
    let resultExpiresAt: Date?
    let error: JobErrorDTO?
}

// API 명세 §5 classification 완료 result와 같은 모양(서버 ClassificationResultDTO와 짝).
struct ClassificationResultDTO: Equatable, Sendable, Decodable {
    let decisions: [ClassificationDecisionDTO]
}

struct ClassificationDecisionDTO: Equatable, Sendable, Decodable {
    let folderId: String
    let criteriaVersion: Int
    let decision: ClassificationDecision
    let evidence: String
}

// 서버 ClassificationDecision과 짝 — 서버가 @JsonValue로 소문자 스네이크케이스를 내보낸다.
enum ClassificationDecision: String, Equatable, Sendable, Decodable {
    case match
    case noMatch = "no_match"
    case uncertain
}
