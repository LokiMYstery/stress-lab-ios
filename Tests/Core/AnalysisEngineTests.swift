import XCTest
@testable import StressLabCore

final class AnalysisEngineTests: XCTestCase {
    private let source = "watch-a"

    func testV3PointScoresFollowPairedStressWatchReferencesWithinTenPoints() {
        let parameters = ExperimentParameters()
        let reliablePairs: [(Int, Int)] = [
            (1, 10), (13, 7), (37, 13), (54, 73),
            (1, 4), (1, 4), (45, 32), (88, 100),
            (12, 4), (9, 2), (62, 79), (69, 94)
        ]
        let errors = reliablePairs.map { previous, target -> Int in
            let normalized = previous >= 50 ? Double(previous - 50) / 8 : Double(previous - 50) / 15
            let predicted = parameters.hrvCalibratedScore(for: normalized) ?? -1
            return abs(predicted - target)
        }
        XCTAssertLessThanOrEqual(Double(errors.reduce(0, +)) / Double(errors.count), 6)
        XCTAssertLessThanOrEqual(errors.max() ?? 100, 10)
    }

    func testV3NewHRVPointMatchesFirstEligibleRealTimeBin() throws {
        var dataset = HealthDataset()
        dataset.heartbeats = [
            hrvRecord(id: "d1", start: "2026-09-08T08:00:00Z", rmssd: 100),
            hrvRecord(id: "d2", start: "2026-09-09T08:00:00Z", rmssd: 100),
            hrvRecord(id: "current", start: "2026-09-10T08:00:00Z", rmssd: 25)
        ]
        var parameters = ExperimentParameters()
        parameters.minimumDays = 2
        parameters.minimumHRVRecords = 2
        let output = analyze(dataset, parameters: parameters, day: date("2026-09-10T00:00:00Z"), now: date("2026-09-10T08:07:00Z"))
        let point = try XCTUnwrap(output.hrv.last)
        let firstBin = try XCTUnwrap(output.pressure.first { $0.date == date("2026-09-10T08:06:00Z") })
        XCTAssertEqual(firstBin.score, point.assessment.score)
        XCTAssertEqual(firstBin.hrvWeight, 1)
    }

    func testWatchActiveOnAnotherSourceSuppressesHRVAndRestingPressureThenResumes() throws {
        var dataset = HealthDataset(sources: [
            DataSource(id: source, name: "Primary Watch", isAppleWatch: true),
            DataSource(id: "watch-b", name: "Second Watch", isAppleWatch: true)
        ])
        dataset.heartbeats = [
            hrvRecord(id: "d1", start: "2026-09-08T08:00:00Z", rmssd: 80),
            hrvRecord(id: "d2", start: "2026-09-09T08:00:00Z", rmssd: 80),
            hrvRecord(id: "current", start: "2026-09-10T09:00:00Z", rmssd: 30)
        ]
        dataset.quantities = [
            QuantityRecord(id: "r1", start: date("2026-09-08T08:00:00Z"), end: date("2026-09-08T08:00:00Z"), sourceID: source, kind: .restingHeartRate, value: 60),
            QuantityRecord(id: "r2", start: date("2026-09-09T08:00:00Z"), end: date("2026-09-09T08:00:00Z"), sourceID: source, kind: .restingHeartRate, value: 60),
            QuantityRecord(id: "rNow", start: date("2026-09-10T08:00:00Z"), end: date("2026-09-10T08:00:00Z"), sourceID: source, kind: .restingHeartRate, value: 64),
            QuantityRecord(id: "watch-active", start: date("2026-09-10T09:04:00Z"), end: date("2026-09-10T09:04:00Z"), sourceID: "watch-b", kind: .heartRate, value: 95, motion: .active)
        ]
        var parameters = ExperimentParameters()
        parameters.minimumDays = 2
        parameters.minimumHRVRecords = 2
        let during = analyze(dataset, parameters: parameters, day: date("2026-09-10T00:00:00Z"), now: date("2026-09-10T09:06:00Z"))
        XCTAssertNil(during.current.score)
        XCTAssertTrue(during.current.reasons.contains("frequent_movement"))
        XCTAssertNil(during.pressure.first { $0.date == date("2026-09-10T09:06:00Z") }?.score)
        let after = analyze(dataset, parameters: parameters, day: date("2026-09-10T00:00:00Z"), now: date("2026-09-10T09:20:00Z"))
        XCTAssertNotNil(after.current.score)
        XCTAssertFalse(after.current.reasons.contains("frequent_movement"))
    }

