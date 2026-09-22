import XCTest
@testable import CapPick

final class URLSessionSearchAPIClientTests: XCTestCase {
    private var client: URLSessionSearchAPIClient!

    override func setUp() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        client = URLSessionSearchAPIClient(
            session: URLSession(configuration: configuration), baseURL: URL(string: "https://api.example.invalid")!)
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
    }

    func testPrepareSendsSnakeCaseBodyWithBearerAuthAndParsesResponse() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/search/prepare")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer cred-1")
            let body = try JSONSerialization.jsonObject(with: request.bodyData!) as! [String: Any]
            XCTAssertEqual(body["query"] as? String, "지난달 저장한 알고리즘 문제")
            XCTAssertEqual(body["timezone"] as? String, "Asia/Seoul")
            XCTAssertEqual(body["embedding_model_version"] as? String, "gemini-embedding-001")

            let json = """
            {"normalized_query":"지난달 저장한 알고리즘 문제","lexical_terms":["알고리즘","행렬곱"],
             "embedding":[0.1,0.2],"embedding_model_version":"gemini-embedding-001",
             "captured_from":"2026-08-01T00:00:00Z","captured_before":"2026-09-01T00:00:00Z",
             "date_interpretation":"지난달(8월 1일~31일)"}
            """
            return (200, Data(json.utf8))
        }

        let result = try await client.prepare(
            query: "지난달 저장한 알고리즘 문제", now: Date(), timezone: TimeZone(identifier: "Asia/Seoul")!,
            embeddingModelVersion: "gemini-embedding-001", credential: "cred-1")

        XCTAssertEqual(result.normalizedQuery, "지난달 저장한 알고리즘 문제")
        XCTAssertEqual(result.lexicalTerms, ["알고리즘", "행렬곱"])
        XCTAssertEqual(result.embedding, [0.1, 0.2])
        let isoFormatter = ISO8601DateFormatter()
        XCTAssertEqual(result.capturedFrom, isoFormatter.date(from: "2026-08-01T00:00:00Z"))
        XCTAssertEqual(result.capturedBefore, isoFormatter.date(from: "2026-09-01T00:00:00Z"))
        XCTAssertEqual(result.dateInterpretation, "지난달(8월 1일~31일)")
    }

    func testPrepareParsesNullDateFieldsAsNil() async throws {
        StubURLProtocol.handler = { _ in
            let json = """
            {"normalized_query":"면접 질문","lexical_terms":["면접"],
             "embedding":[],"embedding_model_version":"gemini-embedding-001",
             "captured_from":null,"captured_before":null,"date_interpretation":null}
            """
            return (200, Data(json.utf8))
        }

        let result = try await client.prepare(
            query: "면접 질문", now: Date(), timezone: TimeZone(identifier: "Asia/Seoul")!,
            embeddingModelVersion: "gemini-embedding-001", credential: "cred-1")

        XCTAssertNil(result.capturedFrom)
        XCTAssertNil(result.capturedBefore)
        XCTAssertNil(result.dateInterpretation)
    }

    func testModelMismatchServerErrorIsMappedToCapPickAPIError() async throws {
        StubURLProtocol.handler = { _ in
            let json = """
            {"error":{"code":"SEARCH_MODEL_MISMATCH","message":"모델 버전이 다릅니다.","retryable":false},"request_id":"req_1"}
            """
            return (409, Data(json.utf8))
        }

        do {
            _ = try await client.prepare(
                query: "질문", now: Date(), timezone: TimeZone(identifier: "Asia/Seoul")!,
                embeddingModelVersion: "old-v1", credential: "cred-1")
            XCTFail("expected error")
        } catch let CapPickAPIError.server(status, code, _, retryable) {
            XCTAssertEqual(status, 409)
            XCTAssertEqual(code, "SEARCH_MODEL_MISMATCH")
            XCTAssertFalse(retryable)
        }
    }
}
