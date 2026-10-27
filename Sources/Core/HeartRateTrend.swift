import Foundation

struct HeartRateTrendParameters: Codable, Equatable {
    var windowMinutes: Int = 15
    var comparisonMinutes: Int = 60
    var scoreThreshold: Int = 15
    var cooldownMinutes: Int = 60
    var valid: Bool {
        (15...30).contains(windowMinutes) && (45...120).contains(comparisonMinutes) &&
        comparisonMinutes > windowMinutes && (10...30).contains(scoreThreshold) && (30...120).contains(cooldownMinutes)
    }
}

enum HeartRateTrendDirection: String, Codable { case rising, easing }

struct HeartRateTrendEvaluation {
    var sampleID: String
    var measuredAt: Date
    var recentScore: Int
    var previousScore: Int
    var recentBPM: Double
    var previousBPM: Double
    var recentBins: Int
    var previousBins: Int
    var provisional: Bool
    var sustained: Bool
    var delta: Int { recentScore - previousScore }
    var direction: HeartRateTrendDirection { delta >= 0 ? .rising : .easing }
}

enum HeartRateTrendEvaluator {
    static func evaluate(records: [QuantityRecord], baseline: BaselineSummary,
                         parameters: ExperimentParameters, trend: HeartRateTrendParameters,
                         now: Date) -> HeartRateTrendEvaluation? {
        guard trend.valid, baseline.days >= 3, let median = baseline.median, let scale = baseline.scale else { return nil }
        let recentStart = now.addingTimeInterval(-Double(trend.windowMinutes) * 60)
        let previousEnd = now.addingTimeInterval(-Double(trend.comparisonMinutes) * 60)
        let previousStart = previousEnd.addingTimeInterval(-Double(trend.windowMinutes) * 60)
        let recent = records.filter { $0.end > recentStart && $0.end <= now }
        let previous = records.filter { $0.end > previousStart && $0.end <= previousEnd }
        func bins(_ samples: [QuantityRecord]) -> [(time: Double, bpm: Double, score: Int)] {
            let grouped = Dictionary(grouping: samples) { floor($0.end.timeIntervalSince1970 / 300) }
            return grouped.compactMap { time, samples in
                guard let bpm = samples.map(\.value).median(),
                      let score = parameters.mappedScore(for: (bpm - median) / max(scale, parameters.hrScaleFloor)) else { return nil }
                return (time, bpm, score)
            }.sorted { $0.time < $1.time }
        }
        let recentBins = bins(recent), previousBins = bins(previous)
        guard recentBins.count >= 3, previousBins.count >= 3,
              let latest = recent.max(by: { $0.end < $1.end }), latest.end >= now.addingTimeInterval(-5 * 60),
              let firstRecent = recent.map(\.end).min(), latest.end.timeIntervalSince(firstRecent) >= 8 * 60,
              let firstPrevious = previous.map(\.end).min(), let lastPrevious = previous.map(\.end).max(),
              lastPrevious.timeIntervalSince(firstPrevious) >= 8 * 60,
              let recentScore = recentBins.map({ Double($0.score) }).median(),
              let previousScore = previousBins.map({ Double($0.score) }).median(),
              let recentBPM = recentBins.map(\.bpm).median(), let previousBPM = previousBins.map(\.bpm).median() else { return nil }
        let delta = recentScore - previousScore
        let sustained = recentBins.suffix(2).allSatisfy {
            delta >= 0 ? Double($0.score) - previousScore >= Double(trend.scoreThreshold)
                       : previousScore - Double($0.score) >= Double(trend.scoreThreshold)
        }
        return HeartRateTrendEvaluation(sampleID: latest.id, measuredAt: latest.end,
            recentScore: Int(recentScore.rounded()), previousScore: Int(previousScore.rounded()),
            recentBPM: recentBPM, previousBPM: previousBPM, recentBins: recentBins.count,
            previousBins: previousBins.count, provisional: !baseline.ready, sustained: sustained)
    }
}
