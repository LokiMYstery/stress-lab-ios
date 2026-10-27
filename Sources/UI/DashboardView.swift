import Charts
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var store: LabStore
    @State private var hrvSelection: Date?
    @State private var pressureSelection: Date?
    @State private var showingSettings = false
    @State private var showingRecords = false
    @State private var showingParameters = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if let error = store.error {
                        errorBanner(error)
                    }
                    HrvCard(selection: $hrvSelection)
                        .environmentObject(store)
                        .accessibilityIdentifier("dashboard.hrv")
                    PressureCard(selection: $pressureSelection)
                        .environmentObject(store)
                        .accessibilityIdentifier("dashboard.pressure")
                    AgentReferenceCard()
                        .environmentObject(store)
                        .accessibilityIdentifier("dashboard.agent")
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .accessibilityIdentifier("dashboard.scroll")
            .background(StressLabStyle.background.ignoresSafeArea())
            .navigationTitle("Stress Lab")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showingRecords = true
                    } label: {
                        Label("记录", systemImage: "list.bullet.rectangle")
                    }
                    .accessibilityIdentifier("toolbar.records")

                    Button {
                        showingParameters = true
                    } label: {
                        Label("实验参数", systemImage: "slider.horizontal.3")
                    }
                    .accessibilityIdentifier("toolbar.parameters")

                    Button {
                        showingSettings = true
                    } label: {
                        Label("设置", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("toolbar.settings")
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
                    .environmentObject(store)
            }
            .sheet(isPresented: $showingRecords) {
                RecordsView()
                    .environmentObject(store)
            }
            .sheet(isPresented: $showingParameters) {
                ParametersView()
                    .environmentObject(store)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.status)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text("\(store.isDemo ? "模拟快照" : "HealthKit 同步")：\(LabFormat.optionalTime(store.dataset.fetchedAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if store.isDemo {
                        Text("模拟数据")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                Button {
                    Task { await store.authorizeAndRefresh() }
                } label: {
                    Text("授权")
                        .font(.subheadline)
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isLoading)
                .accessibilityLabel("首次授权读取健康数据")
                Button {
                    Task { await store.refresh(forceSelectedDay: true) }
                } label: {
                    if store.isLoading {
                        ProgressView()
                            .frame(width: 18, height: 18)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 18, height: 18)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(store.isLoading)
                .accessibilityLabel(store.selectedDay < store.dayRange.upperBound ? "重算所选日期" : "刷新")
            }

            HStack {
                Button {
                    store.selectDay(store.calendar.date(byAdding: .day, value: -1, to: store.selectedDay) ?? store.selectedDay)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.bordered)
                .disabled(store.selectedDay <= store.dayRange.lowerBound)
                .accessibilityIdentifier("dashboard.previousDay")

                Spacer()
                Text(LabFormat.day.string(from: store.selectedDay))
                    .font(.headline.monospacedDigit())
                Spacer()

                Button {
                    store.selectDay(store.calendar.date(byAdding: .day, value: 1, to: store.selectedDay) ?? store.selectedDay)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.bordered)
                .disabled(store.selectedDay >= store.dayRange.upperBound)
                .accessibilityIdentifier("dashboard.nextDay")
            }
            if store.isShowingCachedReport {
                Text("历史报告已缓存 · 点刷新可主动重算")
                    .font(.caption2).foregroundStyle(.secondary)
                    .accessibilityIdentifier("report.cached")
            }
        }
        .padding(.top, 8)
    }

    private func errorBanner(_ error: String) -> some View {
        Text(error)
            .font(.footnote)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.red.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: StressLabStyle.radius, style: .continuous))
    }
}

private struct HrvCard: View {
    @EnvironmentObject private var store: LabStore
    @Binding var selection: Date?
    @State private var selectedSDNN: QuantityRecord?
    @State private var selectedRejected: HRVPoint?

    private var points: [HRVPoint] {
        store.result?.hrv.filter { $0.rmssd != nil } ?? []
    }

