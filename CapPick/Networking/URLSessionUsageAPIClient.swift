import Foundation

final class URLSessionUsageAPIClient: UsageAPIClient {
    private let session: URLSession
    private let baseURL: URL

    init(session: URLSession = .shared, baseURL: URL) {
        self.session = session
        self.baseURL = baseURL
    }

    func fetchUsage(credential: String) async throws -> UsageSummary {
        var request = URLRequest(url: baseURL.appendingPathComponent("/v1/usage"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")

        return try await CapPickHTTP.send(request, session: session)
    }
}
