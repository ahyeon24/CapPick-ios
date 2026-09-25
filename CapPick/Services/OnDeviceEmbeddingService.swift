import Foundation
import NaturalLanguage

enum OnDeviceEmbeddingError: Error, Equatable {
    /// 모델 에셋이 기기에 없고 요청도 실패했을 때 — 최초 실행이 오프라인이면 날 수 있다.
    case assetsUnavailable
    case emptyText
}

/// 온디바이스 검색 전환 Phase 2. Apple `NLContextualEmbedding`(NaturalLanguage 프레임워크,
/// iOS 17+)으로 캡처 검색용 텍스트와 검색어를 **같은 모델**로 벡터화한다 — Gemini `embedContent`를
/// 대체할 후보. **아직 SearchService에 연결하지 않는다** — 병행 평가(evaluation) 전용이다.
///
/// NLContextualEmbedding은 문장 하나짜리 벡터를 바로 안 주고 토큰별 벡터 시퀀스를 준다
/// (`enumerateTokenVectors`) — 이 서비스가 평균을 내서 문장 벡터 하나로 만든다(mean pooling,
/// 풀링 방식을 따로 노출 안 하는 모델에서 흔히 쓰는 가장 단순한 방식. 더 정교한 풀링이 필요한지는
/// 6절 평가 결과를 보고 판단한다).
actor OnDeviceEmbeddingService {
    private var embedding: NLContextualEmbedding?
    private var loadError: Error?

    /// `SearchDocument.embeddingModelVersion`에 그대로 저장할 값. `modelIdentifier`+`revision`을
    /// 실제 로드된 모델 인스턴스에서 읽어서 만든다 — 하드코딩한 문자열이 아니다. OS가 모델을
    /// 갱신하면 이 값도 자동으로 달라지므로, 저장된 문서의 버전과 비교하면 모델이 바뀌었는지
    /// 알 수 있다(NLContextualEmbedding.md "버전 호환성" 절 참고).
    private(set) var modelVersion: String?

    /// 실제로 임베딩을 계산할 수 있는 상태로 모델을 준비한다 — 에셋이 없으면 다운로드까지 기다린다.
    /// 여러 번 불러도 안전하다(이미 로드됐으면 즉시 반환).
    func prepare() async throws {
        if embedding != nil { return }
        if let loadError { throw loadError }

        let model = NLContextualEmbedding(language: .korean)
        guard let model else {
            let error = OnDeviceEmbeddingError.assetsUnavailable
            loadError = error
            throw error
        }

        if !model.hasAvailableAssets {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                model.requestAssets { result, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
        try model.load()

        embedding = model
        modelVersion = "\(model.modelIdentifier)-r\(model.revision)"
    }

    /// 텍스트 하나를 벡터 하나로. 빈 문자열은 벡터가 없으니 에러.
    func embed(_ text: String) async throws -> [Double] {
        try await prepare()
        guard let embedding else { throw OnDeviceEmbeddingError.assetsUnavailable }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OnDeviceEmbeddingError.emptyText }

        let result = try embedding.embeddingResult(for: trimmed, language: .korean)
        var sum: [Double] = []
        var count = 0
        result.enumerateTokenVectors(in: trimmed.startIndex..<trimmed.endIndex) { vector, _ in
            if sum.isEmpty {
                sum = vector
            } else {
                for i in vector.indices { sum[i] += vector[i] }
            }
            count += 1
            return true
        }
        guard count > 0 else { throw OnDeviceEmbeddingError.emptyText }
        return sum.map { $0 / Double(count) }
    }
}
