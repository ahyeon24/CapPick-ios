import Foundation

// 모든 API 클라이언트가 공유하는 응답 처리: 2xx가 아니면 API 명세 §2 오류 형식으로 파싱해
// CapPickAPIError.server로 바꾼다. Job 등 새 클라이언트를 추가할 때도 이걸 쓴다.
enum CapPickHTTP {
    static func send<Response: Decodable>(_ request: URLRequest, session: URLSession) async throws -> Response {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CapPickAPIError.network(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CapPickAPIError.network("no HTTP response")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if let errorBody = try? CapPickJSON.decoder.decode(ApiErrorResponseDTO.self, from: data) {
                throw CapPickAPIError.server(
                    status: httpResponse.statusCode,
                    code: errorBody.error.code,
                    message: errorBody.error.message,
                    retryable: errorBody.error.retryable
                )
            }
            throw CapPickAPIError.unexpectedResponse(status: httpResponse.statusCode)
        }

        do {
            return try CapPickJSON.decoder.decode(Response.self, from: data)
        } catch {
            throw CapPickAPIError.decoding("\(error)")
        }
    }
}