    func testStepsAloneDoNotSuppressNewV3PressureButLegacyVersionKeepsRule() throws {
        var dataset = HealthDataset()
        dataset.heartbeats = [
            hrvRecord(id: "d1", start: "2026-09-08T09:00:00Z", rmssd: 80),
            hrvRecord(id: "d2", start: "2026-09-09T09:00:00Z", rmssd: 80),
            hrvRecord(id: "current", start: "2026-09-10T09:00:00Z", rmssd: 45)
        ]
        dataset.quantities = [QuantityRecord(id: "many-phone-steps", start: date("2026-09-10T09:04:00Z"),
            end: date("2026-09-10T09:05:00Z"), sourceID: "iphone", kind: .steps, value: 120)]
        let day = date("2026-09-10T00:00:00Z"), now = date("2026-09-10T09:06:00Z")
        let current = analyze(dataset, parameters: ExperimentParameters(), day: day, now: now)
        XCTAssertNotNil(current.current.score)
        XCTAssertFalse(current.current.reasons.contains("frequent_movement"))
        let old = analyze(dataset, parameters: .legacyV3, day: day, now: now)
        XCTAssertNil(old.current.score)
        XCTAssertTrue(old.current.reasons.contains("frequent_movement"))
    }

    func testPhoneActiveHeartRateDoesNotClaimWatchMovement() throws {
        var dataset = HealthDataset(sources: [
            DataSource(id: source, name: "Watch", isAppleWatch: true),
            DataSource(id: "iphone", name: "iPhone", isAppleWatch: false)
        ])
        dataset.heartbeats = [hrvRecord(id: "current", start: "2026-09-10T09:00:00Z", rmssd: 45)]
        dataset.quantities = [QuantityRecord(id: "phone-active", start: date("2026-09-10T09:04:00Z"),
            end: date("2026-09-10T09:04:00Z"), sourceID: "iphone", kind: .heartRate, value: 90, motion: .active)]
        let result = analyze(dataset, parameters: ExperimentParameters(), day: date("2026-09-10T00:00:00Z"), now: date("2026-09-10T09:06:00Z"))
        XCTAssertNotNil(result.current.score)
        XCTAssertFalse(result.current.reasons.contains("frequent_movement"))
    }

    func testFirstDayRMSSDPointHasExplicitDefaultReferenceLevel() throws {
        var dataset = HealthDataset()
        dataset.heartbeats = [hrvRecord(id: "first", start: "2026-09-10T08:00:00Z", rmssd: 20)]
        let result = analyze(dataset, parameters: easyParameters(), day: date("2026-09-10T00:00:00Z"), now: date("2026-09-10T08:15:00Z"))
        let point = try XCTUnwrap(result.hrv.first)
        XCTAssertEqual(point.assessment.origin, .default)
        XCTAssertEqual(point.assessment.level, "压力偏高")
        XCTAssertTrue(result.pressure.contains { $0.score != nil })
        XCTAssertTrue(result.current.reasons.contains("hrv_default_reference"))
    }

    func testV1ClassifiesModerateRMSSDDropAsNormalInsteadOfRed() throws {
        var dataset = HealthDataset()
        dataset.heartbeats = [
            hrvRecord(id: "d1", start: "2026-09-08T08:00:00Z", rmssd: 100),
            hrvRecord(id: "d2", start: "2026-09-09T08:00:00Z", rmssd: 100),
            hrvRecord(id: "current", start: "2026-09-10T08:00:00Z", rmssd: 75)
        ]
        var calibrated = ExperimentParameters.legacyV1
        calibrated.minimumDays = 2
        calibrated.minimumHRVRecords = 2
        calibrated.minimumDuration = 10
        calibrated.minimumPairs = 5
        let result = analyze(dataset, parameters: calibrated, day: date("2026-09-10T00:00:00Z"), now: date("2026-09-10T08:15:00Z"))
        XCTAssertEqual(result.hrv.last?.assessment.level, "状态一般")
        XCTAssertEqual(result.current.level, "一般")
        XCTAssertLessThan(result.current.score ?? 100, 61)
    }

    func testV1RestingHeartRateModeratesOrdinaryHeartRateSpikes() throws {
        var dataset = HealthDataset()
        dataset.quantities = [
            heartRate(id: "hr-d1", start: "2026-09-08T09:00:00Z", value: 60, motion: .sedentary),
            heartRate(id: "hr-d2", start: "2026-09-09T09:00:00Z", value: 60, motion: .sedentary),
            heartRate(id: "hr-now", start: "2026-09-10T09:00:00Z", value: 84, motion: .sedentary),
            QuantityRecord(id: "rhr-d1", start: date("2026-09-08T08:30:00Z"), end: date("2026-09-08T08:30:00Z"), sourceID: source, kind: .restingHeartRate, value: 60),
            QuantityRecord(id: "rhr-d2", start: date("2026-09-09T08:30:00Z"), end: date("2026-09-09T08:30:00Z"), sourceID: source, kind: .restingHeartRate, value: 60),
            QuantityRecord(id: "rhr-now", start: date("2026-09-10T08:30:00Z"), end: date("2026-09-10T08:30:00Z"), sourceID: source, kind: .restingHeartRate, value: 61)
        ]
        var parameters = ExperimentParameters()
        parameters.minimumDays = 2
        parameters.minimumHRBins = 2
        let day = date("2026-09-10T00:00:00Z")
        let now = date("2026-09-10T09:06:00Z")
        let withResting = analyze(dataset, parameters: parameters, day: day, now: now)
        let withoutResting = analyze(HealthDataset(quantities: dataset.quantities.filter { $0.kind != .restingHeartRate }), parameters: parameters, day: day, now: now)
        XCTAssertEqual(withResting.current.restingHeartRate, 61)
        XCTAssertTrue(withResting.current.reasons.contains("rhr_corrob"))
        XCTAssertLessThan(withResting.current.score ?? 100, withoutResting.current.score ?? 0)
        XCTAssertLessThan(withResting.current.score ?? 100, 61)

        var legacy = parameters
        legacy.mappingVersion = 0
        let v0 = analyze(dataset, parameters: legacy, day: day, now: now)
        XCTAssertNil(v0.current.restingHeartRate)
    }

