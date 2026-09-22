import Foundation

final class URLSessionSearchAPIClient: SearchAPIClient {
    private let session: URLSession
    private let baseURL: URL

    init(session: URLSession = .shared, baseURL: URL) {
        self.session = session
        self.baseURL = baseURL
    }

    func prepare(
        query: String, now: Date, timezone: TimeZone, embeddingModelVersion: String, credential: String
    ) async throws -> SearchPrepared {
        let body = SearchPrepareRequestDTO(
            query: query, now: now, timezone: timezone.identifier, embeddingModelVersion: embeddingModelVersion)

        var request = URLRequest(url: baseURL.appendingPathComponent("/v1/search/prepare"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try CapPickJSON.encoder.encode(body)
        } catch {
            throw CapPickAPIError.decoding("request encoding failed: \(error)")
        }

        let dto: SearchPrepareResponseDTO = try await CapPickHTTP.send(request, session: session)
        return SearchPrepared(
            normalizedQuery: dto.normalizedQuery,
            lexicalTerms: dto.lexicalTerms,
            embedding: dto.embedding,
            embeddingModelVersion: dto.embeddingModelVersion,
            capturedFrom: dto.capturedFrom,
            capturedBefore: dto.capturedBefore,
            dateInterpretation: dto.dateInterpretation
        )
    }
}

private struct SearchPrepareRequestDTO: Encodable {
    let query: String
    let now: Date
    let timezone: String
    let embeddingModelVersion: String
}

private struct SearchPrepareResponseDTO: Decodable {
    let normalizedQuery: String
    let lexicalTerms: [String]
    let embedding: [Double]
    let embeddingModelVersion: String
    let capturedFrom: Date?
    let capturedBefore: Date?
    let dateInterpretation: String?
}