    private var rejected: [HRVPoint] {
        store.result?.hrv.filter { $0.rmssd == nil } ?? []
    }

    private var otherWatchSeries: [HeartbeatRecord] {
        let watchIDs = Set(store.dataset.sources.filter(\.isAppleWatch).map(\.id))
        return store.dataset.heartbeats.filter {
            $0.sourceID != store.selectedSourceID && watchIDs.contains($0.sourceID) &&
            store.calendar.isDate($0.end, inSameDayAs: store.selectedDay)
        }.sorted { $0.end < $1.end }
    }

    private var watchSDNNWithoutSelectedSeries: [QuantityRecord] {
        let watchIDs = Set(store.dataset.sources.filter(\.isAppleWatch).map(\.id))
        let selectedSeries = store.dataset.heartbeats.filter { $0.sourceID == store.selectedSourceID }
        return store.dataset.quantities.filter { sample in
            sample.kind == .sdnn && watchIDs.contains(sample.sourceID) &&
            store.calendar.isDate(sample.end, inSameDayAs: store.selectedDay) &&
            !selectedSeries.contains { abs($0.end.timeIntervalSince(sample.end)) <= 180 }
        }.sorted { $0.end < $1.end }
    }

    var body: some View {
        let latest = points.max { $0.date < $1.date }
        LabCard(
            title: "HRV 趋势 · RMSSD",
            subtitle: store.selectedVersion.parameters.hrvFilterEnabled
                ? "逐拍序列经质量门槛过滤，缺失不补点"
                : "实验无过滤：逐拍序列可算 RMSSD 就展示；缺口与倒序仍断开"
        ) {
            HStack(spacing: 8) {
                MetricPill(label: "最新值", value: LabFormat.ms(latest?.rmssd), tint: StressLabStyle.mint)
                MetricPill(label: "测量时间", value: latest.map { LabFormat.time.string(from: $0.date) } ?? "无", tint: StressLabStyle.blue)
                MetricPill(label: "个人基线", value: baselineText, tint: .gray)
            }
            .font(.caption)

            if points.isEmpty {
                EmptyChartView(text: "当天没有可用 RMSSD")
            } else {
                Chart {
                    sleepMarks(maxY: hrvMax)
                    ForEach(points) { point in
                        if let rmssd = point.rmssd {
                            LineMark(x: .value("时间", point.date), y: .value("RMSSD", rmssd))
                                .foregroundStyle(Color.gray.opacity(0.38))
                            PointMark(x: .value("时间", point.date), y: .value("RMSSD", rmssd))
                                .foregroundStyle(point.baselineEligible ? statusTint(point.assessment.score) : .gray)
                                .symbolSize(70)
                                .symbol {
                                    Circle()
                                        .fill(.white)
                                        .frame(width: 12, height: 12)
                                        .overlay {
                                            Circle().strokeBorder(point.baselineEligible ? statusTint(point.assessment.score) : .gray, lineWidth: 3)
                                        }
                                }
                        }
                    }
                    if selection != nil, let selected = selectedPoint {
                        RuleMark(x: .value("选择", selected.date))
                            .foregroundStyle(.secondary.opacity(0.45))
                    }
                }
                .chartXScale(domain: dayDomain)
                .chartYScale(domain: 0...hrvMax)
                .chartXAxis { timeAxis }
                .chartYAxisLabel("ms")
                .chartXSelection(value: $selection)
                .frame(height: 185)
                .accessibilityIdentifier("chart.hrv")
                HStack(spacing: 10) {
                    LegendDot(color: StressLabStyle.mint, text: "优秀")
                    LegendDot(color: StressLabStyle.blue, text: "一般")
                    LegendDot(color: StressLabStyle.orange, text: "注意")
                    LegendDot(color: StressLabStyle.red, text: "偏高")
                    LegendDot(color: .gray, text: "不入基线")
                }
                .font(.caption2).foregroundStyle(.secondary)
                Text("轻点图上的测量点，查看这次 RMSSD 的状态判断")
                    .font(.caption2).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(points) { point in
                            Button {
                                selection = point.date
                            } label: {
                                Text("\(LabFormat.time.string(from: point.date)) · \(LabFormat.ms(point.rmssd))")
                                    .font(.caption.monospacedDigit())
                            }
                            .buttonStyle(.bordered)
                            .tint(point.baselineEligible ? statusTint(point.assessment.score) : .gray)
                            .accessibilityIdentifier("hrv.point.\(point.id)")
                        }
                    }
                }
                Text("当天所选来源逐拍 \(store.result?.hrv.count ?? 0) 条：显示 \(points.count)、过滤 \(rejected.count)；其他手表来源逐拍 \(otherWatchSeries.count) 条，另有 \(watchSDNNWithoutSelectedSeries.count) 条 Apple SDNN 在当前来源未配对。")
                    .font(.caption2).foregroundStyle(.secondary)
                if !rejected.isEmpty || !watchSDNNWithoutSelectedSeries.isEmpty || !otherWatchSeries.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(rejected) { point in
                                Button("\(LabFormat.time.string(from: point.date)) · \(store.selectedVersion.parameters.hrvFilterEnabled ? "已过滤" : "无法计算")") {
                                    selectedRejected = point
                                    selectedSDNN = nil
                                }
                                .buttonStyle(.bordered).tint(.gray)
                            }
                            ForEach(watchSDNNWithoutSelectedSeries) { sample in
                                Button("\(LabFormat.time.string(from: sample.end)) · 仅 SDNN") {
                                    selectedSDNN = sample
                                    selectedRejected = nil
                                }
                                .buttonStyle(.bordered).tint(.gray)
                            }
                            ForEach(otherWatchSeries) { sample in
                                Button("\(LabFormat.time.string(from: sample.end)) · 其他来源逐拍") {
                                    store.selectSource(sample.sourceID)
                                    selection = nil
                                    selectedSDNN = nil
                                    selectedRejected = nil
                                }
                                .buttonStyle(.bordered).tint(.gray)
                            }
                        }
                    }
                }
                if let selectedRejected, store.calendar.isDate(selectedRejected.date, inSameDayAs: store.selectedDay) {
                    Text("这次逐拍记录未画成 RMSSD 点：有效 \(Int(selectedRejected.validDuration)) 秒、\(selectedRejected.pairCount) 组相邻差；原因 \(selectedRejected.readableReasons.joined(separator: "、"))。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let selectedSDNN, store.calendar.isDate(selectedSDNN.end, inSameDayAs: store.selectedDay) {
                    Text(sdnnExplanation(selectedSDNN))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            if selection != nil, let selectedPoint {
                HrvDetail(point: selectedPoint)
            }
        }
    }

    private var dayDomain: ClosedRange<Date> {
        let start = store.calendar.startOfDay(for: store.selectedDay)
        let end = store.calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return start...end
    }

    private var hrvMax: Double {
        max(80, (points.compactMap(\.rmssd).max() ?? 60) * 1.25)
    }

    private func sdnnExplanation(_ sample: QuantityRecord) -> String {
        let elsewhere = store.dataset.heartbeats.contains {
            $0.sourceID != store.selectedSourceID && abs($0.end.timeIntervalSince(sample.end)) <= 180
        }
        let reason = elsewhere ? "其他来源有接近时刻的逐拍记录，可在设置中切换来源核对。" : "目前未读到对应的逐拍序列，不能把 SDNN 直接换算为 RMSSD。"
        return "\(LabFormat.dateTime.string(from: sample.end))，Apple SDNN \(LabFormat.ms(sample.value))。\(reason)"
    }

    private func statusTint(_ score: Int) -> Color {
        switch score {
        case ...20: return StressLabStyle.mint
        case ...60: return StressLabStyle.blue
        case ...80: return StressLabStyle.orange
        default: return StressLabStyle.red
        }
    }

    @ChartContentBuilder
    private func sleepMarks(maxY: Double) -> some ChartContent {
        ForEach(store.result?.sleep ?? []) { interval in
            RectangleMark(
                xStart: .value("睡眠开始", max(interval.start, dayDomain.lowerBound)),
                xEnd: .value("睡眠结束", min(interval.end, dayDomain.upperBound)),
                yStart: .value("下限", 0),
                yEnd: .value("上限", maxY)
            )
            .foregroundStyle(StressLabStyle.purple.opacity(0.09))
        }
    }

    private var timeAxis: some AxisContent {
        AxisMarks(values: .stride(by: .hour, count: 6)) { value in
            AxisGridLine()
            AxisTick()
            AxisValueLabel(format: .dateTime.hour())
        }
    }

    private var selectedPoint: HRVPoint? {
        guard let selection else { return points.last }
        return points.min { abs($0.date.timeIntervalSince(selection)) < abs($1.date.timeIntervalSince(selection)) }
    }

    private var baselineText: String {
        guard let point = store.result?.pressure.last(where: { $0.hrvBaseline.samples > 0 || $0.heartRateBaseline.samples > 0 }) else { return "无" }
        return point.hrvBaseline.ready ? "\(point.hrvBaseline.days)天 / \(point.hrvBaseline.samples)条" : "不足"
    }
}

