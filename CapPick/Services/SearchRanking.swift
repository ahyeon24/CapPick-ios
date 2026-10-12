import Foundation

/// 검색 대상 캡처 한 장 — capture + captureAnalysis(ocrText) + searchDocument(searchText,
/// embedding)를 조인한 결과. 아직 분석이 끝나지 않은 캡처(searchDocument 없음)는 후보에서 아예
/// 빠진다 — GRDBCaptureStore.fetchSearchCandidates()가 INNER JOIN으로 걸러낸다.
struct SearchCandidate: Equatable {
    let capture: Capture
    let ocrText: String?
    let searchText: String?
    let embedding: [Double]
}

// 키워드 검색(SEARCH-02)과 의미 검색(SEARCH-01·03)을 Reciprocal Rank Fusion으로 결합해 정렬한다.
// 순수 함수 — I/O 없음.
//
// CapPickTests/SearchStrategyEvaluationTests에서 substring-only / embedding-only와 비교 평가한
// hybrid-RRF를 그대로 옮겼다(2026-10-08, 파라미터는 평가 때 값 그대로 — 실제 앨범 규모에서의
// 튜닝은 아직 안 했다):
// - 키워드 쪽: 검색어를 공백으로 나눈 토큰 중 몇 개가 추출 글자(ocrText)·검색용 표현(searchText)에
//   들어 있는지로 순위를 매기고, 기여도에 matchRatio(일치 토큰 수 / 전체 토큰 수)를 곱한다 —
//   토큰 하나만 우연히 겹친 캡처가 전부 겹친 캡처와 같은 보너스를 받지 않게 하려는 것.
// - 의미 쪽: 코사인 유사도 순위. e5 계열은 유사도 절대값이 좁은 구간에 몰려 있어서 점수 자체가
//   아니라 순위만 쓴다.
// - 결과에 넣는 기준(2026-10-12, 사용자 결정 — 전에는 순위만 매기고 전부 보여줘서 관련 없는
//   캡처까지 끝없이 나왔다): 글자가 일치한 캡처는 항상 넣는다. 의미로만 걸린 캡처는 그 검색에서
//   유사도 1위와의 차이가 semanticGapThreshold 이내인 것만, 최대 semanticOnlyLimit장까지 넣는다.
//   유사도 절대값으로 자르지 않는 이유는 검색어마다 점수 높낮이 자체가 달라서다(관련 캡처가 없는
//   "고양이 사진"의 1위 0.822 ≈ "면접"의 진짜 1위 0.824).
enum SearchRanking {
    /// RRF 문헌의 표준값 60은 웹 규모용이라 개인 앨범 규모에 맞춰 낮춘 값(평가 하네스와 동일).
    private static let rrfConstant = 5.0

    /// ⚠️ 잠정치 — 계속 조정해 나가야 하는 값이다(사용자 당부, 2026-10-12). 시뮬레이터의 캡처
    /// 8장으로 잰 유사도(전체가 0.72~0.86에 몰려 있고, 진짜 관련 캡처는 다음 캡처보다 0.02~0.06
    /// 앞섰다)를 보고 잡았을 뿐, 실제 앨범 규모(수백~수천 장)에서 검증한 적이 없다. 캡처가
    /// 많아지면 1위 근처에 몰리는 캡처도 늘어나므로 더 좁혀야 할 가능성이 있다.
    static let semanticGapThreshold = 0.03

    /// 관련 캡처가 없는 검색어는 유사도가 고르게 퍼져서 위 기준을 많이 통과한다 — 그때 수천 장이
    /// 쏟아지는 것만 막는 안전장치다(좋은 결과를 고르는 용도가 아니라서 넉넉하게 잡은 잠정치).
    static let semanticOnlyLimit = 50

    static func rank(_ candidates: [SearchCandidate], lexicalTerms: [String], queryEmbedding: [Double]) -> [Capture] {
        let terms = lexicalTerms.map { $0.lowercased() }.filter { !$0.isEmpty }
        var scores = [Double](repeating: 0, count: candidates.count)
        var included = Set<Int>()

        if !terms.isEmpty {
            let keywordRanking = candidates.indices
                .map { (index: $0, matched: matchedTermCount(candidates[$0], terms: terms)) }
                .filter { $0.matched > 0 }
                .sorted { ($0.matched, $1.index) > ($1.matched, $0.index) }
            for (rank, entry) in keywordRanking.enumerated() {
                let matchRatio = Double(entry.matched) / Double(terms.count)
                scores[entry.index] += matchRatio / (rrfConstant + Double(rank + 1))
                included.insert(entry.index)
            }
        }

        let vectorRanking = candidates.indices
            .map { (index: $0, similarity: cosineSimilarity(queryEmbedding, candidates[$0].embedding)) }
            .filter { $0.similarity > 0 }
            .sorted { ($0.similarity, $1.index) > ($1.similarity, $0.index) }
        for (rank, entry) in vectorRanking.enumerated() {
            scores[entry.index] += 1.0 / (rrfConstant + Double(rank + 1))
        }
        if let best = vectorRanking.first?.similarity {
            let semanticOnly = vectorRanking
                .filter { !included.contains($0.index) && best - $0.similarity <= semanticGapThreshold }
                .prefix(semanticOnlyLimit)
            included.formUnion(semanticOnly.map(\.index))
        }

        // 점수가 같으면 들어온 순서(최근 캡처 먼저)를 유지한다.
        return candidates.indices
            .filter { included.contains($0) }
            .sorted { (scores[$0], $1) > (scores[$1], $0) }
            .map { candidates[$0].capture }
    }

    private static func matchedTermCount(_ candidate: SearchCandidate, terms: [String]) -> Int {
        let haystack = [candidate.ocrText, candidate.searchText]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        guard !haystack.isEmpty else { return 0 }
        // 기기 OCR은 화면에서 줄바꿈된 단어를 줄 단위로 끊어서 돌려준다("진\n입") — 줄바꿈을 지운
        // 버전에서도 한 번 더 찾아서 줄 경계에 걸친 단어를 잡는다(2026-10-08).
        let unwrapped = haystack.replacingOccurrences(of: "\n", with: "")
        return terms.filter { haystack.contains($0) || unwrapped.contains($0) }.count
    }

    private static func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, normA = 0.0, normB = 0.0
        for i in a.indices {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (normA.squareRoot() * normB.squareRoot())
    }
}
