import Foundation

final class URLSessionDeletionAPIClient: DeletionAPIClient {
    private let session: URLSession
    private let baseURL: URL

    init(session: URLSession = .shared, baseURL: URL) {
        self.session = session
        self.baseURL = baseURL
    }

    func requestInstallationDeletion(credential: String, idempotencyKey: String) async throws -> DeletionSubmitted {
        var request = URLRequest(url: baseURL.appendingPathComponent("/v1/data-deletions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try CapPickJSON.encoder.encode(DataDeletionRequestBody(scope: "installation_content"))

        return try await CapPickHTTP.send(request, session: session)
    }

    func fetchDeletionStatus(deletionId: String, credential: String) async throws -> DeletionStatusResult {
        var request = URLRequest(url: baseURL.appendingPathComponent("/v1/data-deletions/\(deletionId)"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")

        return try await CapPickHTTP.send(request, session: session)
    }
}

private struct DataDeletionRequestBody: Encodable {
    let scope: String
}