private struct PressureCard: View {
    @EnvironmentObject private var store: LabStore
    @Binding var selection: Date?

    private var points: [PressurePoint] { store.result?.pressure ?? [] }

    var body: some View {
        LabCard(
            title: "实时压力 · 实验模型",
            subtitle: store.selectedVersion.parameters.mappingVersion >= 3
                ? "V3：新 HRV 与点分同口径；频繁移动留白；突变短暂标红"
                : store.selectedVersion.parameters.mappingVersion == 2
                    ? "V2：只有明显突变才短暂标红；六分钟时间格"
                    : "RMSSD 较低、心率较高时参考分上升；六分钟时间格"
        ) {
            HStack(spacing: 8) {
                MetricPill(label: summaryLabel, value: scoreText(summaryPoint), tint: (summaryPoint?.origin.tint ?? .gray))
                MetricPill(label: "结果来源", value: summaryPoint?.origin.label ?? "无", tint: StressLabStyle.purple)
                MetricPill(label: "输入时间", value: inputTime(summaryPoint), tint: StressLabStyle.blue)
            }

            if points.allSatisfy({ $0.score == nil }) {
                EmptyChartView(text: "当天暂无可估算的压力时间格")
                Text(emptyReason)
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(store.result?.sleep ?? []) { interval in
                        RectangleMark(
                            xStart: .value("睡眠开始", max(interval.start, dayDomain.lowerBound)),
                            xEnd: .value("睡眠结束", min(interval.end, dayDomain.upperBound)),
                            yStart: .value("下限", 0),
                            yEnd: .value("上限", 100)
                        )
                        .foregroundStyle(StressLabStyle.purple.opacity(0.10))
                    }
                    ForEach(points) { point in
                        if let score = point.score {
                            BarMark(x: .value("时间", point.date), y: .value("压力", score), width: .fixed(3))
                                .foregroundStyle(color(for: point))
                                .opacity(opacity(for: point.origin))
                        } else if point.reasons.contains("frequent_movement") {
                            RectangleMark(
                                xStart: .value("移动开始", point.date),
                                xEnd: .value("移动结束", point.date.addingTimeInterval(6 * 60)),
                                yStart: .value("下限", 0), yEnd: .value("上限", 100)
                            )
                            .foregroundStyle(Color.gray.opacity(0.12))
                        }
                    }
                    if let selected = selectedPoint {
                        RuleMark(x: .value("选择", selected.date))
                            .foregroundStyle(.secondary.opacity(0.45))
                    }
                }
                .chartXScale(domain: dayDomain)
                .chartYScale(domain: 0...100)
                .chartXAxis { timeAxis }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: [0, 50, 100])
                }
                .chartXSelection(value: $selection)
                .frame(height: 185)
                .accessibilityIdentifier("chart.pressure")
                Text("\(store.selectedVersion.name)：有效 \(points.filter { $0.score != nil }.count) 格，红色 \(points.filter { ($0.score ?? 0) >= 81 }.count) 格 · 颜色代表分级，深浅代表依据")
                    .font(.caption2).foregroundStyle(.secondary)
                    .accessibilityIdentifier("pressure.validBins")
                let movingCount = points.filter { $0.score == nil && $0.reasons.contains("frequent_movement") }.count
                if movingCount > 0 {
                    Text("频繁移动中：\(movingCount) 个时间格已留空，不参与压力分计算。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            provenanceLegend
            Text("红色表示实验压力参考分 81–100；蓝色为 21–60。颜色不是心理压力诊断。")
                .font(.caption2).foregroundStyle(.secondary)
            if store.selectedSourceID.hasPrefix("ambiguous::") {
                Text("设备标识未提供：按当前来源分组作实验估算，可能混入同型号设备的数据。")
                    .font(.caption).foregroundStyle(StressLabStyle.orange)
            }

            if selection != nil, let selectedPoint {
                PressureDetail(point: selectedPoint)
            }
        }
    }

