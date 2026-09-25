import Foundation

/// 온디바이스 검색 전환 Phase 1. 검색어에 섞인 상대적 날짜 표현("지난달 면접 자료")을 로컬에서
/// 찾아 날짜 구간으로 바꾼다 — 서버 `GeminiSearchInterpretationClient`가 하던 일 중 날짜 해석
/// 부분만 먼저 온디바이스로 옮긴 것이다(Gemini 프롬프트가 하던 지시를 그대로 규칙으로 옮김:
/// "캡처가 저장된 시점"만 다루고 이미지 속에 적힌 다른 날짜와는 무관, 시작 포함·끝 미포함).
///
/// **아직 SearchService에 연결하지 않는다** — 평가(evaluation) 목적으로 독립적으로만 쓴다.
/// 기존 검색 기능(서버 `/v1/search/prepare` 경유)은 이 타입과 무관하게 그대로 동작한다.
enum LocalDateInterpreter {
    struct Result: Equatable {
        /// 날짜 표현을 뺀 나머지 검색어. 공백은 정리된다.
        let searchText: String
        /// 시작 포함.
        let capturedFrom: Date?
        /// 끝 미포함.
        let capturedBefore: Date?
        /// 사람이 읽을 짧은 설명. 날짜 조건이 없으면 nil.
        let dateInterpretation: String?
    }

    private enum Phrase {
        case today, yesterday, thisWeek, lastWeek, thisMonth, lastMonth, thisYear, lastYear

        // 한국어 띄어쓰기가 일관되지 않아("이번 주"/"이번주") 자주 쓰이는 표기를 모두 받는다.
        var variants: [String] {
            switch self {
            case .today: ["오늘"]
            case .yesterday: ["어제"]
            case .thisWeek: ["이번 주", "이번주"]
            case .lastWeek: ["지난주", "지난 주"]
            case .thisMonth: ["이번 달", "이번달"]
            case .lastMonth: ["지난달", "지난 달"]
            case .thisYear: ["올해"]
            case .lastYear: ["작년"]
            }
        }

        var label: String {
            switch self {
            case .today: "오늘"
            case .yesterday: "어제"
            case .thisWeek: "이번 주"
            case .lastWeek: "지난주"
            case .thisMonth: "이번 달"
            case .lastMonth: "지난달"
            case .thisYear: "올해"
            case .lastYear: "작년"
            }
        }

        static let all: [Phrase] = [.today, .yesterday, .thisWeek, .lastWeek, .thisMonth, .lastMonth, .thisYear, .lastYear]
    }

    static func interpret(_ query: String, now: Date = Date(), calendar: Calendar = .current) -> Result {
        for phrase in Phrase.all {
            for variant in phrase.variants {
                guard let range = query.range(of: variant) else { continue }
                let remainder = query.replacingCharacters(in: range, with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                guard let interval = dateInterval(for: phrase, now: now, calendar: calendar) else {
                    continue
                }
                return Result(
                    searchText: remainder, capturedFrom: interval.start, capturedBefore: interval.end,
                    dateInterpretation: phrase.label
                )
            }
        }
        return Result(searchText: query, capturedFrom: nil, capturedBefore: nil, dateInterpretation: nil)
    }

    private static func dateInterval(for phrase: Phrase, now: Date, calendar: Calendar) -> DateInterval? {
        switch phrase {
        case .today:
            return calendar.dateInterval(of: .day, for: now)
        case .yesterday:
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else { return nil }
            return calendar.dateInterval(of: .day, for: yesterday)
        case .thisWeek:
            return calendar.dateInterval(of: .weekOfYear, for: now)
        case .lastWeek:
            guard let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: now) else { return nil }
            return calendar.dateInterval(of: .weekOfYear, for: lastWeek)
        case .thisMonth:
            return calendar.dateInterval(of: .month, for: now)
        case .lastMonth:
            guard let lastMonth = calendar.date(byAdding: .month, value: -1, to: now) else { return nil }
            return calendar.dateInterval(of: .month, for: lastMonth)
        case .thisYear:
            return calendar.dateInterval(of: .year, for: now)
        case .lastYear:
            guard let lastYear = calendar.date(byAdding: .year, value: -1, to: now) else { return nil }
            return calendar.dateInterval(of: .year, for: lastYear)
        }
    }
}
