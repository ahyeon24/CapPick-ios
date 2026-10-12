import Foundation

// 검색 벡터를 기기에서 만드는 경계. 실제 구현은 OnnxEmbeddingService(번들된 e5-small) 하나뿐이고,
// 113MB 모델을 띄우지 않고도 SearchService·ContentAnalysisService를 테스트할 수 있게 프로토콜로 뺐다.
protocol TextEmbedding: Sendable {
    /// 이 값이 다른 벡터끼리는 비교하면 안 된다(차원·공간이 다름).
    nonisolated var modelVersion: String { get }
    func embed(_ text: String, as kind: OnnxEmbeddingInputKind) async throws -> [Double]
}

extension OnnxEmbeddingService: TextEmbedding {
    nonisolated var modelVersion: String { Self.modelVersion }
}