    private var dayDomain: ClosedRange<Date> {
        let start = store.calendar.startOfDay(for: store.selectedDay)
        let end = store.calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return start...end
    }

    private var timeAxis: some AxisContent {
        AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
            AxisGridLine()
            AxisTick()
            AxisValueLabel(format: .dateTime.hour())
        }
    }

    private var selectedPoint: PressurePoint? {
        guard let selection else { return points.last(where: { $0.score != nil }) }
        return points.min { abs($0.date.timeIntervalSince(selection)) < abs($1.date.timeIntervalSince(selection)) }
    }

    private var summaryPoint: PressurePoint? {
        let selectedDay = store.calendar.startOfDay(for: store.selectedDay)
        if store.calendar.isDate(selectedDay, inSameDayAs: Date()) {
            return store.result?.current
        }
        return points.last(where: { $0.score != nil })
    }

    private var summaryLabel: String {
        store.calendar.isDate(store.selectedDay, inSameDayAs: Date()) ? "当前值" : "当日末次"
    }

    private var emptyReason: String {
        guard let result = store.result else { return "正在读取或计算数据。" }
        let source = store.selectedSourceID
        let heartRates = store.dataset.quantities.filter {
            $0.sourceID == source && $0.kind == .heartRate && store.calendar.isDate($0.end, inSameDayAs: store.selectedDay)
        }.count
        if result.hrv.isEmpty && heartRates == 0 {
            return "这个来源当天没有 RMSSD 或心率记录；可在设置中切换来源，或检查手表同步。"
        }
        let reference = result.pressure.last ?? result.current
        return "当天 RMSSD \(result.hrv.count) 次、心率 \(heartRates) 条；此前 HRV 基线 \(reference.hrvBaseline.days) 天 / \(reference.hrvBaseline.samples) 条，心率基线 \(reference.heartRateBaseline.days) 天 / \(reference.heartRateBaseline.samples) 格。现有记录可能已过时或落在运动排除时段。"
    }

    private var provenanceLegend: some View {
        HStack(spacing: 12) {
            LegendDot(color: .gray, text: "深：RMSSD")
            LegendDot(color: .gray.opacity(0.82), text: "中：混合")
            LegendDot(color: .gray.opacity(0.58), text: "浅：心率")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func color(for point: PressurePoint) -> Color {
        guard let score = point.score else { return .clear }
        switch score {
        case 1...20: return StressLabStyle.mint
        case 21...60: return StressLabStyle.blue.opacity(0.65)
        case 61...80: return StressLabStyle.orange
        default: return StressLabStyle.red
        }
    }

    private func opacity(for origin: EstimateOrigin) -> Double {
        switch origin {
        case .hrv: return 1.0
        case .blended: return 0.82
        case .heartRate: return 0.58
        case .default: return 0.25
        }
    }

    private func scoreText(_ point: PressurePoint?) -> String {
        guard let point, let score = point.score else { return "无" }
        return "\(score) · \(point.level)"
    }

    private func inputTime(_ point: PressurePoint?) -> String {
        guard let point else { return "无" }
        return LabFormat.optionalTime([point.hrvDate, point.heartRateDate, point.restingHeartRateDate].compactMap { $0 }.max())
    }
}

private struct LegendDot: View {
    var color: Color
    var text: String

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
        }
    }
}

