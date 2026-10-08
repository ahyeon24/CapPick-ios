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

// 키워드 검색(SEARCH-02)과 의미 검색(SEARCH-01·03)을 결합해 정렬한다. 순수 함수 — I/O 없음.
//
// 결합 방식은 잠정치다: 기능명세서 §3.2가 "결합 방식·점수 기준은 샘플 평가 후 결정"이라고 스스로
// 명시한 미정 항목이라, 지금은 키워드 일치(추출 글자 ocrText 또는 검색용 표현 searchText에
// lexicalTerms 중 하나라도 포함되면 1.0, 아니면 0.0)와 코사인 유사도(음수는 0으로 clamp)를 단순
// 합산만 한다. 가중치·임계값은 실제 검색 품질을 보고 조정할 것.
enum SearchRanking {
    static func rank(_ candidates: [SearchCandidate], lexicalTerms: [String], queryEmbedding: [Double]) -> [Capture] {
        let terms = lexicalTerms.map { $0.lowercased() }.filter { !$0.isEmpty }

        return candidates
            .map { candidate in (candidate.capture, score(candidate, terms: terms, queryEmbedding: queryEmbedding)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    private static func score(_ candidate: SearchCandidate, terms: [String], queryEmbedding: [Double]) -> Double {
        let keywordScore = matchesKeyword(candidate, terms: terms) ? 1.0 : 0.0
        let vectorScore = max(0, cosineSimilarity(queryEmbedding, candidate.embedding))
        return keywordScore + vectorScore
    }

    private static func matchesKeyword(_ candidate: SearchCandidate, terms: [String]) -> Bool {
        guard !terms.isEmpty else { return false }
        let haystack = [candidate.ocrText, candidate.searchText]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        guard !haystack.isEmpty else { return false }
        // 기기 OCR은 화면에서 줄바꿈된 단어를 줄 단위로 끊어서 돌려준다("진\n입") — 줄바꿈을 지운
        // 버전에서도 한 번 더 찾아서 줄 경계에 걸친 단어를 잡는다(2026-10-08).
        let unwrapped = haystack.replacingOccurrences(of: "\n", with: "")
        return terms.contains { haystack.contains($0) || unwrapped.contains($0) }
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
