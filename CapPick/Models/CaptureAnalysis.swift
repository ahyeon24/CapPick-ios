// ERD v0.2 §2 CaptureAnalysis. 검색·직접 근거 기반 분류에 필요한 내부 정보 — 사용자에게
// 제목/설명/태그로 노출하지 않는다 (기능명세서 v0.11 §7 변경 이력).
struct CaptureAnalysis: Equatable {
    let captureID: String
    let contentRevision: Int
    let analysisRevision: Int
    let ocrText: String?
    let observedEvidence: [String]
    let modelVersion: String
}
