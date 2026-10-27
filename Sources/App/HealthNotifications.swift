import Foundation
import Combine
import UserNotifications

@MainActor final class HealthNotifications: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var enabled = false
    @Published private(set) var trendEnabled = true
    @Published private(set) var trendParameters = HeartRateTrendParameters()
    @Published private(set) var trendStatus = "等待有效心率窗口"
    @Published private(set) var permission = "尚未申请"
    @Published var backgroundStatus = "未开启后台接收"
    @Published private(set) var lastCallback: Date?
    @Published private(set) var callbackType = "—"
    @Published private(set) var lastNotice: Date?
    @Published private(set) var deliveryStatus = "尚未发送"
    var onOpenMeasurement: ((Date, String?, String?) -> Void)?
    private var cursor = HealthNotificationCursor()
    private var sleepCursor = MainSleepNotificationCursor()
    @Published private(set) var sleepStatus = "等待主睡眠记录"
    @Published private(set) var sleepEnabled = true
    @Published private(set) var lastSleepNoticeText: String?
    @Published private(set) var lastSleepNoticeAt: Date?
    private var generation = 0
    private let center = UNUserNotificationCenter.current()
    private var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StressLab/notification-state.json")
    }
    private struct State: Codable {
        var enabled: Bool
        var cursor: HealthNotificationCursor
        var lastNotice: Date?
        var lastCallback: Date?
        var callbackType: String?
        var deliveryStatus: String?
        var trendEnabled: Bool?
        var trendParameters: HeartRateTrendParameters?
        var sleepCursor: MainSleepNotificationCursor?
        var sleepEnabled: Bool?
        var lastSleepNoticeText: String?
        var lastSleepNoticeAt: Date?
    }

    override init() {
        super.init()
        if let data = try? Data(contentsOf: fileURL), let state = try? JSONDecoder().decode(State.self, from: data) {
            enabled = state.enabled
            sleepCursor = state.sleepCursor ?? MainSleepNotificationCursor()
            sleepEnabled = state.sleepEnabled ?? true
            lastSleepNoticeText = state.lastSleepNoticeText
            lastSleepNoticeAt = state.lastSleepNoticeAt
            sleepStatus = sleepCursor.status
            cursor = state.cursor; lastNotice = state.lastNotice
            lastCallback = state.lastCallback; callbackType = state.callbackType ?? "—"
            deliveryStatus = state.deliveryStatus ?? "尚未发送"
            trendEnabled = state.trendEnabled ?? true
            if let parameters = state.trendParameters, parameters.valid { trendParameters = parameters }
        }
        center.delegate = self
    }

    func refreshPermission() async {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized: permission = "已允许"
        case .provisional: permission = "静默通知"
        case .ephemeral: permission = "临时允许"
        case .denied: permission = "系统通知已关闭"
        case .notDetermined: permission = "尚未申请"
        @unknown default: permission = "未知"
        }
    }

    func setEnabled(_ value: Bool, dataset: HealthDataset) async -> Bool {
        if value {
            do {
                guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                    await refreshPermission(); deliveryStatus = "请在系统设置允许 Stress Lab 通知"; return false
                }
            } catch { deliveryStatus = "通知授权失败：\(error.localizedDescription)"; return false }
            cursor = HealthNotificationCursor()
            if dataset.fetchedAt != nil, !dataset.isDemo { cursor.prime(dataset); sleepCursor.prime(dataset: dataset) }
        }
        generation += 1
        enabled = value
        if !value { center.removeAllPendingNotificationRequests() }
        persist(); await refreshPermission()
        return true
    }

    func recordCallback(_ type: String) {
        lastCallback = Date()
        callbackType = type.replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
        persist()
    }

    func setSleepEnabled(_ value: Bool, dataset: HealthDataset) {
        generation += 1; sleepEnabled = value; sleepCursor.prime(dataset: dataset)
        sleepStatus = sleepCursor.status; persist()
    }

    func setTrendEnabled(_ value: Bool) { generation += 1; trendEnabled = value; cursor.trendIdentity = nil; persist() }
    func setTrendParameters(_ value: HeartRateTrendParameters) {
        guard value.valid else { return }
        generation += 1; trendParameters = value; cursor.trendIdentity = nil; persist()
    }

    func reportReadFailure(_ message: String) {
        deliveryStatus = "健康数据读取失败，等待下次更新或回前台重试：\(message)"
        persist()
    }

    func process(dataset: HealthDataset, sourceID: String, parameters: ExperimentParameters, version: String) async {
        guard enabled, !dataset.isDemo else { return }
        let token = generation
        let now = Date(), calendar = Calendar.autoupdatingCurrent
        let previous = cursor
        // Include a just-arrived measurement across midnight; the current score still uses now.
        let day = dataset.heartbeats.filter { $0.sourceID == sourceID && $0.end <= now }
            .max(by: { $0.end < $1.end })?.end ?? now
        let trendSettings = trendParameters
        let computed = await Task.detached(priority: .utility) {
            let output = AnalysisEngine.analyze(dataset: dataset, sourceID: sourceID, parameters: parameters,
                version: version, day: day, now: now, calendar: calendar)
            let trend = AnalysisEngine.heartRateTrend(dataset: dataset, sourceID: sourceID, parameters: parameters,
                trend: trendSettings, now: now, calendar: calendar)
            return (output, trend)
        }.value
        let (output, trend) = computed
        guard enabled, token == generation else { return }
        let settings = await center.notificationSettings()
        guard enabled, token == generation else { return }
        guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else {
            deliveryStatus = "系统通知未允许；请在设置中开启"
            await refreshPermission(); return
        }
        if let trend {
            trendStatus = "心率通道 \(trend.previousScore) → \(trend.recentScore)（\(trend.delta >= 0 ? "+" : "")\(trend.delta)）· 有效格 \(trend.previousBins)/\(trend.recentBins)"
        } else { trendStatus = "窗口覆盖、静止标记或个人基线不足；不触发趋势通知" }
        let hrvCandidate = cursor.next(dataset: dataset, sourceID: sourceID, result: output, now: now)
        let trendCandidate = cursor.nextTrend(dataset: dataset, evaluation: trendEnabled && hrvCandidate == nil ? trend : nil,
            parameters: trendSettings, identity: "\(sourceID)/\(version)/\(calendar.timeZone.identifier)", now: now)
        if await processSleep(dataset: dataset, now: now, calendar: calendar, token: token) { return }
        guard previous.primed, let candidate = hrvCandidate ?? trendCandidate else {
            deliveryStatus = previous.primed ? "已检查更新；没有新的可通知结果" : "首次同步已建立记录基准；从下次新测量开始通知"
            persist(); return
        }
        guard !NotificationQuietHours.isQuiet(at: now, calendar: calendar) else {
            deliveryStatus = "23:00–07:00 睡眠时段不发送健康通知；不补发夜间压力提醒"
            persist(); return
        }
        let content = UNMutableNotificationContent()
        let pressureLabel: String
        let suggestion: String
        switch candidate.score {
        case ...20:
            pressureLabel = "压力较低"
            suggestion = "当前压力较低，适合推进任务。让音乐陪你开始。"
        case ...60:
            pressureLabel = "压力一般"
            suggestion = "按自己的节奏，继续手边的事。让音乐陪你保持专注。"
        case ...80:
            pressureLabel = "压力偏高"
            suggestion = "先把节奏放慢一点，让舒缓的声音陪你缓一缓。"
        default:
            pressureLabel = "压力高"
            suggestion = "给自己留一点休息时间，放慢呼吸，听一会儿舒缓的声音。"
        }
        content.title = String(format: "HRV %.1f ms · %@", candidate.value, pressureLabel)
        content.body = suggestion + "\n采样 \(time(candidate.measuredAt))"
            + (candidate.provisional ? " · 临时基线参考" : " · 个人基线参考")
        if let trend = candidate.trend {
            let direction = trend.direction == .rising ? "有所升高" : "有所缓解"
            content.title = "心率估算 · \(pressureLabel)（\(direction)）"
            let bpmChange = String(format: "%.0f → %.0f bpm", trend.previousBPM, trend.recentBPM)
            content.body = suggestion + "\n窗口心率 \(bpmChange) · 心率估算"
                + (candidate.provisional ? " · 临时基线参考" : " · 个人基线参考")
        }
        content.sound = .default
        content.threadIdentifier = "stresslab.health-updates"
        content.userInfo = ["measurementDate": candidate.measuredAt.timeIntervalSince1970,
                            "algorithmVersion": version, "sourceID": sourceID]
        do {
            try await center.add(UNNotificationRequest(identifier: candidate.requestID, content: content, trigger: nil))
            guard enabled, token == generation else {
                center.removePendingNotificationRequests(withIdentifiers: [candidate.requestID]); return
            }
            lastNotice = now
            cursor.acknowledge(candidate, at: now)
            deliveryStatus = "已提交本地通知；系统决定实际展示时间"
        } catch {
            cursor.retry(candidate)
            deliveryStatus = "通知提交失败：\(error.localizedDescription)"
        }
        persist()
    }

    private func processSleep(dataset: HealthDataset, now: Date, calendar: Calendar, token: Int) async -> Bool {
        guard sleepEnabled else { sleepStatus = "主睡眠提醒已关闭"; return false }
        let candidate = sleepCursor.evaluate(dataset: dataset, now: now, calendar: calendar)
        sleepStatus = sleepCursor.status
        guard let candidate else { persist(); return false }
        let content = UNMutableNotificationContent()
        guard let assessment = candidate.assessment else { return false }
        content.title = assessment.title
        content.body = assessment.body
        content.sound = .default
        content.threadIdentifier = "stresslab.sleep-updates"
        content.userInfo = ["measurementDate": candidate.end.timeIntervalSince1970,
                            "sourceID": candidate.sourceID, "notificationType": "main_sleep_ended",
                            "sleepMinutes": candidate.sleepMinutes,
                            "sleepStart": candidate.start.timeIntervalSince1970,
                            "sleepEnd": candidate.end.timeIntervalSince1970,
                            "assessmentVersion": MainSleepAssessment.version,
                            "durationComparison": assessment.comparison.rawValue,
                            "baselineNights": assessment.baselineNights,
                            "observedAwakeMinutes": assessment.observedAwakeMinutes]
        do {
            try await center.add(UNNotificationRequest(identifier: candidate.requestID, content: content, trigger: nil))
            guard enabled, sleepEnabled, token == generation else {
                center.removePendingNotificationRequests(withIdentifiers: [candidate.requestID]); return true
            }
            sleepCursor.acknowledge(candidate); sleepStatus = sleepCursor.status
            lastSleepNoticeText = assessment.title + "\n" + assessment.body
            lastSleepNoticeAt = now
            lastNotice = now; deliveryStatus = sleepStatus
        } catch { deliveryStatus = "睡眠通知提交失败，等待下次更新重试：\(error.localizedDescription)" }
        persist(); return true
    }

    func sendTest() async {
        deliveryStatus = "正在申请通知权限"
        do {
            guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                await refreshPermission(); deliveryStatus = "请在系统设置允许通知"; return
            }
            let content = UNMutableNotificationContent()
            content.title = "Stress Lab · 通知测试"
            content.body = "本地通知通路正常。这是测试消息，没有读取或生成健康测量。"
            content.sound = .default
            try await center.add(UNNotificationRequest(identifier: "stresslab.test", content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)))
            deliveryStatus = "测试通知已安排，约 5 秒后展示"
            await refreshPermission()
        } catch { deliveryStatus = "测试通知失败：\(error.localizedDescription)" }
    }

    func reset() {
        generation += 1
        enabled = false; trendEnabled = true; trendParameters = HeartRateTrendParameters(); cursor = HealthNotificationCursor()
        sleepCursor = MainSleepNotificationCursor(); sleepEnabled = true; sleepStatus = sleepCursor.status
        lastSleepNoticeText = nil; lastSleepNoticeAt = nil
        lastCallback = nil; lastNotice = nil; backgroundStatus = "未开启后台接收"
        deliveryStatus = "通知记录已清除"
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
        persist()
    }

    private func persist() {
        do {
            var folder = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try folder.setResourceValues(values)
            let state = State(enabled: enabled, cursor: cursor,
                lastNotice: lastNotice, lastCallback: lastCallback, callbackType: callbackType, deliveryStatus: deliveryStatus,
                trendEnabled: trendEnabled, trendParameters: trendParameters, sleepCursor: sleepCursor, sleepEnabled: sleepEnabled,
                lastSleepNoticeText: lastSleepNoticeText, lastSleepNoticeAt: lastSleepNoticeAt)
            try JSONEncoder().encode(state).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { deliveryStatus = "通知状态保存失败：\(error.localizedDescription)" }
    }

    private func time(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let timestamp = response.notification.request.content.userInfo["measurementDate"] as? Double
        let source = response.notification.request.content.userInfo["sourceID"] as? String
        let version = response.notification.request.content.userInfo["algorithmVersion"] as? String
        Task { @MainActor in
            if let timestamp { self.onOpenMeasurement?(Date(timeIntervalSince1970: timestamp), source, version) }
            completionHandler()
        }
    }
}
