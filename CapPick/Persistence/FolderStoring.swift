enum StoreError: Error, Equatable {
    case folderNotFound(String)
    case captureNotFound(String)
}

/// AI 자동 분류 결과를 반영하려 했을 때 실제로 어떻게 처리됐는지.
enum AutoMatchResult: Equatable, Sendable {
    case applied
    /// 판정 이후 폴더 분류 기준이 바뀌었다 — 늦게 도착한 결과를 반영하지 않는다 (시스템 설계 §8).
    case ignoredStaleCriteria
    /// 사용자가 직접 추가했거나 직접 제거한 관계는 자동 분류가 덮어쓰지 않는다 (기능명세서 §2, ERD §3).
    case ignoredUserDecision
    /// 접근 불가이거나 캡픽에서 제외한 캡처는 생략한다 (기능명세서 §3.3.2).
    case ignoredCaptureUnavailable
}

// 폴더 소속 변경 규칙(ERD §3 표)은 이 프로토콜 구현체 안에서만 구현한다.
protocol FolderStoring: Sendable {
    /// 저장·수정. 이름만 바꿔도 criteriaVersion은 호출하는 쪽이 올리지 않는다. membershipRevision은 덮어쓰지 않는다.
    func save(_ folder: Folder) async throws
    func fetchAll() async throws -> [Folder]
    /// 폴더와 그 소속·차단·재분류 기록만 지운다. 캡처 원본 기록은 유지한다.
    func delete(id: String) async throws

    func fetchMemberships(of folderID: String) async throws -> [FolderCapture]

    /// 직접 추가: present + manual, 기존 차단(blocked) 해제.
    func addManually(captureID: String, to folderID: String) async throws
    /// 직접 제거: blocked + manual — 소속은 없어지고 자동 재추가는 막힌다.
    func removeManually(captureID: String, from folderID: String) async throws
    /// AI 일치 결과 반영. `criteriaVersion`은 판정 요청 당시 폴더 기준 버전.
    func applyAutoMatch(
        captureID: String,
        to folderID: String,
        evidence: String?,
        criteriaVersion: Int
    ) async throws -> AutoMatchResult
}