    func testRMSSDDoesNotBridgeGaps() throws {
        var dataset = HealthDataset()
        dataset.heartbeats = [
            HeartbeatRecord(
                id: "h1",
                start: date("2026-09-10T09:00:00Z"),
                end: date("2026-09-10T09:00:06Z"),
                sourceID: source,
                beats: [
                    Beat(offset: 0.0, precededByGap: false),
                    Beat(offset: 1.0, precededByGap: false),
                    Beat(offset: 2.1, precededByGap: false),
                    Beat(offset: 3.1, precededByGap: true),
                    Beat(offset: 4.2, precededByGap: false)
                ]
            )
        ]

        var parameters = ExperimentParameters.legacyV0
        parameters.minimumDuration = 1
        parameters.minimumPairs = 1

        let result = analyze(dataset, parameters: parameters, day: date("2026-09-10T00:00:00Z"))
        XCTAssertEqual(result.hrv.first?.pairCount, 1)
        XCTAssertEqual(result.hrv.first?.rmssd ?? 0, 100, accuracy: 0.0001)
        XCTAssertTrue(result.hrv.first?.exclusionReasons.contains("rejected_intervals") == true)
    }

    func testFilteredRMSSDRejectsAbnormalIntervalsButRawIsKept() throws {
        var dataset = HealthDataset()
        dataset.heartbeats = [
            HeartbeatRecord(
                id: "h1",
                start: date("2026-09-10T09:00:00Z"),
                end: date("2026-09-10T09:00:04Z"),
                sourceID: source,
                beats: [
                    Beat(offset: 0.0, precededByGap: false),
                    Beat(offset: 1.0, precededByGap: false),
                    Beat(offset: 1.1, precededByGap: false),
                    Beat(offset: 2.1, precededByGap: false)
                ]
            )
        ]

        var parameters = ExperimentParameters.legacyV1
        parameters.minimumDuration = 1
        parameters.minimumPairs = 1

        let point = analyze(dataset, parameters: parameters, day: date("2026-09-10T00:00:00Z")).hrv[0]
        XCTAssertNotNil(point.rawRMSSD)
        XCTAssertNil(point.rmssd)
        XCTAssertTrue(point.exclusionReasons.contains("pairs_below_threshold"))
    }

    func testV2ShowsShortSeriesThatV1QualityGateRejects() throws {
        var dataset = HealthDataset()
        dataset.heartbeats = [HeartbeatRecord(id: "short", start: date("2026-09-10T09:00:00Z"),
            end: date("2026-09-10T09:00:04Z"), sourceID: source, beats: [
                Beat(offset: 0, precededByGap: false), Beat(offset: 1, precededByGap: false),
                Beat(offset: 2.1, precededByGap: false), Beat(offset: 3.1, precededByGap: false)
            ])]
        let day = date("2026-09-10T00:00:00Z")
        let now = date("2026-09-10T09:06:00Z")
        let strict = analyze(dataset, parameters: .legacyV1, day: day, now: now)
        let experimental = analyze(dataset, parameters: .legacyV2, day: day, now: now)
        XCTAssertNil(strict.hrv.first?.rmssd)
        XCTAssertNotNil(experimental.hrv.first?.rmssd)
        XCTAssertEqual(experimental.hrv.first?.pairCount, 2)
        XCTAssertTrue(experimental.hrv.first?.exclusionReasons.contains("quality_filter_disabled") == true)
    }

    func testV2MarksOnlySuddenHighScoreAndCapsSustainedHighAtOrange() throws {
        var dataset = HealthDataset()
        dataset.quantities = [
            heartRate(id: "previous-1", start: "2026-09-08T09:00:00Z", value: 60, motion: .sedentary),
            heartRate(id: "previous-2", start: "2026-09-09T09:00:00Z", value: 60, motion: .sedentary)
        ]
        for minute in stride(from: 30, through: 54, by: 6) {
            dataset.quantities.append(heartRate(id: "quiet-\(minute)", start: "2026-09-10T08:\(minute):00Z", value: 60, motion: .sedentary))
        }
        for minute in [0, 6, 12, 18] {
            dataset.quantities.append(heartRate(id: "high-\(minute)", start: String(format: "2026-09-10T09:%02d:00Z", minute), value: 110, motion: .sedentary))
        }
        var parameters = ExperimentParameters.legacyV2
        parameters.minimumDays = 2
        parameters.minimumHRBins = 2
        let output = analyze(dataset, parameters: parameters, day: date("2026-09-10T00:00:00Z"), now: date("2026-09-10T09:18:00Z"))
        let eventBins = output.pressure.filter { $0.reasons.contains("acute_rise_confirmed") }
        XCTAssertEqual(eventBins.count, 1)
        XCTAssertEqual(eventBins.first?.score, 100)
        XCTAssertTrue(output.pressure.contains { $0.reasons.contains("acute_red_suppressed") && $0.score == 80 })
    }

