import XCTest
@testable import StressLabCore

final class HealthNotificationPolicyTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_790_150_400)
    let source = "watch"

    private func data(_ ids: [String], age: TimeInterval = 60, demo: Bool = false) -> HealthDataset {
        HealthDataset(heartbeats: ids.map {
            HeartbeatRecord(id: $0, start: now.addingTimeInterval(-age - 60),
                end: now.addingTimeInterval(-age), sourceID: source, beats: [])
        }, isDemo: demo)
    }

    private func result(_ ids: [String], age: TimeInterval = 60, blocked: Bool = false) -> AnalysisResult {
        let baseline = BaselineSummary(median: log(50), scale: 0.25, days: 2, samples: 5, ready: false)
        let hrv = ids.map {
            HRVPoint(id: $0, date: now.addingTimeInterval(-age), start: now.addingTimeInterval(-age - 60),
                sourceID: source, rawRMSSD: 40, rmssd: 40, validDuration: 60, pairCount: 60,
                state: .awake, exclusionReasons: [], baselineEligible: true,
                assessment: HRVAssessment(score: 40, origin: .provisional, baseline: baseline))
        }
        let current = PressurePoint(date: now, score: blocked ? nil : 40, origin: .hrv, state: .awake,
            hrvDate: hrv.last?.date, rmssd: hrv.last?.rmssd, hrvWeight: 1,
            hrvBaseline: baseline, heartRateBaseline: baseline,
            reasons: blocked ? ["frequent_movement"] : [], algorithmVersion: "test")
        return AnalysisResult(hrv: hrv, pressure: [], current: current, sleep: [])
    }

    func testInitialHistoryIsPrimedWithoutNotificationThenNewMeasurementNotifiesOnce() throws {
        var cursor = HealthNotificationCursor()
        XCTAssertNil(cursor.next(dataset: data(["old"]), sourceID: source, result: result(["old"]), now: now))
        let candidate = try XCTUnwrap(cursor.next(dataset: data(["old", "new"]), sourceID: source,
            result: result(["old", "new"]), now: now))
        XCTAssertEqual(candidate.sampleID, "new")
        XCTAssertEqual(candidate.score, 40)
        XCTAssertTrue(candidate.provisional)
        let restored = try JSONDecoder().decode(HealthNotificationCursor.self, from: JSONEncoder().encode(cursor))
        cursor = restored
        XCTAssertNil(cursor.next(dataset: data(["old", "new"]), sourceID: source, result: result(["old", "new"]), now: now))
    }

    func testCoalescedMeasurementsProduceOnlyLatestNotification() {
        var cursor = HealthNotificationCursor(); cursor.prime(data([]))
        let candidate = cursor.next(dataset: data(["a", "b"]), sourceID: source,
            result: result(["a", "b"]), now: now)
        XCTAssertEqual(candidate?.sampleID, "b")
        XCTAssertNil(cursor.next(dataset: data(["a", "b"]), sourceID: source, result: result(["a", "b"]), now: now))
    }

    func testOldBackfillDemoExcludedAndMovingMeasurementsDoNotNotify() {
        for (age, demo, blocked) in [(4 * 3_600.0, false, false), (60.0, true, false), (60.0, false, true)] {
            var cursor = HealthNotificationCursor(); cursor.prime(data([]))
            XCTAssertNil(cursor.next(dataset: data(["new"], age: age, demo: demo), sourceID: source,
                result: result(["new"], age: age, blocked: blocked), now: now))
        }
        var cursor = HealthNotificationCursor(); cursor.prime(data([]))
        var excluded = result(["new"]); excluded.hrv[0].baselineEligible = false
        XCTAssertNil(cursor.next(dataset: data(["new"]), sourceID: source, result: excluded, now: now))
    }

    func testNotificationFailureCanRetrySameMeasurement() throws {
        var cursor = HealthNotificationCursor(); cursor.prime(data([]))
        let candidate = try XCTUnwrap(cursor.next(dataset: data(["new"]), sourceID: source, result: result(["new"]), now: now))
        cursor.retry(candidate)
        XCTAssertEqual(cursor.next(dataset: data(["new"]), sourceID: source, result: result(["new"]), now: now)?.requestID, candidate.requestID)
    }

    func testHeartRateOnlyUpdatesNeverNotifyEvenWhenScoreIsHighOrCooldownHasElapsed() {
        var dataset = data([])
        dataset.quantities = [QuantityRecord(id: "hr1", start: now, end: now, sourceID: source,
            kind: .heartRate, value: 70, motion: .sedentary)]
        var output = result([]); output.current.origin = .heartRate
        output.current.heartRateDate = now; output.current.heartRate = 70
        var cursor = HealthNotificationCursor(); cursor.prime(data([]))
        XCTAssertNil(cursor.next(dataset: dataset, sourceID: source, result: output, now: now))
        dataset.quantities[0].id = "hr2"
        output.current.score = 99
        XCTAssertNil(cursor.next(dataset: dataset, sourceID: source, result: output, now: now.addingTimeInterval(60)))
        dataset.quantities[0].id = "hr3"
        XCTAssertNil(cursor.next(dataset: dataset, sourceID: source, result: output, now: now.addingTimeInterval(10 * 60)))
        dataset.heartbeats = data(["new-hrv"]).heartbeats
        XCTAssertEqual(cursor.next(dataset: dataset, sourceID: source, result: result(["new-hrv"]), now: now)?.sampleID, "new-hrv")
    }

    func testLegacyCursorKeepsHRVDeduplicationAndIgnoresOldHeartRateSettings() throws {
        let payload = Data(#"{"primed":true,"hrvIDs":["old"],"heartRateIDs":["hr"],"lastHeartRateNotice":0,"includeHeartRate":true}"#.utf8)
        var cursor = try JSONDecoder().decode(HealthNotificationCursor.self, from: payload)
        XCTAssertNil(cursor.next(dataset: data(["old"]), sourceID: source, result: result(["old"]), now: now))
        XCTAssertEqual(cursor.next(dataset: data(["old", "new"]), sourceID: source, result: result(["old", "new"]), now: now)?.sampleID, "new")
    }

    func testNoDataAndOtherSourceCannotNotify() {
        var cursor = HealthNotificationCursor(); cursor.prime(data([]))
        XCTAssertNil(cursor.next(dataset: data([]), sourceID: source, result: result([]), now: now))
        XCTAssertNil(cursor.next(dataset: data(["new"]), sourceID: "other-watch", result: result(["new"]), now: now))
    }
}
