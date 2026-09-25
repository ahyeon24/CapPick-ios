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

    func submitClassification(
        clientReference: String, analysisRevision: Int, ocrText: String, observedEvidence: [String],
        folders: [ClassificationFolderInput], credential: String, idempotencyKey: String
    ) async throws -> JobSubmitted {
        submitCalls.append((clientReference, analysisRevision, ocrText, observedEvidence, folders, idempotencyKey))
        guard let result = submitResultsByReference[clientReference] else {
            fatalError("no stubbed submit result for \(clientReference)")
        }
        return try result.get()
    }

    func fetchClassificationStatus(jobId: String, credential: String) async throws -> ClassificationJobStatusResult {
        guard let results = statusResultsByJobId[jobId] else {
            fatalError("no stubbed status results for \(jobId)")
        }
        let index = statusCallCountByJobId[jobId, default: 0]
        statusCallCountByJobId[jobId] = index + 1
        return try results[min(index, results.count - 1)].get()
    }
}
