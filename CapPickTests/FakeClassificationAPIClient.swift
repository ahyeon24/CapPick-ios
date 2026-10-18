import Foundation
@testable import CapPick

// FakeJobAPIClient와 같은 패턴 — clientReference별 submit 결과, jobId별 순서대로 소비되는
// status 결과.
final class FakeClassificationAPIClient: ClassificationAPIClient, @unchecked Sendable {
    var submitResultsByReference: [String: Result<JobSubmitted, Error>] = [:]
    var statusResultsByJobId: [String: [Result<ClassificationJobStatusResult, Error>]] = [:]

    private(set) var submitCalls: [(
        clientReference: String, analysisRevision: Int, ocrText: String,
        observedEvidence: [String], folders: [ClassificationFolderInput], idempotencyKey: String
    )] = []
    private var statusCallCountByJobId: [String: Int] = [:]
    // 재분류가 판정을 여러 개 동시에 보내므로 기록·소비를 잠근다.
    private let lock = NSLock()

    func submitClassification(
        clientReference: String, analysisRevision: Int, ocrText: String, observedEvidence: [String],
        folders: [ClassificationFolderInput], credential: String, idempotencyKey: String
    ) async throws -> JobSubmitted {
        let result: Result<JobSubmitted, Error>? = lock.withLock {
            submitCalls.append((clientReference, analysisRevision, ocrText, observedEvidence, folders, idempotencyKey))
            return submitResultsByReference[clientReference]
        }
        guard let result else {
            fatalError("no stubbed submit result for \(clientReference)")
        }
        return try result.get()
    }

    func fetchClassificationStatus(jobId: String, credential: String) async throws -> ClassificationJobStatusResult {
        let next: Result<ClassificationJobStatusResult, Error>? = lock.withLock {
            guard let results = statusResultsByJobId[jobId] else { return nil }
            let index = statusCallCountByJobId[jobId, default: 0]
            statusCallCountByJobId[jobId] = index + 1
            return results[min(index, results.count - 1)]
        }
        guard let next else {
            fatalError("no stubbed status results for \(jobId)")
        }
        return try next.get()
    }
}
