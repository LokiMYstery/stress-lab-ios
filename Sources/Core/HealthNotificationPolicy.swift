import Foundation

struct HealthNotificationCandidate {
    var trend: HeartRateTrendEvaluation? = nil
    var sampleID: String
    var measuredAt: Date
    var score: Int
    var level: String
    var value: Double
    var provisional: Bool
    var requestID: String { "stresslab.\(trend == nil ? "hrv" : "trend").\(sampleID)" }
}

/// A persisted sample cursor distinguishes a new measurement from re-reading history.
struct HealthNotificationCursor: Codable {
    var primed = false
    var hrvIDs: Set<String> = []
    var observedHeartRateIDs: Set<String>?
    var trendIdentity: String?
    var lastTrendNotice: Date?
    var lastTrendDirection: HeartRateTrendDirection?
    var lastHRVNotice: Date?

    mutating func prime(_ dataset: HealthDataset) {
        primed = true
        hrvIDs = Set(dataset.heartbeats.map(\.id))
    }

    mutating func next(dataset: HealthDataset, sourceID: String, result: AnalysisResult,
                       now: Date) -> HealthNotificationCandidate? {
        let newHRV = Set(dataset.heartbeats.map(\.id)).subtracting(hrvIDs)
        let wasPrimed = primed
        prime(dataset)
        guard wasPrimed, !dataset.isDemo else { return nil }
        guard !result.current.reasons.contains("frequent_movement"),
              !result.current.reasons.contains("target_activity_excluded") else { return nil }
        // Coalesced syncs produce one notice for the newest usable measurement.
        if let point = result.hrv.last(where: {
            newHRV.contains($0.id) && $0.sourceID == sourceID && $0.baselineEligible &&
            $0.date <= now && $0.date >= now.addingTimeInterval(-3 * 3_600) && ($0.rmssd ?? 0) > 0
        }), let value = point.rmssd {
            return HealthNotificationCandidate(sampleID: point.id, measuredAt: point.date,
                score: point.assessment.score, level: point.assessment.level, value: value,
                provisional: point.assessment.origin != .personal)
        }
        return nil
    }

    mutating func nextTrend(dataset: HealthDataset, evaluation: HeartRateTrendEvaluation?,
                           parameters: HeartRateTrendParameters, identity: String, now: Date) -> HealthNotificationCandidate? {
        let ids = Set(dataset.quantities.filter { $0.kind == .heartRate }.map(\.id))
        let newIDs = ids.subtracting(observedHeartRateIDs ?? ids)
        let sameIdentity = trendIdentity == identity
        observedHeartRateIDs = ids
        if !sameIdentity { trendIdentity = identity; lastTrendDirection = nil; return nil }
        guard !dataset.isDemo, let evaluation else { return nil }
        if abs(evaluation.delta) < parameters.scoreThreshold / 2 { lastTrendDirection = nil }
        guard newIDs.contains(evaluation.sampleID), evaluation.measuredAt <= now,
              evaluation.measuredAt >= now.addingTimeInterval(-5 * 60), evaluation.sustained,
              abs(evaluation.delta) >= parameters.scoreThreshold,
              abs(evaluation.recentBPM - evaluation.previousBPM) >= 8,
              evaluation.direction != lastTrendDirection,
              lastTrendNotice.map({ now.timeIntervalSince($0) >= Double(parameters.cooldownMinutes) * 60 }) ?? true,
              lastHRVNotice.map({ now.timeIntervalSince($0) >= 15 * 60 }) ?? true else { return nil }
        return HealthNotificationCandidate(trend: evaluation, sampleID: evaluation.sampleID,
            measuredAt: evaluation.measuredAt, score: evaluation.recentScore,
            level: evaluation.direction == .rising ? "身体压力有所升高" : "身体压力有所缓解",
            value: evaluation.recentBPM, provisional: evaluation.provisional)
    }

    mutating func acknowledge(_ candidate: HealthNotificationCandidate, at now: Date) {
        if let trend = candidate.trend { lastTrendNotice = now; lastTrendDirection = trend.direction }
        else { lastHRVNotice = now }
    }

    mutating func retry(_ candidate: HealthNotificationCandidate) {
        if candidate.trend == nil { hrvIDs.remove(candidate.sampleID) }
        else { observedHeartRateIDs?.remove(candidate.sampleID) }
    }
}
