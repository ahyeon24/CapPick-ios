import Foundation

// 서버가 전역으로 snake_case JSON, Instant를 ISO-8601(밀리초 이하 포함)로 내보낸다
// (CapPick-server/CLAUDE.md "스택" 절). 인코더·디코더를 한 곳에서 맞춰 재사용한다.
//
// ISO8601DateFormatter는 Sendable이 아니라 static 공유 인스턴스로 두지 않는다 — 호출마다
// 새로 만든다. 빈도가 낮은 API 요청/응답 처리라 비용은 무시할 만하다.
enum CapPickJSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(makeFormatter(fractional: true).string(from: date))
        }
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = makeFormatter(fractional: true).date(from: string) {
                return date
            }
            if let date = makeFormatter(fractional: false).date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid ISO-8601 date: \(string)")
        }
        return decoder
    }()

    private static func makeFormatter(fractional: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractional
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }
}

// API 명세 §2 공통 오류 형식.
struct ApiErrorResponseDTO: Decodable {
    let error: ApiErrorBodyDTO
    let requestId: String
}

struct ApiErrorBodyDTO: Decodable {
    let code: String
    let message: String
    let retryable: Bool
}
