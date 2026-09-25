import Foundation

final class URLSessionClassificationAPIClient: ClassificationAPIClient {
    private let session: URLSession
    private let baseURL: URL

    init(session: URLSession = .shared, baseURL: URL) {
        self.session = session
        self.baseURL = baseURL
    }

    func submitClassification(
        clientReference: String,
        analysisRevision: Int,
        ocrText: String,
        observedEvidence: [String],
        folders: [ClassificationFolderInput],
        credential: String,
        idempotencyKey: String
    ) async throws -> JobSubmitted {
        var request = URLRequest(url: baseURL.appendingPathComponent("/v1/jobs"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ClassificationRequestDTO(
            kind: "classification",
            clientReference: clientReference,
            analysisRevision: analysisRevision,
            analysis: .init(ocrText: ocrText, observedEvidence: observedEvidence),
            folders: folders.map { .init(id: $0.id, criteriaText: $0.criteriaText, criteriaVersion: $0.criteriaVersion) }
        )
        do {
            request.httpBody = try CapPickJSON.encoder.encode(body)
        } catch {
            throw CapPickAPIError.decoding("classification request encoding failed: \(error)")
        }

        let dto: JobSubmitResponseDTO = try await CapPickHTTP.send(request, session: session)
        return JobSubmitted(jobId: dto.jobId, status: dto.status, pollAfterSeconds: dto.pollAfterSeconds)
    }

    func fetchClassificationStatus(jobId: String, credential: String) async throws -> ClassificationJobStatusResult {
        var request = URLRequest(url: baseURL.appendingPathComponent("/v1/jobs/\(jobId)"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")

        let dto: ClassificationJobStatusResponseDTO = try await CapPickHTTP.send(request, session: session)
        return ClassificationJobStatusResult(
            jobId: dto.jobId, status: dto.status, clientReference: dto.clientReference,
            result: dto.result, resultExpiresAt: dto.resultExpiresAt, error: dto.error)
    }
}

private struct ClassificationRequestDTO: Encodable {
    let kind: String
    let clientReference: String
    let analysisRevision: Int
    let analysis: AnalysisDTO
    let folders: [FolderDTO]

    struct AnalysisDTO: Encodable {
        let ocrText: String
        let observedEvidence: [String]
    }

    struct FolderDTO: Encodable {
        let id: String
        let criteriaText: String
        let criteriaVersion: Int
    }
}

private struct JobSubmitResponseDTO: Decodable {
    let jobId: String
    let status: RemoteJobStatus
    let pollAfterSeconds: Int
}

private struct ClassificationJobStatusResponseDTO: Decodable {
    let jobId: String
    let status: RemoteJobStatus
    let clientReference: String
    let result: ClassificationResultDTO?
    let resultExpiresAt: Date?
    let error: JobErrorDTO?
}
