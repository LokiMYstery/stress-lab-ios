import XCTest
@testable import StressLabCore

final class MainSleepAssessmentTests: XCTestCase {
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!; return c }
    func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }
    func interval(_ id: String, _ start: Date, _ end: Date, kind: IntervalKind = .sleep, source: String = "watch") -> ContextInterval {
        .init(id: id, start: start, end: end, sourceID: source, kind: kind)
    }
    func candidate(minutes: Int = 480, source: String = "watch") -> MainSleepNotificationCandidate {
        let start = date(25, 23), end = start.addingTimeInterval(Double(minutes) * 60)
        return .init(key: MainSleepEpisodes.nightKey(start: start, calendar: calendar),
            start: start, end: end, sleepMinutes: minutes, sourceID: source)
    }
    func history(minutes: [Int], source: String = "watch") -> HealthDataset {
        .init(intervals: minutes.enumerated().map { index, value in
            let start = date(24 - index, 23)
            return interval("history-\(index)", start, start.addingTimeInterval(Double(value) * 60), source: source)
        })
    }
    func assess(_ candidate: MainSleepNotificationCandidate, _ dataset: HealthDataset) -> MainSleepAssessment {
        MainSleepAssessmentEngine.assess(candidate: candidate, dataset: dataset, now: date(26, 10), calendar: calendar)
    }
    func testDurationComparisonUsesFiveNightsMedianAndExactFortyFiveMinuteBoundary() {
        let data = history(minutes: [480, 480, 480, 480, 900])
        let shorter = assess(candidate(minutes: 435), data)
        XCTAssertEqual(shorter.medianSleepMinutes, 480)
        XCTAssertEqual(shorter.comparison, .shorter)
        XCTAssertEqual(shorter.assessmentText, "比平时短一些")
        XCTAssertEqual(shorter.title, "睡了7小时15分钟")
        XCTAssertEqual(shorter.body, "23:00–06:15，比平时短一些。今天温和起步，先做一件轻量的事。")
        XCTAssertEqual(assess(candidate(minutes: 436), data).comparison, .similar)
        XCTAssertEqual(assess(candidate(minutes: 524), data).comparison, .similar)
        XCTAssertEqual(assess(candidate(minutes: 525), data).comparison, .longer)
    }
    func testEvenMedianAndInsufficientHistoryFallbackDoNotInventQuality() {
        let even = assess(candidate(), history(minutes: [420, 420, 420, 480, 480, 480]))
        XCTAssertEqual(even.medianSleepMinutes, 450)
        let missing = assess(candidate(), history(minutes: [480, 480, 480, 480]))
        XCTAssertEqual(missing.comparison, .insufficientHistory)
        XCTAssertNil(missing.medianSleepMinutes)
        XCTAssertEqual(missing.assessmentText, "")
        XCTAssertEqual(missing.body, "23:00–07:00。先感受一下醒后的状态，慢慢开始今天。")
    }
    func testHistoryExcludesCurrentFutureOtherSourceAndOlderThanFourteenNights() {
        var data = history(minutes: [480, 480, 480, 480])
        data.intervals += history(minutes: [400, 400, 400, 400, 400], source: "other").intervals
        data.intervals += [interval("current", date(25, 23), date(26, 7)),
            interval("future", date(26, 23), date(27, 7)),
            interval("old", date(10, 23), date(11, 7))]
        let output = assess(candidate(), data)
        XCTAssertEqual(output.baselineNights, 4)
        XCTAssertEqual(output.comparison, .insufficientHistory)
    }
    func testHistoryIncludesFourteenthNightAndCountsOneEpisodePerNight() {
        var data = history(minutes: [480, 480, 480, 480])
        data.intervals.append(interval("boundary", date(11, 23), date(12, 7)))
        let ready = assess(candidate(), data)
        XCTAssertEqual(ready.baselineNights, 5)
        XCTAssertEqual(ready.comparison, .similar)
        // Two separated qualifying sleep episodes in one night do not inflate the baseline count.
        data = history(minutes: [480, 480, 480, 480])
        data.intervals += [interval("first", date(20, 19), date(21, 1)), interval("second", date(21, 3), date(21, 6))]
        let oneNight = assess(candidate(), data)
        XCTAssertEqual(oneNight.baselineNights, 5)
        XCTAssertEqual(oneNight.medianSleepMinutes, 480)
    }
    func testExplicitAwakeIntervalsAreClippedMergedAndContradictorySleepExcluded() {
        let target = candidate(minutes: 450)
        var data = history(minutes: [450, 450, 450, 450, 450])
        data.intervals += [interval("s1", target.start, date(26, 3)),
            interval("s2", date(26, 3, 30), target.end),
            interval("awake1", date(26, 2, 50), date(26, 3, 20), kind: .awake),
            interval("awake2", date(26, 3, 10), date(26, 3, 30), kind: .awake),
            interval("otherAwake", date(26, 4), date(26, 5), kind: .awake, source: "other")]
        let output = assess(target, data)
        XCTAssertEqual(output.observedAwakeMinutes, 30)
        XCTAssertEqual(output.assessmentText, "时长与平时接近，记录到中途清醒约30分钟")
        XCTAssertEqual(output.suggestion, "今天温和起步，先做一件轻量的事。")
    }
    func testGapsWithoutAwakeSamplesAreNotCalledAwakenings() {
        var data = history(minutes: [450, 450, 450, 450, 450])
        data.intervals += [interval("s1", date(25, 23), date(26, 3)), interval("s2", date(26, 3, 30), date(26, 7))]
        let output = assess(candidate(minutes: 450), data)
        XCTAssertEqual(output.observedAwakeMinutes, 0)
        XCTAssertEqual(output.assessmentText, "时长与平时接近")
        XCTAssertFalse(output.body.contains("连续"))
    }
    func testUnderTwentyMinutesAwakeDoesNotTriggerAssessmentAndUnknownSourceHasNoBaseline() {
        var data = history(minutes: [480, 480, 480, 480, 480])
        data.intervals.append(interval("awake", date(26, 3), date(26, 3, 19), kind: .awake))
        XCTAssertEqual(assess(candidate(), data).assessmentText, "时长与平时接近")
        let unknown = assess(candidate(source: "ambiguous::watch"), history(minutes: [480, 480, 480, 480, 480], source: "ambiguous::watch"))
        XCTAssertEqual(unknown.comparison, .insufficientHistory)
    }
    func testCopyUsesPassedTimeZoneAndAssessmentCanBePersisted() throws {
        let target = candidate()
        var utc = calendar; utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let result = MainSleepAssessmentEngine.assess(candidate: target, dataset: HealthDataset(), now: date(26, 10), calendar: utc)
        XCTAssertTrue(result.body.hasPrefix("15:00–23:00。"))
        let restored = try JSONDecoder().decode(MainSleepAssessment.self, from: JSONEncoder().encode(result))
        XCTAssertEqual(restored.body, result.body)
    }
    func testCandidateCarriesAssessmentButPreviouslyHandledNightDoesNotNotifyAgain() throws {
        var data = history(minutes: [480, 480, 480, 480, 480])
        var cursor = MainSleepNotificationCursor(); cursor.prime(dataset: data)
        data.intervals.append(interval("today", date(25, 23), date(26, 7)))
        let result = try XCTUnwrap(cursor.evaluate(dataset: data, now: date(26, 8), calendar: calendar))
        XCTAssertEqual(result.assessment?.comparison, .similar)
        cursor.acknowledge(result)
        cursor = try JSONDecoder().decode(MainSleepNotificationCursor.self, from: JSONEncoder().encode(cursor))
        XCTAssertNil(cursor.evaluate(dataset: data, now: date(26, 8), calendar: calendar))
    }
}
