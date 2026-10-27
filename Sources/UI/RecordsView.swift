import SwiftUI

struct RecordsView: View {
    @EnvironmentObject private var store: LabStore
    @Environment(\.dismiss) private var dismiss
    @State private var quantityKind = QuantityKind.heartRate

    var body: some View {
        NavigationStack {
            List {
                Section("摘要") {
                    LabeledContent("心跳序列") { Text("\(store.dataset.heartbeats.count)") }
                    LabeledContent("心率") { Text("\(count(.heartRate))") }
                    LabeledContent("Apple SDNN") { Text("\(count(.sdnn))") }
                    LabeledContent("静息心率") { Text("\(count(.restingHeartRate))") }
                    LabeledContent("步数") { Text("\(count(.steps))") }
                    LabeledContent("睡眠区间") { Text("\(intervalCount(.sleep))") }
                    LabeledContent("运动区间") { Text("\(intervalCount(.workout))") }
                    LabeledContent("正念区间") { Text("\(intervalCount(.mindfulness))") }
                }

                Section("HRV 诊断") {
                    ForEach(store.result?.hrv ?? []) { point in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(LabFormat.dateTime.string(from: point.date)) · \(LabFormat.ms(point.rmssd))")
                                .font(.headline)
                            Text("Raw \(LabFormat.ms(point.rawRMSSD)) · \(Int(point.validDuration)) 秒 · \(point.pairCount) 组 · \(point.state.label)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(point.assessment.level) · 参考分 \(point.assessment.score)/100 · \(point.assessment.origin.rawValue)")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("记录：\(point.id)\n来源：\(point.sourceID)\n参数：\(store.selectedVersion.name)")
                                .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                            if point.exclusionReasons.isEmpty {
                                Text(point.baselineEligible ? "可进入默认日常基线" : "未进入默认日常基线")
                                    .font(.caption)
                                    .foregroundStyle(point.baselineEligible ? StressLabStyle.mint : StressLabStyle.orange)
                            } else {
                                Text(point.readableReasons.joined(separator: "；"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    if (store.result?.hrv ?? []).isEmpty {
                        Text("当天没有 HRV 记录")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("压力时间格") {
                    ForEach(store.result?.pressure ?? []) { point in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(LabFormat.time.string(from: point.date)) · \(point.score.map(String.init) ?? "无") · \(point.origin.label)")
                                .font(.headline)
                            Text("RMSSD \(LabFormat.ms(point.rmssd)) · HR \(LabFormat.bpm(point.heartRate)) · \(point.state.label)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if point.reasons.contains("frequent_movement") {
                                Text("频繁移动中 · 本格不参与压力计算")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let restingBaseline = point.restingHeartRateBaseline, point.restingHeartRate != nil {
                                Text("静息心率 \(LabFormat.bpm(point.restingHeartRate)) · 基线 \(baseline(restingBaseline))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text("HRV基线 \(baseline(point.hrvBaseline)) · 心率基线 \(baseline(point.heartRateBaseline))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("HRV采样 \(LabFormat.optionalTime(point.hrvDate)) · 心率采样 \(LabFormat.optionalTime(point.heartRateDate))\n版本 \(point.algorithmVersion)")
                                .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                            if !point.reasons.isEmpty {
                                Text(point.reasons.joined(separator: "；"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    if store.result?.pressure.allSatisfy({ $0.score == nil }) != false {
                        Text("当天没有可回算压力格")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("当天原始数值 · 当前来源") {
                    Picker("数据类型", selection: $quantityKind) {
                        Text("心率").tag(QuantityKind.heartRate)
                        Text("Apple SDNN").tag(QuantityKind.sdnn)
                        Text("静息心率").tag(QuantityKind.restingHeartRate)
                        Text("步数").tag(QuantityKind.steps)
                    }
                    ForEach(quantities) { sample in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(LabFormat.dateTime.string(from: sample.start)) → \(LabFormat.time.string(from: sample.end))")
                            Text("\(sample.value.formatted(.number.precision(.fractionLength(2)))) \(unit) · 活动：\(sample.motion.rawValue)")
                            Text("\(sample.id)\n\(sample.sourceID)").font(.caption2).textSelection(.enabled)
                        }.font(.caption)
                    }
                    if quantities.isEmpty { Text("当前来源当天无此类记录").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("记录列表")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func count(_ kind: QuantityKind) -> Int {
        store.dataset.quantities.filter { $0.kind == kind }.count
    }

    private func intervalCount(_ kind: IntervalKind) -> Int {
        store.dataset.intervals.filter { $0.kind == kind }.count
    }

    private func baseline(_ summary: BaselineSummary) -> String {
        let stats = "\(summary.days)天/\(summary.samples)样本"
        let numeric = "中位数 \(summary.median.map { String(format: "%.2f", $0) } ?? "—") / 尺度 \(summary.scale.map { String(format: "%.2f", $0) } ?? "—")"
        return "\(summary.ready ? "就绪" : "不足") \(stats)，\(numeric)"
    }

    private var quantities: [QuantityRecord] {
        store.dataset.quantities.filter { $0.sourceID == store.selectedSourceID && $0.kind == quantityKind && store.calendar.isDate($0.end, inSameDayAs: store.selectedDay) }.sorted { $0.end > $1.end }
    }
    private var unit: String {
        switch quantityKind { case .heartRate, .restingHeartRate: return "bpm"; case .sdnn: return "ms"; case .steps: return "步" }
    }
}
