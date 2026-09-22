import Foundation

/// 자연어 검색 실행 (기능명세서 SEARCH-01·02·03·06). 서버 `/v1/search/prepare`로 질의를
/// 해석·임베딩만 받고, 실제 캡처 매칭·정렬은 로컬 DB에서 SearchRanking으로 한다 — 서버는
/// 스크린샷 데이터를 전혀 안 본다(시스템 설계 §5).
actor SearchService {
    private let searchAPIClient: any SearchAPIClient
    private let installationRegistrar: InstallationRegistrar
    private let captureStore: any CaptureStoring

    init(
        searchAPIClient: any SearchAPIClient,
        installationRegistrar: InstallationRegistrar,
        captureStore: any CaptureStoring
    ) {
        self.searchAPIClient = searchAPIClient
        self.installationRegistrar = installationRegistrar
        self.captureStore = captureStore
    }

    /// 빈 검색어는 호출하지 않는다 — SEARCH-06: 빈 검색어는 AI 요청 없이 로컬 전체 탐색(이미
    /// BrowseViewModel.load()가 그 역할을 한다).
    func search(query: String) async throws -> [Capture] {
        guard let embeddingModelVersion = try await captureStore.currentEmbeddingModelVersion() else {
            return [] // 분석 완료된 캡처가 아직 하나도 없음 — 검색 대상 자체가 없다(SEARCH-08).
        }
        let credential = try await installationRegistrar.ensureRegistered()
        let prepared = try await searchAPIClient.prepare(
            query: query, now: Date(), timezone: .current,
            embeddingModelVersion: embeddingModelVersion, credential: credential
        )
        let candidates = try await captureStore.fetchSearchCandidates(
            capturedFrom: prepared.capturedFrom, capturedBefore: prepared.capturedBefore
        )
        return SearchRanking.rank(candidates, lexicalTerms: prepared.lexicalTerms, queryEmbedding: prepared.embedding)
    }
}
