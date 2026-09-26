import Foundation

// API 명세 §7 GET /v1/usage. 서버 UsageController/UsageService와 짝(CapPick-server/CLAUDE.md
// "사용량·삭제" 절 참고).
protocol UsageAPIClient: Sendable {
    func fetchUsage(credential: String) async throws -> UsageSummary
}

enum RemoteUsageCategory: String, Equatable, Sendable, Decodable {
    case contentAnalysis = "content_analysis"
    case classification
}

struct UsageSummary: Equatable, Sendable, Decodable {
    let categories: [UsageCategorySummary]
}

// limitUnits·resetsAt은 한도 정책이 미정이라 서버가 항상 null로 내려준다(진짜 "값 없음"이지
// "무제한"이 아니다 — API 명세 §7). canSubmit도 지금은 항상 true.
struct UsageCategorySummary: Equatable, Sendable, Decodable {
    let category: RemoteUsageCategory
    let usedUnits: Int
    let reservedUnits: Int
    let limitUnits: Int?
    let resetsAt: Date?
    let canSubmit: Bool
}
