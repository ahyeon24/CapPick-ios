import Foundation
@testable import CapPick

final class FakeSearchAPIClient: SearchAPIClient, @unchecked Sendable {
    var resultsByQuery: [String: SearchPrepared] = [:]
    var delayByQuery: [String: Duration] = [:]
    private(set) var prepareCalls: [String] = []

    func prepare(
        query: String, now: Date, timezone: TimeZone, embeddingModelVersion: String, credential: String
    ) async throws -> SearchPrepared {
        prepareCalls.append(query)
        if let delay = delayByQuery[query] {
            try await Task.sleep(for: delay)
        }
        if let result = resultsByQuery[query] {
            return result
        }
        return SearchPrepared(
            normalizedQuery: query, lexicalTerms: [], embedding: [],
            embeddingModelVersion: embeddingModelVersion, capturedFrom: nil, capturedBefore: nil,
            dateInterpretation: nil
        )
    }
}
