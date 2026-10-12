import Foundation

/// 자연어 검색 실행 (기능명세서 SEARCH-01·02·03·06). 2026-10-08부터 서버·AI를 전혀 거치지 않고
/// 기기 안에서만 처리한다(사용자 결정, 2026-09-25) — 날짜 표현은 LocalDateInterpreter가, 검색어
/// 벡터는 번들된 모델(TextEmbedding)이 만들고, 매칭·정렬은 로컬 DB에서 SearchRanking으로 한다.
actor SearchService {
    private let embedder: any TextEmbedding
    private let captureStore: any CaptureStoring

    init(embedder: any TextEmbedding, captureStore: any CaptureStoring) {
        self.embedder = embedder
        self.captureStore = captureStore
    }

    /// 빈 검색어는 호출하지 않는다 — SEARCH-06: 빈 검색어는 로컬 전체 탐색(이미
    /// BrowseViewModel.load()가 그 역할을 한다). folderID가 있으면 그 폴더 범위로만 검색한다(SEARCH-04).
    func search(query: String, folderID: String?) async throws -> [Capture] {
        let interpreted = LocalDateInterpreter.interpret(query)
        try await reembedStaleDocuments()

        let candidates = try await captureStore.fetchSearchCandidates(
            capturedFrom: interpreted.capturedFrom, capturedBefore: interpreted.capturedBefore, folderID: folderID
        )
        // 분석 완료된 캡처가 아직 하나도 없으면 검색 대상 자체가 없다(SEARCH-08).
        guard !candidates.isEmpty else { return [] }

        let searchText = interpreted.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        // "지난주"처럼 날짜 표현만 있는 검색어 — 그 기간의 캡처를 최근순 그대로 보여준다.
        guard !searchText.isEmpty else { return candidates.map(\.capture) }

        let lexicalTerms = searchText.split(whereSeparator: \.isWhitespace).map(String.init)
        // 벡터를 못 만들어도(모델 로드 실패 등) 키워드 검색은 계속 되게 한다.
        let queryEmbedding = (try? await embedder.embed(searchText, as: .query)) ?? []
        return SearchRanking.rank(candidates, lexicalTerms: lexicalTerms, queryEmbedding: queryEmbedding)
    }

    /// 지금 모델과 다른 버전으로 만든 벡터(서버 Gemini 임베딩을 쓰던 시절 분석된 캡처, 또는 분석
    /// 당시 벡터 생성에 실패한 캡처)를 기기에서 다시 만든다. searchText는 그대로 재사용하므로 AI
    /// 비용이 들지 않는다. 다시 만들 게 없으면 조회 한 번으로 끝난다.
    private func reembedStaleDocuments() async throws {
        let stale = try await captureStore.fetchStaleSearchTexts(currentModelVersion: embedder.modelVersion)
        for document in stale {
            guard let embedding = try? await embedder.embed(document.searchText, as: .passage), !embedding.isEmpty else {
                continue // 빈 searchText 등 — 벡터 없이 키워드로만 검색된다.
            }
            try await captureStore.updateSearchEmbedding(
                captureID: document.captureID, embedding: embedding, modelVersion: embedder.modelVersion)
        }
    }
}
