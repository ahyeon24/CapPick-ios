import XCTest
@testable import CapPick

/// substring-only(현재 서버 경로와 유사한 어휘 일치) / embedding-only(OnnxEmbeddingService만) /
/// hybrid-RRF(둘을 Reciprocal Rank Fusion으로 결합) 세 가지 검색 전략을 같은 한국어 코퍼스·질의로
/// 비교하는 평가 하네스다. **아직 SearchService에 어떤 것도 연결하지 않는다** — Phase 3 진행 여부를
/// 실제 데이터로 판단하기 위한 측정 전용 코드다.
///
/// 코퍼스는 "문서는 단어 A만 담고 있는데, 사용자는 의미가 같은 다른 단어 B로 검색한다"는 상황을
/// 재현한다(예: 문서엔 "사주"만 있고 "운세"로 검색) — 이게 substring-only가 원리적으로 못 푸는
/// 문제이자 embedding을 도입하려는 이유 그 자체다. 반대로 브랜드명·운송장번호·출구번호처럼
/// **정확한 문자열 일치가 의미상 비슷한 다른 문서와 구분해주는 근거인 경우**도 같이 넣어서, embedding만
/// 쓸 때 실제로 잃는 게 무엇인지도 같이 측정한다.
final class SearchStrategyEvaluationTests: XCTestCase {
    private struct Document {
        let id: String
        let text: String
    }

    private struct EvalCase {
        let label: String
        let query: String
        let expectedDocumentID: String
        let kind: Kind

        enum Kind: String {
            case lexical
            case semantic
            case exactStringFavoring
        }
    }

    private static let corpus: [Document] = [
        Document(id: "saju", text: "사주 오행 분석 결과입니다. 생년월일 기준으로 사주팔자를 정리했어요."),
        Document(id: "interview", text: "카카오 백엔드 개발자 채용 면접 질문 정리 - 자료구조와 네트워크 위주로 준비"),
        Document(id: "pasta", text: "홍대 파스타 맛집 웨이팅 후기, 크림 파스타 진짜 존맛"),
        Document(id: "os", text: "운영체제 시험 범위 프로세스 스케줄링 챕터 정리 노트"),
        Document(id: "dress", text: "여름 원피스 신상 할인 쇼핑몰 장바구니 캡처해둠"),
        Document(id: "starbucks", text: "스타벅스 아메리카노 영수증 4500원 결제 완료"),
        Document(id: "coffeebean", text: "커피빈 아메리카노 영수증 4800원 결제 완료"),
        Document(id: "trackingA", text: "택배 운송장번호 394857102934 배송 조회 결과"),
        Document(id: "trackingB", text: "택배 운송장번호 118823940111 배송 조회 결과"),
        Document(id: "gangnam3", text: "강남역 3번 출구에서 만나기로 함 저녁 약속"),
        Document(id: "gangnam5", text: "강남역 5번 출구 CU 편의점 앞에서 만나기로 함"),
        Document(id: "movie", text: "영화 예매 확인 CGV 아바타 3 좌석 F14"),
        Document(id: "gym", text: "헬스 루틴 기록 가슴 등 3분할 스쿼트 무게"),
        Document(id: "meeting", text: "팀 회의록 캡처 다음 스프린트 일정 논의"),
        Document(id: "map", text: "지도 길찾기 캡처 회사까지 버스 노선"),
        Document(id: "bank", text: "은행 계좌 이체 내역 캡처 전세자금 대출"),
        Document(id: "netflix", text: "넷플릭스 추천 드라마 목록 캡처해둠"),
        Document(id: "weather", text: "날씨 앱 캡처 이번주 미세먼지 나쁨"),
        Document(id: "recipe", text: "김치찌개 레시피 캡처 재료 손질법"),
    ]

