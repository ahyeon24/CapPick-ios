import XCTest
@testable import CapPick

final class URLSessionJobAPIClientTests: XCTestCase {
    private var client: URLSessionJobAPIClient!

    override func setUp() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        client = URLSessionJobAPIClient(
            session: URLSession(configuration: configuration), baseURL: URL(string: "https://api.example.invalid")!)
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
    }

    func testSubmitSendsMultipartWithMetadataAndImageParts() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/jobs")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer cred-1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "key-1")
            let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
            XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))

            let body = String(decoding: request.bodyData ?? Data(), as: UTF8.self)
            XCTAssertTrue(body.contains("name=\"metadata\""))
            XCTAssertTrue(body.contains("\"client_reference\":\"capture-1\""))
            XCTAssertTrue(body.contains("\"content_revision\":3"))
            XCTAssertTrue(body.contains("name=\"image\"; filename=\"capture.jpg\""))
            XCTAssertTrue(body.contains("Content-Type: image/jpeg"))

            let json = """
            {"job_id":"job-1","status":"queued","poll_after_seconds":2}
            """
            return (202, Data(json.utf8))
        }

        let result = try await client.submitContentAnalysis(
            clientReference: "capture-1", contentRevision: 3, ocrTextHint: nil,
            imageData: Data("fake-jpeg".utf8), credential: "cred-1", idempotencyKey: "key-1")

        XCTAssertEqual(result.jobId, "job-1")
        XCTAssertEqual(result.status, .queued)
        XCTAssertEqual(result.pollAfterSeconds, 2)
    }

    func testFetchJobStatusParsesSucceededResultWithSnakeCaseFields() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/jobs/job-1")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer cred-1")

            let json = """
            {"job_id":"job-1","status":"succeeded","client_reference":"capture-1",
             "result":{"analysis_revision":1,"ocr_text":"실습 1","observed_evidence":["행렬곱 문제"],
                        "search_text":"알고리즘 실습","embedding":[0.1,0.2],"embedding_model_version":"embed-v1"},
             "result_expires_at":"2026-09-23T00:00:00Z","error":null}
            """
            return (200, Data(json.utf8))
        }

        let result = try await client.fetchJobStatus(jobId: "job-1", credential: "cred-1")

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(result.result?.ocrText, "실습 1")
        XCTAssertEqual(result.result?.observedEvidence, ["행렬곱 문제"])
        XCTAssertEqual(result.result?.embedding, [0.1, 0.2])
        XCTAssertNotNil(result.resultExpiresAt)
        XCTAssertNil(result.error)
    }

    func testFetchJobStatusParsesFailedResultWithError() async throws {
        StubURLProtocol.handler = { _ in
            let json = """
            {"job_id":"job-1","status":"failed","client_reference":"capture-1","result":null,
             "result_expires_at":null,"error":{"code":"ANALYSIS_FAILED","message":"실패","retryable":true}}
            """
            return (200, Data(json.utf8))
        }

        let result = try await client.fetchJobStatus(jobId: "job-1", credential: "cred-1")

        XCTAssertEqual(result.status, .failed)
        XCTAssertNil(result.result)
        XCTAssertEqual(result.error?.code, "ANALYSIS_FAILED")
    }

    func testServerErrorOnSubmitIsMappedToCapPickAPIError() async throws {
        StubURLProtocol.handler = { _ in
            let json = """
            {"error":{"code":"IDEMPOTENCY_CONFLICT","message":"충돌","retryable":false},"request_id":"req_1"}
            """
            return (409, Data(json.utf8))
        }

        do {
            _ = try await client.submitContentAnalysis(
                clientReference: "c1", contentRevision: 1, ocrTextHint: nil,
                imageData: Data(), credential: "cred-1", idempotencyKey: "key-1")
            XCTFail("expected error")
        } catch let CapPickAPIError.server(status, code, _, _) {
            XCTAssertEqual(status, 409)
            XCTAssertEqual(code, "IDEMPOTENCY_CONFLICT")
        }
    }
}
