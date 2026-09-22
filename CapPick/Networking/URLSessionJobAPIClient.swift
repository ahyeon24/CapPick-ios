import Foundation

final class URLSessionJobAPIClient: JobAPIClient {
    private let session: URLSession
    private let baseURL: URL

    init(session: URLSession = .shared, baseURL: URL) {
        self.session = session
        self.baseURL = baseURL
    }

    func submitContentAnalysis(
        clientReference: String,
        contentRevision: Int,
        ocrTextHint: String?,
        imageData: Data,
        credential: String,
        idempotencyKey: String
    ) async throws -> JobSubmitted {
        let boundary = "cappick-\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appendingPathComponent("/v1/jobs"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let metadata = ContentAnalysisMetadataDTO(
            clientReference: clientReference, contentRevision: contentRevision, ocrText: ocrTextHint)
        let metadataJSON: Data
        do {
            metadataJSON = try CapPickJSON.encoder.encode(metadata)
        } catch {
            throw CapPickAPIError.decoding("metadata encoding failed: \(error)")
        }

        request.httpBody = Self.multipartBody(
            boundary: boundary,
            parts: [
                .init(name: "metadata", filename: nil, contentType: "application/json", data: metadataJSON),
                .init(name: "image", filename: "capture.jpg", contentType: "image/jpeg", data: imageData),
            ]
        )

        let dto: JobSubmitResponseDTO = try await CapPickHTTP.send(request, session: session)
        return JobSubmitted(jobId: dto.jobId, status: dto.status, pollAfterSeconds: dto.pollAfterSeconds)
    }

    func fetchJobStatus(jobId: String, credential: String) async throws -> JobStatusResult {
        var request = URLRequest(url: baseURL.appendingPathComponent("/v1/jobs/\(jobId)"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")

        let dto: JobStatusResponseDTO = try await CapPickHTTP.send(request, session: session)
        return JobStatusResult(
            jobId: dto.jobId, status: dto.status, clientReference: dto.clientReference,
            result: dto.result, resultExpiresAt: dto.resultExpiresAt, error: dto.error)
    }

    private struct MultipartPart {
        let name: String
        let filename: String?
        let contentType: String
        let data: Data
    }

    private static func multipartBody(boundary: String, parts: [MultipartPart]) -> Data {
        var body = Data()
        for part in parts {
            body.append("--\(boundary)\r\n".utf8Data)
            if let filename = part.filename {
                body.append("Content-Disposition: form-data; name=\"\(part.name)\"; filename=\"\(filename)\"\r\n".utf8Data)
            } else {
                body.append("Content-Disposition: form-data; name=\"\(part.name)\"\r\n".utf8Data)
            }
            body.append("Content-Type: \(part.contentType)\r\n\r\n".utf8Data)
            body.append(part.data)
            body.append("\r\n".utf8Data)
        }
        body.append("--\(boundary)--\r\n".utf8Data)
        return body
    }
}

private extension String {
    var utf8Data: Data { Data(utf8) }
}

private struct ContentAnalysisMetadataDTO: Encodable {
    let clientReference: String
    let contentRevision: Int
    let ocrText: String?
}

private struct JobSubmitResponseDTO: Decodable {
    let jobId: String
    let status: RemoteJobStatus
    let pollAfterSeconds: Int
}

private struct JobStatusResponseDTO: Decodable {
    let jobId: String
    let status: RemoteJobStatus
    let clientReference: String
    let result: ContentAnalysisResultDTO?
    let resultExpiresAt: Date?
    let error: JobErrorDTO?
}
