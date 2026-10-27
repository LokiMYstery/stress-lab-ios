import Foundation
import Combine

private struct SavedState: Codable {
    var dataset: HealthDataset
    var versions: [ParameterVersion]
    var selectedVersionID: UUID
    var selectedSourceID: String
    var reports: [CachedDailyReport]

    init(dataset: HealthDataset, versions: [ParameterVersion], selectedVersionID: UUID,
         selectedSourceID: String, reports: [CachedDailyReport]) {
        self.dataset = dataset
        self.versions = versions
        self.selectedVersionID = selectedVersionID
        self.selectedSourceID = selectedSourceID
        self.reports = reports
    }

    private enum CodingKeys: String, CodingKey {
        case dataset, versions, selectedVersionID, selectedSourceID, reports
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        dataset = try fields.decode(HealthDataset.self, forKey: .dataset)
        versions = try fields.decode([ParameterVersion].self, forKey: .versions)
        selectedVersionID = try fields.decode(UUID.self, forKey: .selectedVersionID)
        selectedSourceID = try fields.decode(String.self, forKey: .selectedSourceID)
        reports = try fields.decodeIfPresent([CachedDailyReport].self, forKey: .reports) ?? []
    }
}

private struct CachedDailyReport: Codable {
    var dayStart: Date
    var timeZoneID: String
    var sourceID: String
    var versionID: UUID
    var generatedAt: Date
    var result: AnalysisResult
}

@MainActor final class LabStore: ObservableObject {
    static let shared = LabStore()
    let notifications = HealthNotifications()
    @Published var dataset = HealthDataset()
    @Published var result: AnalysisResult?
    @Published var selectedDay = Date()
    @Published var selectedSourceID = ""
    @Published var versions = [ParameterVersion(parameters: ExperimentParameters(), name: "V3 · 仅手表活动标记")]
    @Published var selectedVersionID = UUID()
    @Published var isShowingCachedReport = false
    @Published var isLoading = false
    @Published var isComputing = false
    @Published var status = "请授权读取健康数据"
    @Published var error: String?
    private let reader = HealthKitReader()
    private var generation = 0
    private var computation = 0
    private var hasStarted = false
    private var refreshPending = false
    private var observerRefreshTask: Task<Void, Never>?
    private var observerRevision = 0
    private var refreshTask: Task<Void, Never>?
    private var backgroundRegistrationTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var reportCache: [CachedDailyReport] = []

