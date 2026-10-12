import XCTest
@testable import CapPick

final class LocalDateInterpreterTests: XCTestCase {
    // 실제 기기 타임존과 무관하게 결정적으로 검증하려고 고정한다 — 서버가 하던 방식(timezone:
    // .current를 그대로 보냄)과 같은 이유로 한국 사용자 기준을 가정한다.
    private let seoul = TimeZone(identifier: "Asia/Seoul")!
    private lazy var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = seoul
        return cal
    }()

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = seoul
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    func testNoDatePhraseLeavesQueryUntouched() {
        let result = LocalDateInterpreter.interpret("면접 준비 자료", now: date("2026-09-25T10:00:00+09:00"), calendar: calendar)

        XCTAssertEqual(result.searchText, "면접 준비 자료")
        XCTAssertNil(result.capturedFrom)
        XCTAssertNil(result.capturedBefore)
        XCTAssertNil(result.dateInterpretation)
    }

    func testYesterdayExtractsPhraseAndComputesDayBoundaries() {
        // 2026-09-25 낮 — "어제"는 09-24 00:00 ~ 09-25 00:00(KST), 끝은 미포함.
        let now = date("2026-09-25T15:30:00+09:00")
        let result = LocalDateInterpreter.interpret("어제 캡처한 사진", now: now, calendar: calendar)

        XCTAssertEqual(result.searchText, "캡처한 사진")
        XCTAssertEqual(result.capturedFrom, date("2026-09-24T00:00:00+09:00"))
        XCTAssertEqual(result.capturedBefore, date("2026-09-25T00:00:00+09:00"))
        XCTAssertEqual(result.dateInterpretation, "어제")
    }

    // 자정에 가까운 시각(23:59)에도 "오늘"이 실제로 그날 자정~다음날 자정으로 계산되는지 —
    // Date()를 그대로 쓰면 자정 근처에서 하루가 밀리는 흔한 버그를 잡기 위한 경계 테스트.
    func testTodayNearMidnightStillResolvesToCorrectDay() {
        let now = date("2026-09-25T23:59:00+09:00")
        let result = LocalDateInterpreter.interpret("오늘 스크린샷", now: now, calendar: calendar)

        XCTAssertEqual(result.capturedFrom, date("2026-09-25T00:00:00+09:00"))
        XCTAssertEqual(result.capturedBefore, date("2026-09-26T00:00:00+09:00"))
    }

    // "지난달"이 연도 경계를 넘는 경우(1월 → 작년 12월) — 단순히 month - 1만 하면 틀리는 대표적 버그.
    func testLastMonthCrossesYearBoundaryCorrectly() {
        let now = date("2027-01-15T12:00:00+09:00")
        let result = LocalDateInterpreter.interpret("지난달 면접 자료", now: now, calendar: calendar)

        XCTAssertEqual(result.searchText, "면접 자료")
        XCTAssertEqual(result.capturedFrom, date("2026-12-01T00:00:00+09:00"))
        XCTAssertEqual(result.capturedBefore, date("2027-01-01T00:00:00+09:00"))
    }

    func testThisMonthAtMonthBoundary() {
        // 9월 마지막 날에도 "이번 달"은 여전히 9/1~10/1이어야 한다(월말이라고 다음 달로 새면 안 됨).
        let now = date("2026-09-30T23:00:00+09:00")
        let result = LocalDateInterpreter.interpret("이번 달 캡처", now: now, calendar: calendar)

        XCTAssertEqual(result.capturedFrom, date("2026-09-01T00:00:00+09:00"))
        XCTAssertEqual(result.capturedBefore, date("2026-10-01T00:00:00+09:00"))
    }

    // "작년"이 연도 경계 바로 다음 날(1/1)에도 정확히 작년 1/1~올해 1/1로 계산되는지.
    func testLastYearRightAfterNewYear() {
        let now = date("2027-01-01T00:30:00+09:00")
        let result = LocalDateInterpreter.interpret("작년 여행 사진", now: now, calendar: calendar)

        XCTAssertEqual(result.capturedFrom, date("2026-01-01T00:00:00+09:00"))
        XCTAssertEqual(result.capturedBefore, date("2027-01-01T00:00:00+09:00"))
    }

    // 주 경계가 달을 넘는 경우 — dateInterval(of: .weekOfYear)가 시스템 로캘의 첫 요일 기준으로
    // 올바르게 계산되는지만 확인한다(정확한 요일 규칙은 Calendar가 책임지는 영역이라 재구현하지 않음).
    func testLastWeekCrossesMonthBoundary() {
        let now = date("2026-10-03T12:00:00+09:00") // 10월 첫째 주 토요일 근방
        let result = LocalDateInterpreter.interpret("지난주 스크린샷", now: now, calendar: calendar)

        XCTAssertNotNil(result.capturedFrom)
        XCTAssertNotNil(result.capturedBefore)
        // 끝은 항상 시작보다 뒤여야 하고(미포함 구간), now는 그 구간 밖(지난주니까)이어야 한다.
        XCTAssertLessThan(result.capturedFrom!, result.capturedBefore!)
        XCTAssertFalse((result.capturedFrom!..<result.capturedBefore!).contains(now))
    }

    // 띄어쓰기가 일관되지 않은 흔한 입력들도 같은 결과를 내야 한다.
    func testSpacingVariantsResolveToSameInterpretation() {
        let now = date("2026-09-25T10:00:00+09:00")
        let spaced = LocalDateInterpreter.interpret("이번 주 캡처", now: now, calendar: calendar)
        let unspaced = LocalDateInterpreter.interpret("이번주 캡처", now: now, calendar: calendar)

        XCTAssertEqual(spaced.capturedFrom, unspaced.capturedFrom)
        XCTAssertEqual(spaced.capturedBefore, unspaced.capturedBefore)
    }

    func testDateIntervalIsAlwaysStartInclusiveEndExclusive() {
        let now = date("2026-09-25T10:00:00+09:00")
        let result = LocalDateInterpreter.interpret("올해 캡처", now: now, calendar: calendar)

        // 구간의 시작 시각 자체는 포함, 끝 시각 자체는 제외 — 흔한 off-by-one을 잡는다.
        let from = result.capturedFrom!
        let before = result.capturedBefore!
        XCTAssertTrue((from..<before).contains(from))
        XCTAssertFalse((from..<before).contains(before))
    }

    func testDatePhraseInsideAnotherExpressionIsNotADateCondition() {
        let now = date("2026-09-25T10:00:00+09:00")

        let fortune = LocalDateInterpreter.interpret("오늘의 운세", now: now, calendar: calendar)
        let trend = LocalDateInterpreter.interpret("올해의 컬러 트렌드", now: now, calendar: calendar)

        XCTAssertNil(fortune.capturedFrom)
        XCTAssertEqual(fortune.searchText, "오늘의 운세")
        XCTAssertNil(trend.capturedFrom)
        XCTAssertEqual(trend.searchText, "올해의 컬러 트렌드")
    }

    func testDatePhraseWithTimeParticleIsStillADateConditionAndParticleIsRemoved() {
        let now = date("2026-09-25T10:00:00+09:00")

        let result = LocalDateInterpreter.interpret("지난달에 본 면접 자료", now: now, calendar: calendar)

        XCTAssertNotNil(result.capturedFrom)
        XCTAssertEqual(result.searchText, "본 면접 자료")
    }
}
