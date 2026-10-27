import XCTest
@testable import StressLabCore

final class PerformanceTests: XCTestCase {
    func testThirtySevenDaysReplayProducesScoresPromptlyAndDeterministically() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = Date(timeIntervalSince1970: 1_790_035_200)
        let day = calendar.startOfDay(for: today)
        let now = day.addingTimeInterval(20 * 3600)
        var data = HealthDataset()
        for offset in -36...0 {
            let base = calendar.date(byAdding: .day, value: offset, to: day)!
            data.intervals.append(ContextInterval(id: "sleep\(offset)", start: base, end: base.addingTimeInterval(7 * 3600), sourceID: "watch", kind: .sleep))
            for minute in stride(from: 0, to: 1440, by: 6) {
                let time = base.addingTimeInterval(Double(minute * 60))
                guard time <= now else { continue }
                data.quantities.append(QuantityRecord(id: "hr\(offset)-\(minute)", start: time, end: time, sourceID: "watch", kind: .heartRate, value: 65 + Double((minute + offset) % 9), motion: .sedentary))
                if minute.isMultiple(of: 60) {
                    data.quantities.append(QuantityRecord(id: "steps\(offset)-\(minute)", start: time, end: time.addingTimeInterval(60), sourceID: "watch", kind: .steps, value: 5))
                }
            }
        }
        let start = Date()
        let first = AnalysisEngine.analyze(dataset: data, sourceID: "watch", parameters: ExperimentParameters(), version: "perf", day: day, now: now, calendar: calendar)
        let elapsed = Date().timeIntervalSince(start)
        print("37-day replay: \(data.quantities.count) quantity records, \(elapsed) seconds")
        XCTAssertLessThan(elapsed, 10, "Regression guard against per-bar full-history nested scanning")
        XCTAssertTrue(first.pressure.contains { $0.score != nil })
        XCTAssertEqual(first.current.origin, .heartRate)
        let second = AnalysisEngine.analyze(dataset: data, sourceID: "watch", parameters: ExperimentParameters(), version: "perf", day: day, now: now, calendar: calendar)
        XCTAssertEqual(first.pressure.map(\.score), second.pressure.map(\.score))
        XCTAssertEqual(first.current.score, second.current.score)
    }
}
