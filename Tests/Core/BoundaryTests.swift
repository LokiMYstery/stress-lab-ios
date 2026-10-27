import XCTest
@testable import StressLabCore

final class BoundaryTests: XCTestCase {
    func testRawRMSSDAlsoBreaksAtBackwardBeat() throws {
        let start = Date(timeIntervalSince1970: 1000)
        let record = HeartbeatRecord(id: "bad-order", start: start, end: start.addingTimeInterval(4), sourceID: "watch", beats: [0.0, 1, 1.2, 1.1, 2.1, 3.3].map { Beat(offset: $0, precededByGap: false) })
        let output = AnalysisEngine.rmssd(record: record, parameters: ExperimentParameters())
        XCTAssertEqual(try XCTUnwrap(output.raw), sqrt(0.34) * 1000, accuracy: 0.001)
    }
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private var parameters: ExperimentParameters {
        var value = ExperimentParameters()
        value.minimumDays = 1; value.minimumHRBins = 1
        return value
    }
    func testMidnightSpanningSampleDoesNotLeakIntoPreviousDayBaseline() {
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_790_035_200))
        let past = QuantityRecord(id: "past", start: day.addingTimeInterval(-3600), end: day.addingTimeInterval(-3600), sourceID: "watch", kind: .heartRate, value: 70, motion: .sedentary)
        let spanning = QuantityRecord(id: "spanning", start: day.addingTimeInterval(-60), end: day.addingTimeInterval(60), sourceID: "watch", kind: .heartRate, value: 120, motion: .sedentary)
        let result = AnalysisEngine.analyze(dataset: HealthDataset(quantities: [past, spanning]), sourceID: "watch", parameters: parameters, version: "test", day: day, now: day.addingTimeInterval(120), calendar: calendar)
        XCTAssertEqual(result.current.heartRateBaseline.samples, 1)
        XCTAssertEqual(result.current.heartRateBaseline.median, 70)
    }
    func testExtremeFiniteHeartRateClampsBeforeIntegerConversion() {
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_790_035_200))
        let past = day.addingTimeInterval(-3600), now = day.addingTimeInterval(60)
        let data = HealthDataset(quantities: [
            QuantityRecord(id: "past", start: past, end: past, sourceID: "watch", kind: .heartRate, value: 70, motion: .sedentary),
            QuantityRecord(id: "extreme", start: now, end: now, sourceID: "watch", kind: .heartRate, value: 1e100, motion: .sedentary)
        ])
        let result = AnalysisEngine.analyze(dataset: data, sourceID: "watch", parameters: parameters, version: "test", day: day, now: now, calendar: calendar)
        XCTAssertEqual(parameters.mappedScore(for: 1e100), 100)
        XCTAssertEqual(result.current.score, 80)
        XCTAssertTrue(result.current.reasons.contains("acute_red_suppressed"))
    }
}
