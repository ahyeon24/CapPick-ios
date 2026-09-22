import Foundation
@testable import CapPick

final class FakeJobAPIClient: JobAPIClient, @unchecked Sendable {
    var submitResult: Result<JobSubmitted, Error> = .success(
        JobSubmitted(jobId: "job-1", status: .queued, pollAfterSeconds: 0))
    /// 순서대로 하나씩 소비된다 — 폴링이 여러 번 도는 걸 흉내낼 때 쓴다.
    var statusResults: [Result<JobStatusResult, Error>] = [
        .success(JobStatusResult(
            jobId: "job-1", status: .succeeded, clientReference: "c1",
            result: ContentAnalysisResultDTO(
                analysisRevision: 1, ocrText: "ocr", observedEvidence: ["evidence"],
                searchText: "search", embedding: [0.1], embeddingModelVersion: "embed-v1"),
            resultExpiresAt: nil, error: nil))
    ]

    private(set) var submitCalls: [(clientReference: String, contentRevision: Int, idempotencyKey: String)] = []
    private(set) var statusCallCount = 0

    func submitContentAnalysis(
        clientReference: String, contentRevision: Int, ocrTextHint: String?,
        imageData: Data, credential: String, idempotencyKey: String
    ) async throws -> JobSubmitted {
        submitCalls.append((clientReference, contentRevision, idempotencyKey))
        return try submitResult.get()
    }

    func fetchJobStatus(jobId: String, credential: String) async throws -> JobStatusResult {
        defer { statusCallCount += 1 }
        let index = min(statusCallCount, statusResults.count - 1)
        return try statusResults[index].get()
    }
}

final class FakeCaptureImageProviding: CaptureImageProviding, @unchecked Sendable {
    var dataToReturn: Data? = Data("fake-image".utf8)

    func imageData(for photoAssetID: String) async -> Data? {
        dataToReturn
    }
}
