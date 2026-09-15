// ERD v0.2 §2 AppState. 분석 일시정지, 안내 버전, 삭제 대기 작업 등 단순 키-값 앱 설정.
// 비밀 토큰(설치 자격 등)은 이 테이블에 평문 저장하지 않는다 — Keychain 등 별도 저장소를 쓴다.
struct AppStateEntry: Equatable {
    let key: String
    var value: String
}
