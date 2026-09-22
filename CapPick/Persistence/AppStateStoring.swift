import GRDB

// ERD §2 AppState: 단순 키-값 앱 설정. 비밀 토큰은 여기에 저장하지 않는다.
enum AppStateKey {
    static let onboardingCompleted = "onboardingCompleted"
    /// 사용자가 "전체 캡처 분석 시작"을 눌렀는지("true") 나중에 시작하기/건너뛰기를 골랐는지("false").
    static let analysisStartRequested = "analysisStartRequested"
    /// App Attest 키 식별자(비밀 아님, App Attest 자체가 공개 식별자로 설계됨). 실제 자격(credential)은
    /// 여기 저장하지 않고 Keychain(KeychainCredentialStore)에 둔다.
    static let attestationKeyId = "attestationKeyId"
}

protocol AppStateStoring: Sendable {
    func value(for key: String) async throws -> String?
    func setValue(_ value: String, for key: String) async throws
}

struct GRDBAppStateStore: AppStateStoring {
    let database: AppDatabase

    func value(for key: String) async throws -> String? {
        try await database.dbWriter.read { db in
            try AppStateEntry.fetchOne(db, key: key)?.value
        }
    }

    func setValue(_ value: String, for key: String) async throws {
        try await database.dbWriter.write { db in
            try AppStateEntry(key: key, value: value).save(db)
        }
    }
}
