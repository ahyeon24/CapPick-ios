// 설치 자격(credential)은 비밀 값이라 GRDB(AppState) 평문 저장 대상이 아니다(ERD §2 AppState 주석,
// CapPick-server/CLAUDE.md "자격 형식" 결정과 짝). Keychain 등 별도 저장소를 쓴다.
protocol CredentialStoring: Sendable {
    func save(_ credential: String) throws
    func load() throws -> String?
    func delete() throws
}