    func testCurrentDefaultsTo50ButHistoricalChartStaysBlankWhenNothingIsUsable() throws {
        let result = analyze(HealthDataset(), parameters: easyParameters(), day: date("2026-09-10T00:00:00Z"))

        XCTAssertEqual(result.current.score, 50)
        XCTAssertEqual(result.current.origin, .default)
        XCTAssertTrue(result.pressure.allSatisfy { $0.score == nil })
    }

    func testBaselineUsesOnlyPastCompleteDaysAndDailyEqualWeight() throws {
        var dataset = HealthDataset()
        dataset.heartbeats = [
            hrvRecord(id: "d1", start: "2026-09-08T08:00:00Z", rmssd: 100),
            hrvRecord(id: "d2", start: "2026-09-09T08:00:00Z", rmssd: 100),
            hrvRecord(id: "target", start: "2026-09-10T08:00:00Z", rmssd: 20)
        ]

        var parameters = easyParameters()
        parameters.minimumHRBins = 10_000
        let result = analyze(
            dataset,
            parameters: parameters,
            day: date("2026-09-10T00:00:00Z"),
            now: date("2026-09-10T08:06:00Z")
        )

        XCTAssertEqual(result.current.origin, .hrv)
        XCTAssertEqual(result.current.hrvBaseline.days, 2)
        XCTAssertEqual(result.current.hrvBaseline.samples, 2)
        XCTAssertEqual(result.current.hrvBaseline.median ?? 0, log(100), accuracy: 0.0001)
        XCTAssertGreaterThan(result.current.score ?? 0, 60)
    }

    func testAwakeAndSleepBaselinesAreIsolated() throws {
        var dataset = HealthDataset()
        dataset.intervals = [
            ContextInterval(id: "s1", start: date("2026-09-08T00:00:00Z"), end: date("2026-09-08T06:00:00Z"), sourceID: source, kind: .sleep),
            ContextInterval(id: "s2", start: date("2026-09-09T00:00:00Z"), end: date("2026-09-09T06:00:00Z"), sourceID: source, kind: .sleep),
            ContextInterval(id: "s3", start: date("2026-09-10T00:00:00Z"), end: date("2026-09-10T06:00:00Z"), sourceID: source, kind: .sleep)
        ]
        dataset.heartbeats = [
            hrvRecord(id: "sleep-1", start: "2026-09-08T01:00:00Z", rmssd: 50),
            hrvRecord(id: "sleep-2", start: "2026-09-09T01:00:00Z", rmssd: 50),
            hrvRecord(id: "awake-1", start: "2026-09-08T08:00:00Z", rmssd: 100),
            hrvRecord(id: "awake-2", start: "2026-09-09T08:00:00Z", rmssd: 100),
            hrvRecord(id: "current", start: "2026-09-10T01:00:00Z", rmssd: 25)
        ]

        var parameters = easyParameters()
        parameters.minimumHRBins = 10_000
        let result = analyze(
            dataset,
            parameters: parameters,
            day: date("2026-09-10T00:00:00Z"),
            now: date("2026-09-10T01:06:00Z")
        )

        XCTAssertEqual(result.current.state, .asleep)
        XCTAssertEqual(result.current.hrvBaseline.median ?? 0, log(50), accuracy: 0.0001)
    }

    func testUnknownAwakeMotionUsesExperimentalEstimateWithWarning() throws {
        var dataset = HealthDataset()
        dataset.quantities = [
            heartRate(id: "d1", start: "2026-09-08T09:00:00Z", value: 60, motion: .sedentary),
            heartRate(id: "d2", start: "2026-09-09T09:00:00Z", value: 60, motion: .sedentary),
            heartRate(id: "current", start: "2026-09-10T09:00:00Z", value: 90, motion: .unknown)
        ]

        var parameters = easyParameters()
        parameters.minimumHRVRecords = 10_000
        let result = analyze(
            dataset,
            parameters: parameters,
            day: date("2026-09-10T00:00:00Z"),
            now: date("2026-09-10T09:06:00Z")
        )

        XCTAssertEqual(result.current.origin, .heartRate)
        XCTAssertEqual(result.current.score, 100)
        XCTAssertTrue(result.current.reasons.contains("motion_unknown"))
    }

    func testKnownStillHeartRateWinsOverUnknownMotionInSameWindow() throws {
        var dataset = HealthDataset()
        dataset.quantities = [
            heartRate(id: "d1", start: "2026-09-08T09:00:00Z", value: 60, motion: .sedentary),
            heartRate(id: "d2", start: "2026-09-09T09:00:00Z", value: 60, motion: .sedentary),
            heartRate(id: "unknown", start: "2026-09-10T09:00:00Z", value: 95, motion: .unknown),
            heartRate(id: "still", start: "2026-09-10T09:01:00Z", value: 65, motion: .sedentary)
        ]
        let result = analyze(dataset, parameters: easyParameters(), day: date("2026-09-10T00:00:00Z"), now: date("2026-09-10T09:06:00Z"))
        XCTAssertEqual(result.current.heartRate, 65)
        XCTAssertFalse(result.current.reasons.contains("motion_unknown"))
    }

