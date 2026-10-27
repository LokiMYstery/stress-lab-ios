import XCTest
@testable import StressLabCore

final class ModelsTests: XCTestCase {
    func testDefaultParametersAreValidAndRoundTripWithoutDrift() throws {
        let parameters = ExperimentParameters()
        XCTAssertNil(parameters.validationError)
        let data = try JSONEncoder().encode(parameters)
        XCTAssertEqual(try JSONDecoder().decode(ExperimentParameters.self, from: data), parameters)
    }

    func testPreviousSavedParametersDecodeWithNewColdStartDefaults() throws {
        let encoded = try JSONEncoder().encode(ExperimentParameters.legacyV0)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["defaultRMSSDMS", "defaultHeartRateBPM", "defaultHRVScale", "defaultHeartRateScale", "mappingVersion", "pressureSlope", "recoverySlope", "restingHRWeight", "restingHRScaleFloor", "hrvFilterEnabled", "redJumpThreshold", "redCooldownMinutes", "movementStepWindowMinutes", "movementStepThreshold", "useStepMovement"] {
            legacy.removeValue(forKey: key)
        }
        let saved = try JSONSerialization.data(withJSONObject: legacy)
        let decoded = try JSONDecoder().decode(ExperimentParameters.self, from: saved)
        XCTAssertEqual(decoded.defaultRMSSDMS, 50)
        XCTAssertEqual(decoded.defaultHeartRateBPM, 70)
        XCTAssertEqual(decoded.mappingVersion, 0)
        XCTAssertTrue(decoded.hrvFilterEnabled)
        XCTAssertEqual(decoded.hrScaleFloor, 3)
        XCTAssertEqual(decoded.restingHRWeight, 0.65)
        XCTAssertEqual(decoded.movementStepWindowMinutes, 10)
        XCTAssertEqual(decoded.movementStepThreshold, 8)
        XCTAssertTrue(decoded.useStepMovement)
        XCTAssertNil(decoded.validationError)
    }

    func testV1MappingReducesModerateRedScoresAndKeepsStrongAlerts() {
        let old = ExperimentParameters.legacyV0
        let current = ExperimentParameters.legacyV1
        XCTAssertEqual(old.mappedScore(for: 2), 90)
        XCTAssertEqual(current.mappedScore(for: 2), 66)
        XCTAssertEqual(current.mappedScore(for: 4), 82)
        XCTAssertEqual(current.mappedScore(for: -2), 20)
    }

    func testPreviousV1KeepsStrictRMSSDWhenNewFieldIsMissing() throws {
        let saved = try JSONEncoder().encode(ExperimentParameters.legacyV1)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        payload.removeValue(forKey: "hrvFilterEnabled")
        payload.removeValue(forKey: "redJumpThreshold")
        payload.removeValue(forKey: "redCooldownMinutes")
        let decoded = try JSONDecoder().decode(ExperimentParameters.self, from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertEqual(decoded.mappingVersion, 1)
        XCTAssertTrue(decoded.hrvFilterEnabled)
        XCTAssertFalse(ExperimentParameters().hrvFilterEnabled)
    }

    func testPreviousV2RetainsOriginalPointScoreMapping() throws {
        let saved = try JSONEncoder().encode(ExperimentParameters.legacyV2)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        payload.removeValue(forKey: "hrvScoreFloor")
        payload.removeValue(forKey: "hrvScoreMidpoint")
        payload.removeValue(forKey: "hrvScoreSteepness")
        let decoded = try JSONDecoder().decode(ExperimentParameters.self, from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertEqual(decoded.mappingVersion, 2)
        XCTAssertEqual(decoded.hrvCalibratedScore(for: 0.5), decoded.mappedScore(for: 0.5))
        XCTAssertEqual(ExperimentParameters().mappingVersion, 3)
    }

    func testExistingV3KeepsOldMovementPolicyOnUpgrade() throws {
        let data = try JSONEncoder().encode(ExperimentParameters.legacyV3)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        payload.removeValue(forKey: "movementStepWindowMinutes")
        payload.removeValue(forKey: "movementStepThreshold")
        payload.removeValue(forKey: "useStepMovement")
        let restored = try JSONDecoder().decode(ExperimentParameters.self, from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertEqual(restored.mappingVersion, 3)
        XCTAssertEqual(restored.movementStepWindowMinutes, 10)
        XCTAssertEqual(restored.movementStepThreshold, 8)
        XCTAssertTrue(restored.useStepMovement)
        XCTAssertFalse(ExperimentParameters().useStepMovement)
    }

    func testDailyReportCanRoundTripThroughPrivateDeviceCacheFormat() throws {
        let today = Date(timeIntervalSince1970: 1_790_035_200)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let result = AnalysisEngine.analyze(dataset: HealthDataset(), sourceID: "watch", parameters: ExperimentParameters(),
            version: "v2-test", day: today, now: today.addingTimeInterval(12 * 3_600), calendar: calendar)
        let decoded = try JSONDecoder().decode(AnalysisResult.self, from: JSONEncoder().encode(result))
        XCTAssertEqual(decoded.pressure.count, result.pressure.count)
        XCTAssertEqual(decoded.current.score, result.current.score)
    }

    func testRejectInvalidAndNonFiniteParameters() {
        var value = ExperimentParameters()
        value.slope = .nan
        XCTAssertNotNil(value.validationError)
        value = ExperimentParameters(); value.hrvLifetimeHours = .infinity
        XCTAssertNotNil(value.validationError)
        value = ExperimentParameters(); value.minimumDays = 31
        XCTAssertNotNil(value.validationError)
        value = ExperimentParameters(); value.hrScaleFloor = 0
        XCTAssertNotNil(value.validationError)
        value = ExperimentParameters(); value.minIntervalMS = value.maxIntervalMS
        XCTAssertNotNil(value.validationError)
    }

    func testSnapshotRoundTripPreservesProvenanceAndMotion() throws {
        let time = Date(timeIntervalSince1970: 1_000_000)
        let sample = QuantityRecord(id: "record", start: time, end: time, sourceID: "watch", kind: .heartRate, value: 71, motion: .unknown)
        let original = HealthDataset(sources: [DataSource(id: "watch", name: "Test Watch", isAppleWatch: true)], quantities: [sample], fetchedAt: time)
        let decoded = try JSONDecoder().decode(HealthDataset.self, from: JSONEncoder().encode(original))
        XCTAssertFalse(decoded.isDemo)
        XCTAssertEqual(decoded.quantities[0].motion, .unknown)
        XCTAssertEqual(decoded.quantities[0].sourceID, "watch")
        XCTAssertEqual(decoded.quantities[0].start, time)
        XCTAssertEqual(decoded.fetchedAt, time)
    }
}