private struct AgentReferenceCard: View {
    @EnvironmentObject private var store: LabStore

    var body: some View {
        LabCard(title: store.selectedDay < store.dayRange.upperBound ? "报告生成时的参考结果" : "当前供 Agent 参考的结果预览", subtitle: "实验结果，不作为医疗判断") {
            if let point = store.result?.current {
                HStack(alignment: .firstTextBaseline) {
                    Text(point.score.map(String.init) ?? "—")
                        .font(.system(size: 46, weight: .bold, design: .rounded).monospacedDigit())
                    VStack(alignment: .leading, spacing: 6) {
                        Text(point.level)
                            .font(.title3.weight(.semibold))
                        Text("\(point.origin.label) · \(point.state.label)")
                            .font(.subheadline)
                            .foregroundStyle(point.origin.tint)
                    }
                    Spacer()
                }
                HStack(spacing: 8) {
                    MetricPill(label: "RMSSD", value: LabFormat.ms(point.rmssd), tint: StressLabStyle.mint)
                    MetricPill(label: "心率", value: LabFormat.bpm(point.heartRate), tint: StressLabStyle.blue)
                    if point.restingHeartRate != nil {
                        MetricPill(label: "静息心率", value: LabFormat.bpm(point.restingHeartRate), tint: StressLabStyle.purple)
                    }
                }
                Text("RMSSD 采样：\(LabFormat.optionalTime(point.hrvDate)) · 心率采样：\(LabFormat.optionalTime(point.heartRateDate)) · 静息心率：\(LabFormat.optionalTime(point.restingHeartRateDate))")
                    .font(.caption).foregroundStyle(.secondary)
                Text("\(store.selectedVersion.name) · 默认值不是测量结果")
                    .font(.caption).foregroundStyle(.secondary)
                if point.reasons.contains("frequent_movement") {
                    Text("频繁移动中：本时段不计算压力参考分。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if !point.reasons.isEmpty {
                    Text(point.reasons.joined(separator: "；"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                EmptyChartView(text: "暂无可供 Agent 参考的结果")
            }
        }
    }
}

private struct EmptyChartView: View {
    var text: String

    var body: some View {
        ContentUnavailableView(text, systemImage: "waveform.path.ecg", description: Text("不会用默认值伪造历史曲线"))
            .frame(height: 180)
    }
}

private struct HrvDetail: View {
    @EnvironmentObject private var store: LabStore
    var point: HRVPoint

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(LabFormat.dateTime.string(from: point.date)) · \(point.state.label)")
                .font(.subheadline.weight(.semibold))
            if let rmssd = point.rmssd, rmssd > 0 {
                Text("\(point.assessment.level) · 参考分 \(point.assessment.score)/100")
                    .font(.headline)
                    .foregroundStyle(assessmentColor)
                Text(assessmentBasis)
                    .font(.footnote).foregroundStyle(.secondary)
                if store.selectedVersion.parameters.mappingVersion >= 3 {
                    Text("V3 点分经过校准曲线；新 HRV 对应的实时压力先采用同一分数。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("本次 RMSSD 无效，无法判断状态")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
            Text("RMSSD \(LabFormat.ms(point.rmssd))，Raw \(LabFormat.ms(point.rawRMSSD))，有效 \(Int(point.validDuration)) 秒，\(point.pairCount) 组相邻差")
                .font(.footnote)
            Text(point.baselineEligible ? "进入默认日常基线" : "不进入默认日常基线")
                .font(.footnote)
                .foregroundStyle(point.baselineEligible ? StressLabStyle.mint : StressLabStyle.orange)
            if !point.exclusionReasons.isEmpty {
                Text(point.readableReasons.joined(separator: "；"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var assessmentColor: Color {
        switch point.assessment.score {
        case ...20: return StressLabStyle.mint
        case ...60: return StressLabStyle.blue
        case ...80: return StressLabStyle.orange
        default: return StressLabStyle.red
        }
    }

    private var assessmentBasis: String {
        let reference = point.assessment.baseline
        let source = point.sourceID.hasPrefix("ambiguous::") ? "；设备来源待确认" : ""
        switch point.assessment.origin {
        case .personal:
            return "对照此前 \(reference.days) 天、\(reference.samples) 次个人 RMSSD 测量（中位数 \(reference.median.map { String(format: "%.1f", exp($0)) } ?? "—") ms）\(source)；仅供实验参考。"
        case .provisional:
            return "个人历史仅 \(reference.days) 天、\(reference.samples) 次（中位数 \(reference.median.map { String(format: "%.1f", exp($0)) } ?? "—") ms），使用临时基线\(source)；判断置信度较低。"
        case .default:
            return "缺少可用个人历史，按实验默认 RMSSD \(Int(store.selectedVersion.parameters.defaultRMSSDMS)) ms 计算\(source)；这不是测出的压力。"
        }
    }
}

private struct PressureDetail: View {
    @EnvironmentObject private var store: LabStore
    var point: PressurePoint

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(LabFormat.dateTime.string(from: point.date)) · \(point.origin.label) · \(point.state.label)")
                .font(.subheadline.weight(.semibold))
            if point.reasons.contains("frequent_movement") {
                Text("频繁移动中：本时间格不计算压力参考分。")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
            Text("RMSSD \(LabFormat.ms(point.rmssd))，心率 \(LabFormat.bpm(point.heartRate))，HRV 权重 \(Int((point.hrvWeight * 100).rounded()))%")
                .font(.footnote)
            if let resting = point.restingHeartRate, let restingBaseline = point.restingHeartRateBaseline {
                Text("静息心率 \(LabFormat.bpm(resting))，基线 \(baseline(restingBaseline))；V1 心率通道的静息心率权重 \(Int((store.selectedVersion.parameters.restingHRWeight * 100).rounded()))%。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Text("HRV基线 \(baseline(point.hrvBaseline))；心率基线 \(baseline(point.heartRateBaseline))")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("算法 \(point.algorithmVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if point.reasons.contains("hr_default_reference") || point.reasons.contains("hrv_default_reference") {
                Text("历史不足时使用实验参照：RMSSD \(Int(store.selectedVersion.parameters.defaultRMSSDMS)) ms、心率 \(Int(store.selectedVersion.parameters.defaultHeartRateBPM)) bpm。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if point.reasons.contains("motion_unknown") {
                Text("本次心率没有活动状态标记，已排除已知步数和运动时段；结论置信度较低。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if point.reasons.contains("acute_red_suppressed") {
                Text("V2：压力参考分较高，但未见足够突然的上升，或仍在红色冷却期，显示为注意压力。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if point.reasons.contains("fresh_hrv_score_anchor") {
                Text("刚测得 RMSSD：本格沿用该 HRV 点的压力参考分。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func baseline(_ summary: BaselineSummary) -> String {
        summary.ready ? "\(summary.days)天/\(summary.samples)样本" : "不足(\(summary.days)天/\(summary.samples)样本)"
    }
}
