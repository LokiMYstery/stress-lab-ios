import Foundation

/// One source's merged nighttime episode. Missing intervals are never assumed asleep/awake.
struct MainSleepEpisode {
    var key: String
    var start: Date
    var end: Date
    var sleepMinutes: Int
    var sourceID: String
    var records: [ContextInterval]
}

enum MainSleepEpisodes {
    static func nightKey(start: Date, calendar: Calendar) -> String {
        let shifted = calendar.date(byAdding: .hour, value: -18, to: start)!
        return "\(calendar.startOfDay(for: shifted).timeIntervalSince1970)"
    }

    static func collect(dataset: HealthDataset, now: Date, calendar: Calendar,
                        since: Date) -> [MainSleepEpisode] {
        let records = dataset.intervals.filter {
            $0.kind == .sleep && $0.start < $0.end && $0.end <= now && $0.start >= since
        }
        var episodes: [MainSleepEpisode] = []
        for (source, intervals) in Dictionary(grouping: records, by: \.sourceID) {
            let sorted = intervals.sorted { $0.start < $1.start }
            var groups: [[ContextInterval]] = []
            for interval in sorted {
                if let last = groups.last, let end = last.map(\.end).max(), interval.start.timeIntervalSince(end) <= 90 * 60 {
                    groups[groups.count - 1].append(interval)
                } else { groups.append([interval]) }
            }
            for group in groups {
                let start = group[0].start, end = group.map(\.end).max()!
                var unionEnd = start, seconds: TimeInterval = 0
                var nighttime = false
                for interval in group {
                    seconds += max(0, interval.end.timeIntervalSince(max(unionEnd, interval.start)))
                    unionEnd = max(unionEnd, interval.end)
                    var day = calendar.startOfDay(for: interval.start)
                    while day < interval.end {
                        let six = calendar.date(byAdding: .hour, value: 6, to: day)!
                        if interval.start < six && interval.end > day { nighttime = true }
                        day = calendar.date(byAdding: .day, value: 1, to: day)!
                    }
                }
                guard seconds >= 3 * 3600, end.timeIntervalSince(start) <= 18 * 3600, nighttime else { continue }
                episodes.append(.init(key: nightKey(start: start, calendar: calendar), start: start,
                    end: end, sleepMinutes: Int(seconds / 60), sourceID: source, records: group))
            }
        }
        return episodes
    }
}

struct MainSleepAssessment: Codable {
    static let version = "sleep-summary-v1"
    enum DurationComparison: String, Codable { case shorter, similar, longer, insufficientHistory }
    var comparison: DurationComparison
    var baselineNights: Int
    var medianSleepMinutes: Double?
    var observedAwakeMinutes: Int
    var assessmentText: String
    var suggestion: String
    var title: String
    var body: String
}

enum MainSleepAssessmentEngine {
    static func assess(candidate: MainSleepNotificationCandidate, dataset: HealthDataset,
                       now: Date, calendar: Calendar) -> MainSleepAssessment {
        let shiftedStart = calendar.date(byAdding: .hour, value: -18, to: candidate.start)!
        let nightDay = calendar.startOfDay(for: shiftedStart)
        let firstDay = calendar.date(byAdding: .day, value: -14, to: nightDay)!
        let scanStart = calendar.date(byAdding: .hour, value: 18, to: firstDay)!
        let episodes = MainSleepEpisodes.collect(dataset: dataset, now: now, calendar: calendar, since: scanStart)
        let previous = episodes.filter {
            $0.sourceID == candidate.sourceID && $0.end <= candidate.start &&
            $0.key != candidate.key && Double($0.key)! < nightDay.timeIntervalSince1970
        }
        // Only one main episode per prior sleep day, never count duplicate sources or split nights twice.
        let nights = Dictionary(grouping: previous, by: \.key).values.compactMap {
            $0.max { $0.sleepMinutes < $1.sleepMinutes }
        }
        let values = nights.map { Double($0.sleepMinutes) }.sorted()
        let baselineReady = values.count >= 5 && !candidate.sourceID.hasPrefix("ambiguous::")
        let median: Double? = baselineReady ? (values[(values.count - 1) / 2] + values[values.count / 2]) / 2 : nil
        let comparison: MainSleepAssessment.DurationComparison
        if let median {
            let delta = Double(candidate.sleepMinutes) - median
            comparison = delta <= -45 ? .shorter : delta >= 45 ? .longer : .similar
        } else { comparison = .insufficientHistory }

        // Positive observations only: no awake samples does not prove uninterrupted sleep.
        let asleep = dataset.intervals.filter {
            $0.sourceID == candidate.sourceID && $0.kind == .sleep && $0.start < $0.end &&
            $0.start < candidate.end && $0.end > candidate.start && $0.end <= now
        }
        var awake = dataset.intervals.filter {
            $0.sourceID == candidate.sourceID && $0.kind == .awake && $0.start < $0.end &&
            $0.start < candidate.end && $0.end > candidate.start && $0.end <= now
        }.map { max($0.start, candidate.start)..<min($0.end, candidate.end) }
        // Exclude contradictory asleep portions before merging explicit awake intervals.
        for sleep in asleep {
            awake = awake.flatMap { range -> [Range<Date>] in
                guard sleep.start < range.upperBound && sleep.end > range.lowerBound else { return [range] }
                var parts: [Range<Date>] = []
                if range.lowerBound < sleep.start { parts.append(range.lowerBound..<min(sleep.start, range.upperBound)) }
                if sleep.end < range.upperBound { parts.append(max(sleep.end, range.lowerBound)..<range.upperBound) }
                return parts
            }
        }
        var awakeSeconds: TimeInterval = 0, coveredUntil = candidate.start
        for range in awake.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            awakeSeconds += max(0, range.upperBound.timeIntervalSince(max(coveredUntil, range.lowerBound)))
            coveredUntil = max(coveredUntil, range.upperBound)
        }
        let awakeMinutes = Int(awakeSeconds / 60)
        let durationText: String
        switch comparison {
        case .shorter: durationText = "比平时短一些"
        case .similar: durationText = "时长与平时接近"
        case .longer: durationText = "比平时长一些"
        case .insufficientHistory: durationText = ""
        }
        var observations = durationText.isEmpty ? [] : [durationText]
        if awakeMinutes >= 20 { observations.append("记录到中途清醒约\(awakeMinutes)分钟") }
        let assessmentText = observations.joined(separator: "，")
        let suggestion: String
        if comparison == .shorter || awakeMinutes >= 20 {
            suggestion = "今天温和起步，先做一件轻量的事。"
        } else if comparison == .longer {
            suggestion = "先舒展一下，再安排接下来的事。"
        } else if comparison == .similar {
            suggestion = "按自己的节奏，从一件小事开始。"
        } else {
            suggestion = "先感受一下醒后的状态，慢慢开始今天。"
        }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX"); format.calendar = calendar
        format.timeZone = calendar.timeZone; format.dateFormat = "HH:mm"
        let timeRange = "\(format.string(from: candidate.start))–\(format.string(from: candidate.end))"
        let title = "睡了\(candidate.sleepMinutes / 60)小时\(candidate.sleepMinutes % 60)分钟"
        let body = timeRange + (assessmentText.isEmpty ? "。" : "，\(assessmentText)。") + suggestion
        return .init(comparison: comparison, baselineNights: values.count, medianSleepMinutes: median,
            observedAwakeMinutes: awakeMinutes, assessmentText: assessmentText,
            suggestion: suggestion, title: title, body: body)
    }
}
