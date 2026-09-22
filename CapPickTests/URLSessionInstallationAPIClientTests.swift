import XCTest
@testable import CapPick

final class StubURLProtocol: URLProtocol {
    // 테스트가 순차 실행되고 매번 tearDown에서 nil로 되돌리니 동시 접근은 없다.
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class URLSessionInstallationAPIClientTests: XCTestCase {
    private var client: URLSessionInstallationAPIClient!

    override func setUp() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        client = URLSessionInstallationAPIClient(
            session: URLSession(configuration: configuration), baseURL: URL(string: "https://api.example.invalid")!)
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
    }

    func testRequestChallengeParsesSnakeCaseResponse() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/installations/challenges")
            XCTAssertEqual(request.httpMethod, "POST")
            let json = """
            {"challenge_id":"c1","challenge":"abc","expires_at":"2026-09-22T01:00:00.123456Z"}
            """
            return (200, Data(json.utf8))
        }

        let result = try await client.requestChallenge()

        XCTAssertEqual(result.challengeId, "c1")
        XCTAssertEqual(result.challenge, "abc")
        XCTAssertEqual(result.expiresAt.timeIntervalSince1970, 1790038800.123456, accuracy: 0.001)
    }

    func testRegisterSendsSnakeCaseBodyWithBase64AttestationObject() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/installations")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let body = try JSONSerialization.jsonObject(with: request.bodyData!) as! [String: String]
            XCTAssertEqual(body["challenge_id"], "c1")
            XCTAssertEqual(body["key_id"], "key-1")
            XCTAssertEqual(body["attestation_object"], Data("hello".utf8).base64EncodedString())

            let json = """
            {"installation_id":"i1","credential":"cred","expires_at":"2026-09-22T01:00:00Z"}
            """
            return (201, Data(json.utf8))
        }

        let result = try await client.register(challengeId: "c1", keyId: "key-1", attestationObject: Data("hello".utf8))

        XCTAssertEqual(result.installationId, "i1")
        XCTAssertEqual(result.credential, "cred")
    }

    func testRenewSendsBearerAuthorizationHeader() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/installations/credentials/renew")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer old-credential")
            let json = """
            {"credential":"new-cred","expires_at":"2026-09-22T01:00:00Z"}
            """
            return (200, Data(json.utf8))
        }

        let result = try await client.renewCredential(
            currentCredential: "old-credential", challengeId: "c1", assertionObject: Data("x".utf8))

        XCTAssertEqual(result.credential, "new-cred")
    }

    func testServerErrorIsMappedToCapPickAPIError() async throws {
        StubURLProtocol.handler = { _ in
            let json = """
            {"error":{"code":"CHALLENGE_EXPIRED","message":"만료됐습니다.","retryable":true},"request_id":"req_1"}
            """
            return (400, Data(json.utf8))
        }

        do {
            _ = try await client.requestChallenge()
            XCTFail("expected error")
        } catch let CapPickAPIError.server(status, code, message, retryable) {
            XCTAssertEqual(status, 400)
            XCTAssertEqual(code, "CHALLENGE_EXPIRED")
            XCTAssertEqual(message, "만료됐습니다.")
            XCTAssertTrue(retryable)
        }
    }

    func testUnparseableErrorBodyFallsBackToUnexpectedResponse() async throws {
        StubURLProtocol.handler = { _ in (500, Data("not json".utf8)) }

        do {
            _ = try await client.requestChallenge()
            XCTFail("expected error")
        } catch CapPickAPIError.unexpectedResponse(let status) {
            XCTAssertEqual(status, 500)
        }
    }
}