    private static let evalCases: [EvalCase] = [
        EvalCase(label: "사주(원문 단어)", query: "사주", expectedDocumentID: "saju", kind: .lexical),
        EvalCase(label: "사주→운세(의미만 같음)", query: "운세", expectedDocumentID: "saju", kind: .semantic),
        EvalCase(label: "면접(원문 단어)", query: "백엔드 개발자 면접", expectedDocumentID: "interview", kind: .lexical),
        EvalCase(label: "면접→인터뷰(의미만 같음)", query: "개발자 인터뷰 후기", expectedDocumentID: "interview", kind: .semantic),
        EvalCase(label: "파스타 맛집(원문 단어)", query: "파스타 맛집", expectedDocumentID: "pasta", kind: .lexical),
        EvalCase(label: "맛집→데이트 식당(의미만 같음)", query: "데이트하기 좋은 식당 추천", expectedDocumentID: "pasta", kind: .semantic),
        EvalCase(label: "운영체제(원문 단어)", query: "운영체제 시험", expectedDocumentID: "os", kind: .lexical),
        EvalCase(label: "운영체제→OS(의미만 같음)", query: "OS 시험 공부 자료", expectedDocumentID: "os", kind: .semantic),
        EvalCase(label: "원피스(원문 단어)", query: "원피스 쇼핑", expectedDocumentID: "dress", kind: .lexical),
        EvalCase(label: "원피스→옷(상위어, 의미만 같음)", query: "옷 쇼핑몰 할인", expectedDocumentID: "dress", kind: .semantic),
        EvalCase(label: "브랜드 정확 일치 - 스타벅스", query: "스타벅스 영수증", expectedDocumentID: "starbucks", kind: .exactStringFavoring),
        EvalCase(label: "운송장번호 정확 일치", query: "394857102934", expectedDocumentID: "trackingA", kind: .exactStringFavoring),
        EvalCase(label: "출구 번호 정확 일치 - 강남역 3번", query: "강남역 3번 출구", expectedDocumentID: "gangnam3", kind: .exactStringFavoring),
    ]

    private static let rrfConstant = 60.0

