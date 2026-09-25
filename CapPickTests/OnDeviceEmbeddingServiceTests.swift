import XCTest
@testable import CapPick

// 실제 NLContextualEmbedding을 그대로 부른다(페이크 없음) — 목적 자체가 "진짜 온디바이스 모델이
// 쓸 만한가"를 확인하는 거라 목으로 대체하면 의미가 없다. 시뮬레이터에 에셋이 없으면 첫 실행이
// 느릴 수 있다(Apple이 기기로 내려받는 과정).
final class OnDeviceEmbeddingServiceTests: XCTestCase {
    func testPrepareSucceedsAndReportsModelVersion() async throws {
        let service = OnDeviceEmbeddingService()

        try await service.prepare()

        let version = await service.modelVersion
        XCTAssertNotNil(version)
        XCTAssertFalse(version!.isEmpty)
    }

    func testEmbedReturnsNonEmptyVectorWithConsistentDimension() async throws {
        let service = OnDeviceEmbeddingService()

        let a = try await service.embed("면접 준비 자료")
        let b = try await service.embed("전혀 다른 문장입니다")

        XCTAssertFalse(a.isEmpty)
        XCTAssertEqual(a.count, b.count, "같은 모델이면 어떤 입력이든 차원이 같아야 한다")
    }

    func testSameTextProducesTheSameVectorDeterministically() async throws {
        let service = OnDeviceEmbeddingService()

        let first = try await service.embed("사주 오행 분석 결과")
        let second = try await service.embed("사주 오행 분석 결과")

        XCTAssertEqual(first, second)
    }

    func testEmptyTextThrows() async throws {
        let service = OnDeviceEmbeddingService()

        do {
            _ = try await service.embed("   ")
            XCTFail("expected emptyText")
        } catch OnDeviceEmbeddingError.emptyText {
            // 기대한 대로
        }
    }
}
