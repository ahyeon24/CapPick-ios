import Foundation

/// 온디바이스 검색 전환 Phase 1. 검색어에 섞인 상대적 날짜 표현("지난달 면접 자료")을 로컬에서
/// 찾아 날짜 구간으로 바꾼다 — 서버 `GeminiSearchInterpretationClient`가 하던 일 중 날짜 해석
/// 부분만 먼저 온디바이스로 옮긴 것이다(Gemini 프롬프트가 하던 지시를 그대로 규칙으로 옮김:
/// "캡처가 저장된 시점"만 다루고 이미지 속에 적힌 다른 날짜와는 무관, 시작 포함·끝 미포함).
///
/// 2026-10-08부터 SearchService가 실제 검색에 쓴다(서버 `/v1/search/prepare`는 없어졌다).
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
                guard let range = standaloneRange(of: variant, in: query) else { continue }
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

    // 날짜 표현 뒤에 붙어도 여전히 "그 시점에"라는 뜻인 조사. "오늘의"·"올해의"처럼 다른 조사가
    // 붙으면 날짜 조건으로 보지 않는다.
    private static let trailingParticles = ["에는", "에", "엔"]

    /// 날짜 표현이 독립된 단어로 쓰였을 때만 찾는다(앞뒤가 문장 경계·공백이거나, 뒤에 "에" 계열
    /// 조사만 붙은 경우). 단순 포함으로 찾으면 "오늘의 운세"가 '오늘 찍은 캡처'로 걸러져 결과가
    /// 통째로 사라진다 — 2026-10-08 실제 모델 검색 테스트에서 발견. 돌려주는 범위에는 조사도 포함된다.
    private static func standaloneRange(of variant: String, in query: String) -> Range<String.Index>? {
        var searchStart = query.startIndex
        while let range = query.range(of: variant, range: searchStart..<query.endIndex) {
            let startsAtBoundary = range.lowerBound == query.startIndex
                || query[query.index(before: range.lowerBound)].isWhitespace
            if startsAtBoundary {
                let rest = query[range.upperBound...]
                if rest.isEmpty || rest.first!.isWhitespace {
                    return range
                }
                for particle in trailingParticles where rest.hasPrefix(particle) {
                    let afterParticle = rest.dropFirst(particle.count)
                    if afterParticle.isEmpty || afterParticle.first!.isWhitespace {
                        return range.lowerBound..<afterParticle.startIndex
                    }
                }
            }
            searchStart = range.upperBound
        }
        return nil
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
