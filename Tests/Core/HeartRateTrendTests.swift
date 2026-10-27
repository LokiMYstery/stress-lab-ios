import XCTest
@testable import StressLabCore

final class HeartRateTrendTests: XCTestCase {
    let now = ISO8601DateFormatter().date(from: "2026-10-08T14:00:00Z")!
    let source = "watch"
    let parameters = ExperimentParameters()
    let trend = HeartRateTrendParameters()
    var baseline: BaselineSummary { BaselineSummary(median: 70, scale: 8, days: 7, samples: 100, ready: true) }
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value
    }
    func records(previous: Double = 70, recent: [Double] = [90, 90, 90]) -> [QuantityRecord] {
        zip([-74, -69, -64, -14, -9, -4], [previous, previous, previous] + recent).enumerated().map { index, pair in
            let date = now.addingTimeInterval(Double(pair.0) * 60)
            return QuantityRecord(id: "hr\(index)", start: date, end: date, sourceID: source,
                kind: .heartRate, value: pair.1, motion: .sedentary)
        }
    }
    func evaluate(_ values: [QuantityRecord]) -> HeartRateTrendEvaluation? {
        HeartRateTrendEvaluator.evaluate(records: values, baseline: baseline, parameters: parameters, trend: trend, now: now)
    }

    func testRisingAndEasingUseWindowMediansAndAgreeInLastTwoBins() throws {
        let rising = try XCTUnwrap(evaluate(records()))
        XCTAssertEqual(rising.delta, 20); XCTAssertEqual(rising.direction, .rising)
        XCTAssertTrue(rising.sustained); XCTAssertEqual(rising.recentBins, 3)
        let easing = try XCTUnwrap(evaluate(records(previous: 90, recent: [70, 70, 70])))
        XCTAssertEqual(easing.delta, -20); XCTAssertEqual(easing.direction, .easing)
        XCTAssertTrue(easing.sustained)
    }

    func testSingleSpikeSparseAndStaleInputsCannotQualify() throws {
        let spike = try XCTUnwrap(evaluate(records(recent: [70, 70, 110])))
        XCTAssertEqual(spike.delta, 0); XCTAssertFalse(spike.sustained)
        XCTAssertNil(evaluate(Array(records().dropLast())))
        let stale = records().map { record -> QuantityRecord in
            var record = record; record.start = record.start.addingTimeInterval(-10 * 60)
            record.end = record.end.addingTimeInterval(-10 * 60); return record
        }
        XCTAssertNil(evaluate(stale))
        var shortBaseline = baseline; shortBaseline.days = 2
        XCTAssertNil(HeartRateTrendEvaluator.evaluate(records: records(), baseline: shortBaseline, parameters: parameters, trend: trend, now: now))
    }

    func testTrendPersistsCooldownAndRequiresRearmForRepeatedDirection() throws {
        var cursor = HealthNotificationCursor()
        var dataset = HealthDataset()
        XCTAssertNil(cursor.nextTrend(dataset: dataset, evaluation: nil, parameters: trend, identity: "watch/v3", now: now))
        dataset.quantities = records()
        var evaluation = try XCTUnwrap(evaluate(dataset.quantities))
        let candidate = try XCTUnwrap(cursor.nextTrend(dataset: dataset, evaluation: evaluation, parameters: trend, identity: "watch/v3", now: now))
        cursor.acknowledge(candidate, at: now)
        cursor = try JSONDecoder().decode(HealthNotificationCursor.self, from: JSONEncoder().encode(cursor))
        let later = now.addingTimeInterval(61 * 60)
        evaluation.sampleID = "later"; evaluation.measuredAt = later
        dataset.quantities.append(QuantityRecord(id: "later", start: later, end: later, sourceID: source, kind: .heartRate, value: 90, motion: .sedentary))
        XCTAssertNil(cursor.nextTrend(dataset: dataset, evaluation: evaluation, parameters: trend, identity: "watch/v3", now: later))
        var neutral = evaluation; neutral.recentScore = neutral.previousScore
        XCTAssertNil(cursor.nextTrend(dataset: dataset, evaluation: neutral, parameters: trend, identity: "watch/v3", now: later))
        evaluation.sampleID = "rearmed"; evaluation.measuredAt = later.addingTimeInterval(60)
        dataset.quantities[dataset.quantities.count - 1].id = "rearmed"
        XCTAssertNotNil(cursor.nextTrend(dataset: dataset, evaluation: evaluation, parameters: trend, identity: "watch/v3", now: later.addingTimeInterval(60)))
    }

    func testNewHRVQuietPeriodAndIdentityChangeSuppressTrend() throws {
        var cursor = HealthNotificationCursor(); let empty = HealthDataset()
        _ = cursor.nextTrend(dataset: empty, evaluation: nil, parameters: trend, identity: "v3", now: now)
        cursor.lastHRVNotice = now
        let dataset = HealthDataset(quantities: records())
        let evaluation = try XCTUnwrap(evaluate(dataset.quantities))
        XCTAssertNil(cursor.nextTrend(dataset: dataset, evaluation: evaluation, parameters: trend, identity: "v3", now: now))
        XCTAssertNil(cursor.nextTrend(dataset: dataset, evaluation: evaluation, parameters: trend, identity: "v4", now: now))
    }

    func testOppositeDirectionStillHonorsCooldownAndSmallBPMChangeDoesNotNotify() throws {
        var cursor = HealthNotificationCursor()
        _ = cursor.nextTrend(dataset: HealthDataset(), evaluation: nil, parameters: trend, identity: "v3", now: now)
        cursor.lastTrendNotice = now; cursor.lastTrendDirection = .rising
        var dataset = HealthDataset(quantities: records(previous: 90, recent: [70, 70, 70]))
        var evaluation = try XCTUnwrap(evaluate(dataset.quantities))
        let early = now.addingTimeInterval(10 * 60)
        evaluation.measuredAt = early
        XCTAssertNil(cursor.nextTrend(dataset: dataset, evaluation: evaluation, parameters: trend, identity: "v3", now: early))
        let later = now.addingTimeInterval(61 * 60)
        evaluation.sampleID = "opposite"; evaluation.measuredAt = later
        dataset.quantities[dataset.quantities.count - 1].id = "opposite"
        XCTAssertNotNil(cursor.nextTrend(dataset: dataset, evaluation: evaluation, parameters: trend, identity: "v3", now: later))
        evaluation.sampleID = "small"; evaluation.recentBPM = evaluation.previousBPM - 1
        dataset.quantities[dataset.quantities.count - 1].id = "small"
        XCTAssertNil(cursor.nextTrend(dataset: dataset, evaluation: evaluation, parameters: trend, identity: "v3", now: later))
    }

    func testRollingWindowsCrossMidnightWithoutFutureSampleLeakage() throws {
        let midnight = ISO8601DateFormatter().date(from: "2026-10-09T00:05:00Z")!
        let shifted = records().map { sample -> QuantityRecord in
            var sample = sample; let offset = sample.end.timeIntervalSince(now)
            sample.start = midnight.addingTimeInterval(offset); sample.end = sample.start; return sample
        }
        let clean = try XCTUnwrap(HeartRateTrendEvaluator.evaluate(records: shifted, baseline: baseline,
            parameters: parameters, trend: trend, now: midnight))
        let future = QuantityRecord(id: "future", start: midnight.addingTimeInterval(60), end: midnight.addingTimeInterval(60),
            sourceID: source, kind: .heartRate, value: 180, motion: .sedentary)
        let output = try XCTUnwrap(HeartRateTrendEvaluator.evaluate(records: shifted + [future], baseline: baseline,
            parameters: parameters, trend: trend, now: midnight))
        XCTAssertEqual(output.delta, clean.delta); XCTAssertEqual(output.measuredAt, clean.measuredAt)
    }

    func testEngineExcludesUnknownMotionSleepAndActivityAndIgnoresHRVAndRestingHR() throws {
        var dataset = HealthDataset(sources: [DataSource(id: source, name: "Watch", isAppleWatch: true)], quantities: records())
        for offset in [-3, -2, -1] {
            let date = now.addingTimeInterval(Double(offset) * 86_400)
            dataset.quantities.append(QuantityRecord(id: "base\(offset)", start: date, end: date, sourceID: source, kind: .heartRate, value: 70, motion: .sedentary))
        }
        func run(_ data: HealthDataset) -> HeartRateTrendEvaluation? {
            AnalysisEngine.heartRateTrend(dataset: data, sourceID: source, parameters: parameters, trend: trend, now: now, calendar: calendar)
        }
        let original = try XCTUnwrap(run(dataset))
        dataset.quantities.append(QuantityRecord(id: "rhr", start: now, end: now, sourceID: source, kind: .restingHeartRate, value: 100))
        dataset.heartbeats.append(HeartbeatRecord(id: "hrv", start: now.addingTimeInterval(-60), end: now, sourceID: source,
            beats: [Beat(offset: 0, precededByGap: false), Beat(offset: 0.8, precededByGap: false), Beat(offset: 1.7, precededByGap: false)]))
        XCTAssertEqual(run(dataset)?.delta, original.delta)
        var unknown = dataset; unknown.quantities = unknown.quantities.map { sample in var sample = sample; sample.motion = .unknown; return sample }
        XCTAssertNil(run(unknown))
        dataset.intervals = [ContextInterval(id: "sleep", start: now.addingTimeInterval(-70 * 60), end: now.addingTimeInterval(-50 * 60), sourceID: source, kind: .sleep)]
        XCTAssertNil(run(dataset))
        dataset.intervals = [ContextInterval(id: "workout", start: now.addingTimeInterval(-20 * 60), end: now.addingTimeInterval(-10 * 60), sourceID: source, kind: .workout)]
        XCTAssertNil(run(dataset))
    }
}
