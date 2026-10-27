import Foundation

/// Local clock gate; no deferred night-time alerts are queued.
enum NotificationQuietHours {
    static func isQuiet(at date: Date, calendar: Calendar) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return minute >= 23 * 60 || minute < 7 * 60
    }
}

struct MainSleepNotificationCandidate {
    var key: String
    var start: Date
    var end: Date
    var sleepMinutes: Int
    var sourceID: String
    var assessment: MainSleepAssessment? = nil
    var requestID: String { "stresslab.sleep.\(key)" }
    var durationText: String { "\(sleepMinutes / 60) 小时 \(sleepMinutes % 60) 分钟" }
}

/// Experimental nighttime episode inference, not a real-time wake detector.
struct MainSleepNotificationCursor: Codable {
    private var primed = false
    private var knownIDs = Set<String>()
    private var handled = Set<String>()
    private var pending = Set<String>()
    var status = "等待主睡眠记录"

    mutating func prime(dataset: HealthDataset) {
        primed = true
        knownIDs = Set(dataset.intervals.filter { $0.kind == .sleep }.map(\.id))
        pending.removeAll()
        status = "已建立睡眠基准；不补发历史提醒"
    }

    mutating func evaluate(dataset: HealthDataset, now: Date, calendar: Calendar) -> MainSleepNotificationCandidate? {
        guard !dataset.isDemo else { status = "模拟数据不触发睡眠提醒"; return nil }
        guard primed else { prime(dataset: dataset); return nil }
        let episodes = MainSleepEpisodes.collect(dataset: dataset, now: now, calendar: calendar,
            since: now.addingTimeInterval(-48 * 3600))
        let newIDs = Set(dataset.intervals.filter { $0.kind == .sleep }.map(\.id)).subtracting(knownIDs)
        knownIDs = Set(dataset.intervals.filter { $0.kind == .sleep }.map(\.id))
        let candidates = episodes.map { episode -> MainSleepNotificationCandidate in
            if episode.records.contains(where: { newIDs.contains($0.id) }) { pending.insert(episode.key) }
            return .init(key: episode.key, start: episode.start, end: episode.end,
                sleepMinutes: episode.sleepMinutes, sourceID: episode.sourceID)
        }
        guard var candidate = candidates.max(by: { lhs, rhs in
            if lhs.end != rhs.end { return lhs.end < rhs.end }
            if lhs.sleepMinutes != rhs.sleepMinutes { return lhs.sleepMinutes < rhs.sleepMinutes }
            return lhs.sourceID < rhs.sourceID
        }) else { status = "没有合格夜间主睡眠（实际睡眠至少 3 小时）"; return nil }
        let age = now.timeIntervalSince(candidate.end)
        guard !handled.contains(candidate.key), pending.contains(candidate.key) else { status = "历史或已提醒的主睡眠，不重复发送"; return nil }
        guard age <= 2 * 3600 else { status = "睡眠记录到达过晚（结束超过 2 小时），跳过"; pending.remove(candidate.key); return nil }
        guard age >= 30 * 60 else { status = "睡眠末段结束不足 30 分钟，等待下次健康更新复核"; return nil }
        guard !dataset.intervals.contains(where: { $0.kind == .sleep && $0.end > candidate.end && $0.start <= now && $0.end > $0.start }) else {
            status = "发现后续睡眠记录，暂不提醒"; return nil
        }
        guard !NotificationQuietHours.isQuiet(at: now, calendar: calendar) else { status = "23:00–07:00 静默；下次更新再判断时效"; return nil }
        candidate.assessment = MainSleepAssessmentEngine.assess(candidate: candidate, dataset: dataset, now: now, calendar: calendar)
        status = "主睡眠候选：\(candidate.durationText)；等待提交通知"
        return candidate
    }

    mutating func acknowledge(_ candidate: MainSleepNotificationCandidate) {
        handled.insert(candidate.key); pending.remove(candidate.key)
        status = "已提交主睡眠提醒：\(candidate.durationText)（不代表实时确认醒来）"
    }
}