    func testCompareSearchStrategies() async throws {
        let embeddingService = OnnxEmbeddingService()

        var docEmbeddings: [String: [Double]] = [:]
        for doc in Self.corpus {
            docEmbeddings[doc.id] = try await embeddingService.embed(doc.text, as: .passage)
        }

        // rank == nil이면 그 전략의 결과 목록에 정답 문서가 아예 없었다는 뜻(특히 substring은
        // 어휘가 하나도 안 겹치면 그 문서를 후보에서 통째로 뺀다).
        var ranks: [String: [Int?]] = ["substring": [], "embedding": [], "hybridRRF": []]
        var ranksByKind: [EvalCase.Kind: [String: [Int?]]] = [:]

        for evalCase in Self.evalCases {
            let queryEmbedding = try await embeddingService.embed(evalCase.query, as: .query)

            let substringRanking = Self.substringRanking(query: evalCase.query, corpus: Self.corpus)
            let embeddingRanking = Self.embeddingRanking(queryEmbedding: queryEmbedding, docEmbeddings: docEmbeddings, corpus: Self.corpus)
            let hybridRanking = Self.rrfRanking(substringRanking, embeddingRanking, corpus: Self.corpus, k: Self.rrfConstant)

            for (strategy, ranking) in [("substring", substringRanking), ("embedding", embeddingRanking), ("hybridRRF", hybridRanking)] {
                let rank = ranking.firstIndex { $0.id == evalCase.expectedDocumentID }.map { $0 + 1 }
                ranks[strategy, default: []].append(rank)
                ranksByKind[evalCase.kind, default: [:]][strategy, default: []].append(rank)
            }

            print("[\(evalCase.kind.rawValue)] \(evalCase.label) — 기대: \(evalCase.expectedDocumentID)")
            print("  substring top5: \(substringRanking.prefix(5).map(\.id))")
            print("  embedding top5: \(embeddingRanking.prefix(5).map(\.id))")
            print("  hybridRRF top5: \(hybridRanking.prefix(5).map(\.id))")
        }

        func printHitRates(_ ranks: [String: [Int?]], title: String) {
            print("\n=== \(title) ===")
            for strategy in ["substring", "embedding", "hybridRRF"] {
                let values = ranks[strategy] ?? []
                let total = values.count
                guard total > 0 else { continue }
                let top1 = values.filter { $0 == 1 }.count
                let top3 = values.filter { if let r = $0 { return r <= 3 } else { return false } }.count
                let top5 = values.filter { if let r = $0 { return r <= 5 } else { return false } }.count
                print("\(strategy): Top1 \(top1)/\(total) (\(String(format: "%.0f%%", 100.0 * Double(top1) / Double(total)))) · "
                    + "Top3 \(top3)/\(total) (\(String(format: "%.0f%%", 100.0 * Double(top3) / Double(total)))) · "
                    + "Top5 \(top5)/\(total) (\(String(format: "%.0f%%", 100.0 * Double(top5) / Double(total))))")
            }
        }

        printHitRates(ranks, title: "전체 히트율")
        for kind in [EvalCase.Kind.lexical, .semantic, .exactStringFavoring] {
            printHitRates(ranksByKind[kind] ?? [:], title: "\(kind.rawValue) 히트율")
        }

        // 정성적 기대: "의미만 같음" 질의에도 흔한 단어(예: "개발자")가 우연히 겹칠 수 있어 substring이
        // 부분 점수를 받는 걸 완전히 막지는 않는다(실제 사용자 질의도 그렇다) — 그래도 embedding이
        // 그 격차를 메워서 Top-1 히트 수가 substring보다 낮으면 안 된다.
        let semanticSubstringTop1 = (ranksByKind[.semantic]?["substring"] ?? []).filter { $0 == 1 }.count
        let semanticEmbeddingTop1 = (ranksByKind[.semantic]?["embedding"] ?? []).filter { $0 == 1 }.count
        XCTAssertGreaterThanOrEqual(semanticEmbeddingTop1, semanticSubstringTop1, "의미만 같고 단어가 다른 질의에서 embedding의 Top-1이 substring-only보다 나쁘면 안 된다 — embedding 도입 근거 자체가 흔들린다")
    }

    private static func substringRanking(query: String, corpus: [Document]) -> [Document] {
        let tokens = query.lowercased().split(separator: " ").map(String.init)
        let scored = corpus.compactMap { doc -> (Document, Int)? in
            let haystack = doc.text.lowercased()
            let score = tokens.filter { haystack.contains($0) }.count
            return score > 0 ? (doc, score) : nil
        }
        return scored.sorted { $0.1 > $1.1 }.map(\.0)
    }

    private static func embeddingRanking(
        queryEmbedding: [Double],
        docEmbeddings: [String: [Double]],
        corpus: [Document]
    ) -> [Document] {
        let scored = corpus.map { doc -> (Document, Double) in
            let docEmbedding = docEmbeddings[doc.id] ?? []
            let similarity = zip(queryEmbedding, docEmbedding).reduce(0.0) { $0 + $1.0 * $1.1 }
            return (doc, similarity)
        }
        return scored.sorted { $0.1 > $1.1 }.map(\.0)
    }

    private static func rrfRanking(
        _ substringRanking: [Document],
        _ embeddingRanking: [Document],
        corpus: [Document],
        k: Double
    ) -> [Document] {
        var scores: [String: Double] = [:]
        for (rank, doc) in substringRanking.enumerated() {
            scores[doc.id, default: 0] += 1.0 / (k + Double(rank + 1))
        }
        for (rank, doc) in embeddingRanking.enumerated() {
            scores[doc.id, default: 0] += 1.0 / (k + Double(rank + 1))
        }
        return corpus.sorted { (scores[$0.id] ?? 0) > (scores[$1.id] ?? 0) }
    }
}
