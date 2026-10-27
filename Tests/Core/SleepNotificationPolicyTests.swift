import XCTest
@testable import StressLabCore

final class SleepNotificationPolicyTests: XCTestCase {
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!; return c }
    func date(_ hour: Int, _ minute: Int = 0, day: Int = 26) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }
    func sleep(_ id: String, _ start: Date, _ end: Date, source: String = "watch") -> ContextInterval {
        .init(id: id, start: start, end: end, sourceID: source, kind: .sleep)
    }
    func night() -> HealthDataset {
        HealthDataset(intervals: [sleep("night", date(23, day: 25), date(7))])
    }
    func testQuietHoursUseLocalClockAndExactBoundaries() {
        XCTAssertFalse(NotificationQuietHours.isQuiet(at: date(22, 59), calendar: calendar))
        XCTAssertFalse(NotificationQuietHours.isQuiet(at: date(22, 30), calendar: calendar))
        XCTAssertTrue(NotificationQuietHours.isQuiet(at: date(23), calendar: calendar))
        XCTAssertTrue(NotificationQuietHours.isQuiet(at: date(6, 59), calendar: calendar))
        XCTAssertFalse(NotificationQuietHours.isQuiet(at: date(7), calendar: calendar))
        var utc = calendar; utc.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertFalse(NotificationQuietHours.isQuiet(at: date(23), calendar: utc))
    }
    func testFirstReadPrimesHistoryAndDoesNotNotify() {
        var cursor = MainSleepNotificationCursor()
        XCTAssertNil(cursor.evaluate(dataset: night(), now: date(8), calendar: calendar))
        XCTAssertNil(cursor.evaluate(dataset: night(), now: date(8), calendar: calendar))
    }
    func testDeferredCandidateThenSuccessfulSubmissionDeduplicatesAcrossRestartAndRevision() throws {
        var cursor = MainSleepNotificationCursor(); cursor.prime(dataset: HealthDataset())
        XCTAssertNil(cursor.evaluate(dataset: night(), now: date(7, 10), calendar: calendar))
        let candidate = try XCTUnwrap(cursor.evaluate(dataset: night(), now: date(7, 30), calendar: calendar))
        XCTAssertEqual(candidate.sleepMinutes, 480)
        XCTAssertEqual(candidate.durationText, "8 小时 0 分钟")
        // Not acknowledged: failed submissions remain retryable.
        XCTAssertNotNil(cursor.evaluate(dataset: night(), now: date(7, 31), calendar: calendar))
        cursor.acknowledge(candidate)
        cursor = try JSONDecoder().decode(MainSleepNotificationCursor.self, from: JSONEncoder().encode(cursor))
        var revised = night(); revised.intervals[0].id = "revised"; revised.intervals[0].end = date(7, 5)
        XCTAssertNil(cursor.evaluate(dataset: revised, now: date(8), calendar: calendar))
    }
    func testOverlapDoesNotDoubleCountAndBriefAwakeGapIsNotSleepDuration() throws {
        var cursor = MainSleepNotificationCursor(); cursor.prime(dataset: HealthDataset())
        let data = HealthDataset(intervals: [
            sleep("a", date(0), date(3)), sleep("b", date(1), date(2)),
            sleep("c", date(3, 30), date(7))])
        let candidate = try XCTUnwrap(cursor.evaluate(dataset: data, now: date(8), calendar: calendar))
        XCTAssertEqual(candidate.sleepMinutes, 390)
    }
    func testQuietCandidateCanBeRecheckedAfterSevenButExpiredBackfillDoesNotSend() {
        var cursor = MainSleepNotificationCursor(); cursor.prime(dataset: HealthDataset())
        let data = HealthDataset(intervals: [sleep("a", date(0), date(6))])
        XCTAssertNil(cursor.evaluate(dataset: data, now: date(6, 45), calendar: calendar))
        XCTAssertNotNil(cursor.evaluate(dataset: data, now: date(7), calendar: calendar))
        var old = MainSleepNotificationCursor(); old.prime(dataset: HealthDataset())
        XCTAssertNil(old.evaluate(dataset: data, now: date(9), calendar: calendar))
    }
    func testNapShortSleepDemoAndMalformedRecordsAreRejected() {
        let cases = [
            HealthDataset(intervals: [sleep("nap", date(12), date(15))]),
            HealthDataset(intervals: [sleep("short", date(5), date(7))]),
            HealthDataset(intervals: [sleep("future", date(0), date(10))]),
            HealthDataset(intervals: [sleep("bad", date(7), date(0))])]
        for data in cases {
            var cursor = MainSleepNotificationCursor(); cursor.prime(dataset: HealthDataset())
            XCTAssertNil(cursor.evaluate(dataset: data, now: date(8), calendar: calendar))
        }
        var demo = night(); demo.isDemo = true
        var cursor = MainSleepNotificationCursor(); cursor.prime(dataset: HealthDataset())
        XCTAssertNil(cursor.evaluate(dataset: demo, now: date(8), calendar: calendar))
    }
    func testLaterSleepPreventsPrematureReminderAndSourcesAreNotAddedTogether() {
        var data = night(); data.intervals.append(sleep("ongoing", date(7, 40), date(9)))
        var cursor = MainSleepNotificationCursor(); cursor.prime(dataset: HealthDataset())
        XCTAssertNil(cursor.evaluate(dataset: data, now: date(8), calendar: calendar))
        let twoSources = HealthDataset(intervals: [sleep("a", date(0), date(2), source: "a"), sleep("b", date(2), date(4), source: "b")])
        var second = MainSleepNotificationCursor(); second.prime(dataset: HealthDataset())
        XCTAssertNil(second.evaluate(dataset: twoSources, now: date(5), calendar: calendar))
    }
}