    func testHeartRateEstimateUsesSedentaryRecentSamples() throws {
        var dataset = HealthDataset()
        dataset.quantities = [
            heartRate(id: "d1", start: "2026-09-08T09:00:00Z", value: 60, motion: .sedentary),
            heartRate(id: "d2", start: "2026-09-09T09:00:00Z", value: 60, motion: .sedentary),
            heartRate(id: "current", start: "2026-09-10T09:00:00Z", value: 90, motion: .sedentary)
        ]

        var parameters = easyParameters()
        parameters.minimumHRVRecords = 10_000
        let result = analyze(
            dataset,
            parameters: parameters,
            day: date("2026-09-10T00:00:00Z"),
            now: date("2026-09-10T09:06:00Z")
        )

        XCTAssertEqual(result.current.origin, .heartRate)
        XCTAssertEqual(result.current.heartRateBaseline.median, 60)
        XCTAssertGreaterThan(result.current.score ?? 0, 60)
    }

    func testWorkoutRecoveryAndStepsExcludeHeartRate() throws {
        var dataset = HealthDataset()
        dataset.intervals = [
            ContextInterval(id: "w", start: date("2026-09-10T08:00:00Z"), end: date("2026-09-10T08:30:00Z"), sourceID: source, kind: .workout)
        ]
        dataset.quantities = [
            heartRate(id: "d1", start: "2026-09-08T09:00:00Z", value: 60, motion: .sedentary),
            heartRate(id: "d2", start: "2026-09-09T09:00:00Z", value: 60, motion: .sedentary),
            heartRate(id: "recovery", start: "2026-09-10T08:45:00Z", value: 90, motion: .sedentary),
            QuantityRecord(id: "steps", start: date("2026-09-10T09:10:00Z"), end: date("2026-09-10T09:11:00Z"), sourceID: "iphone", kind: .steps, value: 20, motion: .unknown),
            heartRate(id: "stepping", start: "2026-09-10T09:10:00Z", value: 92, motion: .sedentary)
        ]

        var parameters = easyParameters()
        parameters.minimumHRVRecords = 10_000
        let recoveryResult = analyze(dataset, parameters: parameters, day: date("2026-09-10T00:00:00Z"), now: date("2026-09-10T08:50:00Z"))
        let stepResult = analyze(dataset, parameters: parameters, day: date("2026-09-10T00:00:00Z"), now: date("2026-09-10T09:12:00Z"))

        XCTAssertEqual(recoveryResult.current.origin, .default)
        XCTAssertEqual(stepResult.current.origin, .default)
        XCTAssertNil(recoveryResult.current.score)
        XCTAssertNil(stepResult.current.score)
        XCTAssertTrue(stepResult.current.reasons.contains("frequent_movement"))
    }

    func testSourceIsolationPreventsMixedBaselines() throws {
        var dataset = HealthDataset()
        dataset.heartbeats = [
            hrvRecord(id: "other-1", start: "2026-09-08T08:00:00Z", sourceID: "watch-b", rmssd: 100),
            hrvRecord(id: "other-2", start: "2026-09-09T08:00:00Z", sourceID: "watch-b", rmssd: 100),
            hrvRecord(id: "other-current", start: "2026-09-10T08:00:00Z", sourceID: "watch-b", rmssd: 20)
        ]

        var parameters = easyParameters()
        parameters.minimumHRBins = 10_000
        let result = analyze(dataset, parameters: parameters, day: date("2026-09-10T00:00:00Z"), now: date("2026-09-10T08:06:00Z"))

        XCTAssertTrue(result.hrv.isEmpty)
        XCTAssertEqual(result.current.origin, .default)
    }

    func testHRVExpiresAtLifetimeEvenWhenNoHeartRateExists() throws {
        var dataset = HealthDataset()
        dataset.heartbeats = [
            hrvRecord(id: "d1", start: "2026-09-08T08:00:00Z", rmssd: 100),
            hrvRecord(id: "d2", start: "2026-09-09T08:00:00Z", rmssd: 100),
            hrvRecord(id: "current", start: "2026-09-10T08:00:00Z", rmssd: 20)
        ]

        var parameters = easyParameters()
        parameters.minimumHRBins = 10_000
        let result = analyze(dataset, parameters: parameters, day: date("2026-09-10T00:00:00Z"), now: date("2026-09-10T11:01:00Z"))

        XCTAssertEqual(result.current.origin, .default)
        XCTAssertEqual(result.current.score, 50)
    }