    var calendar: Calendar { Calendar.autoupdatingCurrent }
    var selectedVersion: ParameterVersion { versions.first { $0.id == selectedVersionID } ?? versions[0] }
    var dayRange: ClosedRange<Date> {
        let today = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .day, value: -6, to: today)!...today
    }
    var isDemo: Bool { dataset.isDemo }
    private var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StressLab", isDirectory: true).appendingPathComponent("state.json")
    }

    init() {
        selectedVersionID = versions[0].id
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let saved = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: fileURL))
                guard !saved.dataset.isDemo, !saved.versions.isEmpty,
                      saved.versions.allSatisfy({ $0.parameters.validationError == nil }) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                dataset = saved.dataset
                versions = saved.versions
                selectedVersionID = saved.selectedVersionID
                selectedSourceID = saved.selectedSourceID
                reportCache = saved.reports
                status = "已载入本机缓存；刷新后读取最新数据"
            }
        } catch { self.error = "本地缓存无法读取：\(error.localizedDescription)" }
        if !versions.contains(where: { $0.parameters.mappingVersion == 3 && !$0.parameters.useStepMovement }) {
            let calibrated = ParameterVersion(parameters: ExperimentParameters(), name: "V3 · 仅手表活动标记")
            versions.append(calibrated)
            selectedVersionID = calibrated.id
            persistSettings()
        }
        reader.onChange = { [weak self] type, error in
            guard let self, !self.isDemo else { return }
            self.notifications.recordCallback(type)
            if let error { self.notifications.backgroundStatus = "健康更新回调失败：\(error.localizedDescription)"; return }
            await self.handleObserverUpdate()
        }
        notifications.onOpenMeasurement = { [weak self] date, source, version in
            guard let self else { return }
            if let source, self.dataset.sources.contains(where: { $0.id == source }) { self.selectedSourceID = source }
            if let id = version?.split(separator: "/").last.flatMap({ UUID(uuidString: String($0)) }),
               self.versions.contains(where: { $0.id == id }) { self.selectedVersionID = id }
            self.selectedDay = min(max(self.calendar.startOfDay(for: date), self.dayRange.lowerBound), self.dayRange.upperBound)
            self.removeSelectedReport()
            self.persistSettings()
            self.recalculate(useCache: false)
        }
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--demo") { loadDemo() }
        if ProcessInfo.processInfo.arguments.contains("--empty-test") {
            dataset = HealthDataset(); selectedSourceID = ""
            status = "暂无可读取数据，请授权或检查手表同步"
        }
        #endif
        if !isDemo { recalculate() }
    }

    func authorizeAndRefresh() async {
        guard !isLoading else { return }
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--demo") || ProcessInfo.processInfo.arguments.contains("--empty-test") {
            return
        }
        #endif
        if isDemo { reader.reset(); dataset = HealthDataset(); selectedSourceID = ""; result = nil }
        let token = generation
        isLoading = true; error = nil
        do {
            try await reader.requestReadAccess()
            guard token == generation else { return }
            hasStarted = true; isLoading = false
            await refresh()
        } catch {
            guard token == generation else { return }
            isLoading = false
            self.error = "授权请求未完成：\(error.localizedDescription)"
        }
    }

    func refresh(forceSelectedDay: Bool = false) async {
        if let task = refreshTask {
            refreshPending = true
            await task.value
            if forceSelectedDay { removeSelectedReport(); recalculate(useCache: false) }
            return
        }
        guard !isLoading else { return }
        let token = generation
        let task = Task {
            repeat {
                self.refreshPending = false
                await self.performRefresh(forceSelectedDay: forceSelectedDay)
            } while self.refreshPending && !Task.isCancelled
        }
        refreshTask = task
        await task.value
        if token == generation { refreshTask = nil }
    }

    private func performRefresh(forceSelectedDay: Bool) async {
        guard !isLoading else { return }
        if isDemo {
            if forceSelectedDay { removeSelectedReport() }
            recalculate(clearPrevious: false, useCache: !forceSelectedDay)
            return
        }
        let token = generation
        isLoading = true; error = nil
        do {
            let snapshot = try await reader.refresh(existing: dataset, now: Date())
            guard token == generation else { return }
            let source = snapshot.sources.contains(where: { $0.id == selectedSourceID })
                ? selectedSourceID : defaultSource(in: snapshot)
            if forceSelectedDay { removeSelectedReport() }
            try save(dataset: snapshot, source: source)
            dataset = snapshot; selectedSourceID = source; hasStarted = true
            status = snapshot.heartbeats.isEmpty && snapshot.quantities.isEmpty
                ? "暂无可读取数据，请检查健康权限、手表同步与佩戴情况"
                : "本机数据已更新 · 不保证后台每六分钟刷新"
            recalculate(clearPrevious: false, useCache: !forceSelectedDay)
            let version = selectedVersion
            await notifications.process(dataset: snapshot, sourceID: source, parameters: version.parameters,
                version: "v\(version.parameters.mappingVersion)/\(version.id.uuidString)")
        } catch {
            guard token == generation else { return }
            reader.reset()
            self.error = "读取未完成，保留上次数据：\(error.localizedDescription)"
            notifications.reportReadFailure(error.localizedDescription)
            status = "刷新失败"
        }
        guard token == generation else { return }
        isLoading = false
    }

    func foreground() async {
        await notifications.refreshPermission()
        selectedDay = min(max(calendar.startOfDay(for: selectedDay), dayRange.lowerBound), dayRange.upperBound)
        if isDemo { recalculate(clearPrevious: false) }
        else if hasStarted || dataset.fetchedAt != nil { await refresh() }
    }
    func reevaluateFreshness() {
        guard !isLoading else { return }
        selectedDay = min(max(calendar.startOfDay(for: selectedDay), dayRange.lowerBound), dayRange.upperBound)
        guard !isHistorical(selectedDay, now: Date()) else { return }
        recalculate(clearPrevious: false)
    }
    func selectDay(_ date: Date) {
        selectedDay = min(max(calendar.startOfDay(for: date), dayRange.lowerBound), dayRange.upperBound)
        recalculate()
    }
    func selectSource(_ id: String) {
        guard dataset.sources.contains(where: { $0.id == id }) else { return }
        selectedSourceID = id; persistSettings(); recalculate()
    }
    func selectVersion(_ id: UUID) {
        guard versions.contains(where: { $0.id == id }) else { return }
        selectedVersionID = id; persistSettings(); recalculate()
    }
    func applyParameters(_ parameters: ExperimentParameters) {
        guard parameters.validationError == nil else { error = parameters.validationError; return }
        let version = ParameterVersion(parameters: parameters, name: "自定义 \(versions.count) · V\(parameters.mappingVersion)")
        versions.append(version); selectedVersionID = version.id
        persistSettings(); recalculate()
    }
    func clearLocalData() {
        generation += 1; computation += 1; analysisTask?.cancel()
        refreshTask?.cancel(); refreshTask = nil
        observerRefreshTask?.cancel(); observerRefreshTask = nil
        hasStarted = false; refreshPending = false
        reader.stopObserving(); reader.reset()
        notifications.reset()
        Task { await updateBackgroundRegistration() }
        dataset = HealthDataset(); result = nil; selectedSourceID = ""
        reportCache.removeAll(); isShowingCachedReport = false
        versions = [ParameterVersion(parameters: ExperimentParameters(), name: "V3 · 仅手表活动标记")]
        selectedVersionID = versions[0].id; isLoading = false
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) }
            error = nil; status = "本地缓存与参数版本已清除，Apple 健康原始数据未改动"
        } catch { self.error = "本地文件删除失败：\(error.localizedDescription)" }
        recalculate()
    }
    func loadDemo() {
        #if targetEnvironment(simulator)
        generation += 1; isLoading = false; reader.stopObserving()
        observerRefreshTask?.cancel(); observerRefreshTask = nil
        dataset = DemoData.make(now: Date(), calendar: calendar)
        reportCache.removeAll()
        selectedSourceID = dataset.sources[0].id; selectedDay = Date()
        status = "模拟数据 · 不属于健康记录 · 不会保存"; error = nil
        recalculate()
        #endif
    }
    private func defaultSource(in snapshot: HealthDataset) -> String {
        let watchIDs = Set(snapshot.sources.filter { $0.isAppleWatch && !$0.id.hasPrefix("ambiguous::") }.map(\.id))
        return snapshot.heartbeats.filter { watchIDs.contains($0.sourceID) }
            .max(by: { $0.end < $1.end })?.sourceID
            ?? snapshot.heartbeats.max(by: { $0.end < $1.end })?.sourceID
            ?? snapshot.sources.first?.id ?? ""
    }
    private func handleObserverUpdate() async {
        observerRevision += 1
        if let task = observerRefreshTask { await task.value; return }
        let task = Task {
            do { try await Task.sleep(for: .milliseconds(350)) }
            catch { return }
            guard !Task.isCancelled else { return }
            var handledRevision: Int
            repeat {
                handledRevision = observerRevision
                await refresh()
            } while handledRevision != observerRevision && !Task.isCancelled
        }
        observerRefreshTask = task
        await task.value
        observerRefreshTask = nil
    }

    /// Called synchronously from application launch, before HealthKit delivers wake-up events.
    func startHealthMonitoring() {
        guard !isDemo, dataset.fetchedAt != nil || notifications.enabled else { return }
        reader.startObserving()
        if notifications.enabled {
            Task { await updateBackgroundRegistration() }
        }
    }

    func setHealthNotifications(_ enabled: Bool) async {
        guard await notifications.setEnabled(enabled, dataset: dataset) else { return }
        if enabled {
            if !hasStarted && dataset.fetchedAt == nil { await authorizeAndRefresh() }
            else { await refresh() }
            reader.startObserving()
        }
        await updateBackgroundRegistration()
    }

    private func updateBackgroundRegistration() async {
        let previous = backgroundRegistrationTask
        let task = Task {
            if let previous { await previous.value }
            self.notifications.backgroundStatus = await self.reader.configureBackgroundDelivery(
                enabled: self.notifications.enabled && !self.isDemo)
        }
        backgroundRegistrationTask = task
        await task.value
    }
    private func recalculate(clearPrevious: Bool = true, useCache: Bool = true) {
        computation += 1
        let token = computation
        analysisTask?.cancel()
        let data = dataset, source = selectedSourceID, version = selectedVersion
        let day = selectedDay, now = Date(), cal = calendar
        if useCache, isHistorical(day, now: now), let cached = cachedReport(for: day, source: source, versionID: version.id) {
            result = cached.result
            isShowingCachedReport = true
            isComputing = false
            return
        }
        isShowingCachedReport = false
        isComputing = true
        if clearPrevious { result = nil }
        analysisTask = Task {
            let output = await Task.detached(priority: .userInitiated) {
                AnalysisEngine.analyze(dataset: data, sourceID: source, parameters: version.parameters,
                                       version: "v\(version.parameters.mappingVersion)/\(version.id.uuidString)", day: day, now: now, calendar: cal)
            }.value
            guard !Task.isCancelled, token == self.computation else { return }
            self.result = output
            self.isComputing = false
            if self.isHistorical(day, now: now) {
                self.putCachedReport(output, day: day, source: source, versionID: version.id)
            }
        }
    }

    private func isHistorical(_ day: Date, now: Date) -> Bool {
        calendar.startOfDay(for: day) < calendar.startOfDay(for: now)
    }

    private func cachedReport(for day: Date, source: String, versionID: UUID) -> CachedDailyReport? {
        let start = calendar.startOfDay(for: day)
        return reportCache.first {
            $0.dayStart == start && $0.timeZoneID == calendar.timeZone.identifier &&
            $0.sourceID == source && $0.versionID == versionID
        }
    }

    private func removeSelectedReport() {
        let start = calendar.startOfDay(for: selectedDay)
        reportCache.removeAll {
            $0.dayStart == start && $0.timeZoneID == calendar.timeZone.identifier &&
            $0.sourceID == selectedSourceID && $0.versionID == selectedVersionID
        }
    }

    private func putCachedReport(_ output: AnalysisResult, day: Date, source: String, versionID: UUID) {
        let start = calendar.startOfDay(for: day)
        reportCache.removeAll {
            $0.dayStart == start && $0.timeZoneID == calendar.timeZone.identifier &&
            $0.sourceID == source && $0.versionID == versionID
        }
        reportCache.append(CachedDailyReport(dayStart: start, timeZoneID: calendar.timeZone.identifier,
            sourceID: source, versionID: versionID, generatedAt: Date(), result: output))
        isShowingCachedReport = true
        let earliest = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: Date())) ?? .distantPast
        reportCache = Array(reportCache.filter { $0.dayStart >= earliest }
            .sorted { $0.generatedAt > $1.generatedAt }.prefix(80))
        if !isDemo {
            do { try save(dataset: dataset, source: selectedSourceID) }
            catch { self.error = "历史报告保存失败：\(error.localizedDescription)" }
        }
    }
    private func persistSettings() {
        guard !isDemo else { return }
        do { try save(dataset: dataset, source: selectedSourceID) }
        catch { self.error = "参数保存失败：\(error.localizedDescription)" }
    }
    private func save(dataset: HealthDataset, source: String) throws {
        guard !dataset.isDemo else { return }
        var folder = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        let saved = SavedState(dataset: dataset, versions: versions, selectedVersionID: selectedVersionID,
                               selectedSourceID: source, reports: reportCache)
        try JSONEncoder().encode(saved).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
