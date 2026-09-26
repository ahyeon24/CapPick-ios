import Foundation

// API 명세 §3·§7 POST/GET /v1/data-deletions. 서버 DeletionController/DeletionService와 짝
// (CapPick-server/CLAUDE.md "사용량·삭제" 절 참고). scope는 지금 installation_content 하나뿐.
protocol DeletionAPIClient: Sendable {
    func requestInstallationDeletion(credential: String, idempotencyKey: String) async throws -> DeletionSubmitted
    func fetchDeletionStatus(deletionId: String, credential: String) async throws -> DeletionStatusResult
}

enum RemoteDeletionStatus: String, Equatable, Sendable, Decodable {
    case pending
    case processing
    case completed
    case failed
}

struct DeletionSubmitted: Equatable, Sendable, Decodable {
    let deletionId: String
    let status: RemoteDeletionStatus
}

struct DeletionStatusResult: Equatable, Sendable, Decodable {
    let deletionId: String
    let status: RemoteDeletionStatus
    let completedAt: Date?
    let errorCode: String?
}