    func testDSTSpringForwardDayKeepsRealTimeSixMinuteGrid() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let day = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8))!

        let result = AnalysisEngine.analyze(
            dataset: HealthDataset(),
            sourceID: source,
            parameters: easyParameters(),
            version: "test",
            day: day,
            now: calendar.date(byAdding: .day, value: 1, to: day)!,
            calendar: calendar
        )

        XCTAssertEqual(result.pressure.count, 230)
    }

    func testHeartRateSampleEndingInFutureIsNotUsed() throws {
        var dataset = HealthDataset()
        dataset.quantities = [
            heartRate(id: "d1", start: "2026-09-08T09:00:00Z", value: 60, motion: .sedentary),
            heartRate(id: "d2", start: "2026-09-09T09:00:00Z", value: 60, motion: .sedentary),
            heartRate(id: "future-end", start: "2026-09-10T09:00:00Z", duration: 600, value: 95, motion: .sedentary)
        ]

        var parameters = easyParameters()
        parameters.minimumHRVRecords = 10_000
        let result = analyze(dataset, parameters: parameters, day: date("2026-09-10T00:00:00Z"), now: date("2026-09-10T09:05:00Z"))

        XCTAssertEqual(result.current.origin, .default)
        XCTAssertTrue(result.current.reasons.contains("no_fresh_stationary_hr"))
    }

    func testHeartRateBaselineCountsSixMinuteBinsNotRawSamples() throws {
        var dataset = HealthDataset()
        dataset.quantities = [
            heartRate(id: "d1-a", start: "2026-09-08T09:00:00Z", value: 60, motion: .sedentary),
            heartRate(id: "d1-b", start: "2026-09-08T09:01:00Z", value: 62, motion: .sedentary),
            heartRate(id: "d2-a", start: "2026-09-09T09:00:00Z", value: 60, motion: .sedentary),
            heartRate(id: "d2-b", start: "2026-09-09T09:01:00Z", value: 62, motion: .sedentary),
            heartRate(id: "current", start: "2026-09-10T09:00:00Z", value: 90, motion: .sedentary)
        ]

        var parameters = easyParameters()
        parameters.minimumHRVRecords = 10_000
        parameters.minimumHRBins = 3
        let result = analyze(dataset, parameters: parameters, day: date("2026-09-10T00:00:00Z"), now: date("2026-09-10T09:06:00Z"))

        XCTAssertEqual(result.current.heartRateBaseline.samples, 2)
        XCTAssertFalse(result.current.heartRateBaseline.ready)
        XCTAssertEqual(result.current.origin, .heartRate)
        XCTAssertTrue(result.current.reasons.contains("hr_baseline_provisional"))
    }

    func testActiveHeartRateDuringSleepIsExcluded() throws {
        var dataset = HealthDataset()
        dataset.intervals = [
            ContextInterval(id: "s1", start: date("2026-09-08T00:00:00Z"), end: date("2026-09-08T06:00:00Z"), sourceID: source, kind: .sleep),
            ContextInterval(id: "s2", start: date("2026-09-09T00:00:00Z"), end: date("2026-09-09T06:00:00Z"), sourceID: source, kind: .sleep),
            ContextInterval(id: "s3", start: date("2026-09-10T00:00:00Z"), end: date("2026-09-10T06:00:00Z"), sourceID: source, kind: .sleep)
        ]
        dataset.quantities = [
            heartRate(id: "d1", start: "2026-09-08T01:00:00Z", value: 55, motion: .unknown),
            heartRate(id: "d2", start: "2026-09-09T01:00:00Z", value: 55, motion: .unknown),
            heartRate(id: "current", start: "2026-09-10T01:00:00Z", value: 90, motion: .active)
        ]

        var parameters = easyParameters()
        parameters.minimumHRVRecords = 10_000
        let result = analyze(dataset, parameters: parameters, day: date("2026-09-10T00:00:00Z"), now: date("2026-09-10T01:06:00Z"))

        XCTAssertEqual(result.current.state, .asleep)
        XCTAssertEqual(result.current.origin, .default)
        XCTAssertTrue(result.current.reasons.contains("no_fresh_stationary_hr"))
    }

    func testWorkoutHRVIsVisibleButNotUsedForPressure() throws {
        var dataset = HealthDataset()
        dataset.intervals = [
            ContextInterval(id: "w", start: date("2026-09-10T08:00:00Z"), end: date("2026-09-10T08:30:00Z"), sourceID: source, kind: .workout)
        ]
        dataset.heartbeats = [
            hrvRecord(id: "d1", start: "2026-09-08T08:00:00Z", rmssd: 100),
            hrvRecord(id: "d2", start: "2026-09-09T08:00:00Z", rmssd: 100),
            hrvRecord(id: "workout", start: "2026-09-10T08:05:00Z", rmssd: 20)
        ]

        var parameters = easyParameters()
        parameters.minimumHRBins = 10_000
        let result = analyze(dataset, parameters: parameters, day: date("2026-09-10T00:00:00Z"), now: date("2026-09-10T08:10:00Z"))

        XCTAssertEqual(result.hrv.last?.rmssd ?? -1, 20, accuracy: 0.0001)
        XCTAssertEqual(result.hrv.last?.baselineEligible, false)
        XCTAssertEqual(result.current.origin, .default)
    }

    func testZeroRMSSDIsNotBaselineEligibleOrUsableForPressure() throws {
        var dataset = HealthDataset()
        dataset.heartbeats = [
            hrvRecord(id: "d1", start: "2026-09-08T08:00:00Z", rmssd: 100),
            hrvRecord(id: "d2", start: "2026-09-09T08:00:00Z", rmssd: 100),
            hrvRecord(id: "zero", start: "2026-09-10T08:00:00Z", rmssd: 0)
        ]

        var parameters = easyParameters()
        parameters.minimumHRBins = 10_000
        let result = analyze(dataset, parameters: parameters, day: date("2026-09-10T00:00:00Z"), now: date("2026-09-10T08:06:00Z"))

        XCTAssertEqual(result.hrv.last?.rmssd, 0)
        XCTAssertEqual(result.hrv.last?.baselineEligible, false)
        XCTAssertEqual(result.current.origin, .default)
    }

    func testAmbiguousSourceEstimatesWithExplicitSourceWarning() throws {
        let ambiguous = "ambiguous::watch"
        var dataset = HealthDataset()
        dataset.heartbeats = [
            hrvRecord(id: "d1", start: "2026-09-08T08:00:00Z", sourceID: ambiguous, rmssd: 100),
            hrvRecord(id: "d2", start: "2026-09-09T08:00:00Z", sourceID: ambiguous, rmssd: 100),
            hrvRecord(id: "current", start: "2026-09-10T08:00:00Z", sourceID: ambiguous, rmssd: 20)
        ]
        dataset.quantities = [
            heartRate(id: "d1", start: "2026-09-08T09:00:00Z", sourceID: ambiguous, value: 60, motion: .sedentary),
            heartRate(id: "d2", start: "2026-09-09T09:00:00Z", sourceID: ambiguous, value: 60, motion: .sedentary),
            heartRate(id: "current", start: "2026-09-10T09:00:00Z", sourceID: ambiguous, value: 90, motion: .sedentary)
        ]

        let result = AnalysisEngine.analyze(
            dataset: dataset,
            sourceID: ambiguous,
            parameters: easyParameters(),
            version: "test",
            day: date("2026-09-10T00:00:00Z"),
            now: date("2026-09-10T09:06:00Z"),
            calendar: utcCalendar()
        )

        XCTAssertEqual(result.hrv.count, 1)
        XCTAssertNotNil(result.hrv.first?.rmssd)
        XCTAssertEqual(result.hrv.first?.baselineEligible, true)
        XCTAssertEqual(result.current.score, 100)
        XCTAssertEqual(result.current.origin, .blended)
        XCTAssertTrue(result.current.reasons.contains("ambiguous_source"))
        XCTAssertTrue(result.pressure.contains { $0.score != nil })
        XCTAssertEqual(result.hrv.first?.assessment.origin, .provisional)
    }

    func testWorkoutAtTargetSuppressesPreviouslyFreshHRVAndHeartRate() throws {
        var dataset = HealthDataset()
        dataset.intervals = [
            ContextInterval(id: "w", start: date("2026-09-10T08:00:00Z"), end: date("2026-09-10T08:30:00Z"), sourceID: source, kind: .workout)
        ]
        dataset.heartbeats = [
            hrvRecord(id: "h1", start: "2026-09-08T07:30:00Z", rmssd: 100),
            hrvRecord(id: "h2", start: "2026-09-09T07:30:00Z", rmssd: 100),
            hrvRecord(id: "fresh-before-workout", start: "2026-09-10T07:50:00Z", rmssd: 20)
        ]
        dataset.quantities = [
            heartRate(id: "d1", start: "2026-09-08T07:30:00Z", value: 60, motion: .sedentary),
            heartRate(id: "d2", start: "2026-09-09T07:30:00Z", value: 60, motion: .sedentary),
            heartRate(id: "fresh-before-workout", start: "2026-09-10T07:55:00Z", value: 95, motion: .sedentary)
        ]

        let result = analyze(dataset, parameters: easyParameters(), day: date("2026-09-10T00:00:00Z"), now: date("2026-09-10T08:10:00Z"))

        XCTAssertEqual(result.current.origin, .default)
        XCTAssertNil(result.current.score)
        XCTAssertTrue(result.current.reasons.contains("target_activity_excluded"))
    }

    func testRMSSDUsesAcquisitionOrderAndDoesNotSortBackwardOffsets() throws {
        var dataset = HealthDataset()
        dataset.heartbeats = [
            HeartbeatRecord(
                id: "backward",
                start: date("2026-09-10T09:00:00Z"),
                end: date("2026-09-10T09:00:04Z"),
                sourceID: source,
                beats: [
                    Beat(offset: 0, precededByGap: false),
                    Beat(offset: 2, precededByGap: false),
                    Beat(offset: 1, precededByGap: false),
                    Beat(offset: 3, precededByGap: false)
                ]
            )
        ]

        var parameters = ExperimentParameters.legacyV1
        parameters.minimumDuration = 1
        parameters.minimumPairs = 1
        let point = analyze(dataset, parameters: parameters, day: date("2026-09-10T00:00:00Z")).hrv[0]

        XCTAssertNil(point.rmssd)
        XCTAssertEqual(point.pairCount, 0)
        XCTAssertTrue(point.exclusionReasons.contains("rejected_intervals"))
    }

    func testInstantSleepHeartRateUsesTimestampClassification() throws {
        var dataset = HealthDataset()
        dataset.intervals = [
            ContextInterval(id: "s1", start: date("2026-09-08T00:00:00Z"), end: date("2026-09-08T06:00:00Z"), sourceID: source, kind: .sleep),
            ContextInterval(id: "s2", start: date("2026-09-09T00:00:00Z"), end: date("2026-09-09T06:00:00Z"), sourceID: source, kind: .sleep),
            ContextInterval(id: "s3", start: date("2026-09-10T00:00:00Z"), end: date("2026-09-10T06:00:00Z"), sourceID: source, kind: .sleep)
        ]
        dataset.quantities = [
            heartRate(id: "d1", start: "2026-09-08T01:00:00Z", duration: 0, value: 55, motion: .unknown),
            heartRate(id: "d2", start: "2026-09-09T01:00:00Z", duration: 0, value: 55, motion: .unknown),
            heartRate(id: "current", start: "2026-09-10T01:00:00Z", duration: 0, value: 80, motion: .unknown)
        ]

        var parameters = easyParameters()
        parameters.minimumHRVRecords = 10_000
        let result = analyze(dataset, parameters: parameters, day: date("2026-09-10T00:00:00Z"), now: date("2026-09-10T01:00:00Z"))

        XCTAssertEqual(result.current.state, .asleep)
        XCTAssertEqual(result.current.origin, .heartRate)
        XCTAssertEqual(result.current.heartRateBaseline.samples, 2)
    }

    func testExplicitAwakeOverridesSleepForInstantSamples() throws {
        var dataset = HealthDataset()
        dataset.intervals = [
            ContextInterval(id: "sleep", start: date("2026-09-10T00:00:00Z"), end: date("2026-09-10T06:00:00Z"), sourceID: source, kind: .sleep),
            ContextInterval(id: "awake", start: date("2026-09-10T01:00:00Z"), end: date("2026-09-10T01:10:00Z"), sourceID: source, kind: .awake)
        ]
        dataset.quantities = [
            heartRate(id: "d1", start: "2026-09-08T09:00:00Z", value: 60, motion: .sedentary),
            heartRate(id: "d2", start: "2026-09-09T09:00:00Z", value: 60, motion: .sedentary),
            heartRate(id: "current", start: "2026-09-10T01:02:00Z", duration: 0, value: 80, motion: .unknown)
        ]

        var parameters = easyParameters()
        parameters.minimumHRVRecords = 10_000
        let result = analyze(dataset, parameters: parameters, day: date("2026-09-10T00:00:00Z"), now: date("2026-09-10T01:02:00Z"))

        XCTAssertEqual(result.current.state, .awake)
        XCTAssertEqual(result.current.origin, .heartRate)
        XCTAssertTrue(result.current.reasons.contains("motion_unknown"))
    }

    private func analyze(
        _ dataset: HealthDataset,
        parameters: ExperimentParameters,
        day: Date,
        now: Date? = nil
    ) -> AnalysisResult {
        let calendar = utcCalendar()
        return AnalysisEngine.analyze(
            dataset: dataset,
            sourceID: source,
            parameters: parameters,
            version: "test",
            day: day,
            now: now ?? calendar.date(byAdding: .day, value: 1, to: day)!,
            calendar: calendar
        )
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func easyParameters() -> ExperimentParameters {
        var parameters = ExperimentParameters.legacyV0
        parameters.baselineDays = 30
        parameters.minimumDuration = 10
        parameters.minimumPairs = 5
        parameters.minimumDays = 2
        parameters.minimumHRVRecords = 2
        parameters.minimumHRBins = 2
        parameters.hrvScaleFloor = 0.15
        parameters.hrScaleFloor = 3
        return parameters
    }

    private func hrvRecord(id: String, start: String, sourceID: String? = nil, rmssd: Double) -> HeartbeatRecord {
        let startDate = date(start)
        var beats: [Beat] = [Beat(offset: 0, precededByGap: false)]
        var offset = 0.0
        for index in 0..<40 {
            offset += index.isMultiple(of: 2) ? 1.0 : 1.0 + rmssd / 1_000
            beats.append(Beat(offset: offset, precededByGap: false))
        }
        return HeartbeatRecord(
            id: id,
            start: startDate,
            end: startDate.addingTimeInterval(offset),
            sourceID: sourceID ?? source,
            beats: beats
        )
    }

    private func heartRate(id: String, start: String, sourceID: String? = nil, duration: TimeInterval = 60, value: Double, motion: MotionContext) -> QuantityRecord {
        let startDate = date(start)
        return QuantityRecord(
            id: id,
            start: startDate,
            end: startDate.addingTimeInterval(duration),
            sourceID: sourceID ?? source,
            kind: .heartRate,
            value: value,
            motion: motion
        )
    }

    private func date(_ string: String) -> Date {
        ISO8601DateFormatter().date(from: string)!
    }

}
