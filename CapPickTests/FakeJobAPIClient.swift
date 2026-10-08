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
    /// 캡처(clientReference)별로 다른 결과가 필요할 때(예: 큐 테스트에서 하나는 성공, 하나는
    /// 실패) 쓴다. 여기 없는 clientReference는 위 submitResult로 대체된다.
    var submitResultsByReference: [String: Result<JobSubmitted, Error>] = [:]
    /// jobId별로 다른 폴링 결과가 필요할 때 쓴다. 여기 없는 jobId는 위 statusResults(전역 카운터)로 대체된다.
    var statusResultsByJobId: [String: [Result<JobStatusResult, Error>]] = [:]

    private(set) var submitCalls: [(clientReference: String, contentRevision: Int, idempotencyKey: String)] = []
    private(set) var submittedOCRTextHints: [String?] = []
    private(set) var statusCallCount = 0
    private var statusCallCountByJobId: [String: Int] = [:]

    func submitContentAnalysis(
        clientReference: String, contentRevision: Int, ocrTextHint: String?,
        imageData: Data, credential: String, idempotencyKey: String
    ) async throws -> JobSubmitted {
        submitCalls.append((clientReference, contentRevision, idempotencyKey))
        submittedOCRTextHints.append(ocrTextHint)
        if let perReference = submitResultsByReference[clientReference] {
            return try perReference.get()
        }
        return try submitResult.get()
    }

    func fetchJobStatus(jobId: String, credential: String) async throws -> JobStatusResult {
        if let results = statusResultsByJobId[jobId] {
            let index = statusCallCountByJobId[jobId, default: 0]
            statusCallCountByJobId[jobId] = index + 1
            return try results[min(index, results.count - 1)].get()
        }
        defer { statusCallCount += 1 }
        let index = min(statusCallCount, statusResults.count - 1)
        return try statusResults[index].get()
    }
}

final class FakeTextRecognizer: TextRecognizing, @unchecked Sendable {
    var textToReturn: String? = "fake-ocr"

    func recognizeText(for photoAssetID: String) async -> String? {
        textToReturn
    }
}

final class FakeCaptureImageProviding: CaptureImageProviding, @unchecked Sendable {
    var dataToReturn: Data? = Data("fake-image".utf8)

    func imageData(for photoAssetID: String) async -> Data? {
        dataToReturn
    }
}
