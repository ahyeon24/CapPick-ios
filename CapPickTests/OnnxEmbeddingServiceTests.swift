import XCTest
@testable import CapPick

// 실제 번들 모델을 그대로 부른다(목 없음) — NLContextualEmbedding 때와 같은 이유로, "진짜
// 온디바이스 모델이 쓸 만한가"를 확인하는 게 목적이라 목으로 대체하면 의미가 없다.
final class OnnxEmbeddingServiceTests: XCTestCase {
    func testPrepareSucceeds() async throws {
        let service = OnnxEmbeddingService()

        try await service.prepare()
    }

    func testEmbedReturnsNonEmptyVectorWithConsistentDimension() async throws {
        let service = OnnxEmbeddingService()

        let a = try await service.embed("면접 준비 자료", as: .passage)
        let b = try await service.embed("전혀 다른 문장입니다", as: .passage)

        XCTAssertFalse(a.isEmpty)
        XCTAssertEqual(a.count, b.count, "같은 모델이면 어떤 입력이든 차원이 같아야 한다")
        XCTAssertEqual(a.count, 384, "multilingual-e5-small의 hidden_size는 384다")
    }

    func testSameTextProducesTheSameVectorDeterministically() async throws {
        let service = OnnxEmbeddingService()

        let first = try await service.embed("사주 오행 분석 결과", as: .passage)
        let second = try await service.embed("사주 오행 분석 결과", as: .passage)

        XCTAssertEqual(first, second)
    }

    func testVectorIsL2Normalized() async throws {
        let service = OnnxEmbeddingService()

        let vector = try await service.embed("파스타 맛집 추천", as: .passage)
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })

        XCTAssertEqual(norm, 1.0, accuracy: 0.01)
    }

    func testQueryAndPassagePrefixesProduceDifferentVectorsForSameText() async throws {
        let service = OnnxEmbeddingService()

        let asQuery = try await service.embed("사주 운세", as: .query)
        let asPassage = try await service.embed("사주 운세", as: .passage)

        XCTAssertNotEqual(asQuery, asPassage, "query:/passage: 접두어가 다르면 토큰 시퀀스가 달라 벡터도 달라야 한다")
    }

    func testEmptyTextThrows() async throws {
        let service = OnnxEmbeddingService()

        do {
            _ = try await service.embed("   ", as: .query)
            XCTFail("expected emptyText")
        } catch OnnxEmbeddingError.emptyText {
            // 기대한 대로
        }
    }

    func testSemanticallySimilarTextsAreCloserThanUnrelatedOnes() async throws {
        // 세션에서 다음 단계로 예정된 평가 하네스의 미리보기 성격 — "사주"와 "운세"처럼 다른 단어,
        // 같은 의미가 임베딩 공간에서 실제로 가까운지 최소한으로 확인한다.
        let service = OnnxEmbeddingService()

        let target = try await service.embed("사주 운세를 봤다", as: .passage)
        let related = try await service.embed("오늘의 운세가 궁금해서 사주를 봤다", as: .passage)
        let unrelated = try await service.embed("파스타 맛집 데이트 코스 추천", as: .passage)

        func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
            zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
        }

        let relatedScore = cosineSimilarity(target, related)
        let unrelatedScore = cosineSimilarity(target, unrelated)

        XCTAssertGreaterThan(relatedScore, unrelatedScore)
    }
}
