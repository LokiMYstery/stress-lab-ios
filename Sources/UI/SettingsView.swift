import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: LabStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingClear = false

    var body: some View {
        NavigationStack {
            Form {
                Section("数据源") {
                    if store.dataset.sources.isEmpty {
                        Text("暂无可选数据源")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("默认来源", selection: Binding(
                            get: { store.selectedSourceID },
                            set: { store.selectSource($0) }
                        )) {
                            ForEach(store.dataset.sources) { source in
                                Text(source.name + (source.isAppleWatch ? " · Watch" : ""))
                                    .tag(source.id)
                            }
                        }
                        if store.selectedSourceID.hasPrefix("ambiguous::") {
                            Text("此来源没有稳定设备 ID。App 会按同来源记录作实验估算，并在结果中提示设备可能混用。")
                                .font(.footnote).foregroundStyle(.orange)
                        }
                    }
                    LabeledContent("本地快照") {
                        Text(LabFormat.optionalTime(store.dataset.fetchedAt))
                    }
                    LabeledContent("记录数量") {
                        Text("\(store.dataset.heartbeats.count) HRV / \(store.dataset.quantities.count) 数值")
                    }
                }

                Section("版本") {
                    Picker("参数版本", selection: Binding(
                        get: { store.selectedVersionID },
                        set: { store.selectVersion($0) }
                    )) {
                        ForEach(store.versions) { version in
                            Text("\(version.name) · \(LabFormat.dateTime.string(from: version.createdAt))")
                                .tag(version.id)
                        }
                    }
                }

                HealthNotificationSettings(store: store, notifications: store.notifications)

                Section {
                    Button(role: .destructive) {
                        confirmingClear = true
                    } label: {
                        Label("清除本地缓存", systemImage: "trash")
                    }
                    .accessibilityIdentifier("settings.clear")

                    #if targetEnvironment(simulator)
                    Button {
                        store.loadDemo()
                    } label: {
                        Label("加载模拟数据", systemImage: "testtube.2")
                    }
                    #endif
                } header: {
                    Text("本地数据")
                } footer: {
                    Text("只清除本 App 的本地快照和参数版本，不会写入或删除 Apple 健康数据。")
                }
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .confirmationDialog("清除本地缓存？", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("清除", role: .destructive) {
                    store.clearLocalData()
                }
                Button("取消", role: .cancel) {}
            }
        }
    }
}

private struct HealthNotificationSettings: View {
    let store: LabStore
    @ObservedObject var notifications: HealthNotifications
    @Environment(\.openURL) private var openURL
    @State private var changing = false

    var body: some View {
        Section {
            Toggle("健康变化通知", isOn: Binding(
                get: { notifications.enabled },
                set: { value in
                    changing = true
                    Task { await store.setHealthNotifications(value); changing = false }
                }
            ))
            .disabled(changing || store.isDemo)
            .accessibilityIdentifier("notifications.enabled")
            Toggle("主睡眠结束提醒（实验）", isOn: Binding(get: { notifications.sleepEnabled }, set: {
                notifications.setSleepEnabled($0, dataset: store.dataset)
            }))
                .disabled(!notifications.enabled || store.isDemo)
                .accessibilityIdentifier("notifications.sleep")
            Text("自动通知静默时段：23:00–07:00（当地时间）。睡眠至少 3 小时，末段结束 30–120 分钟内判断；不保证实时醒来提醒。")
                .font(.footnote).foregroundStyle(.secondary)
            Text(notifications.sleepStatus).font(.footnote)
                .accessibilityIdentifier("notifications.sleepStatus")
            Toggle("心率压力趋势提醒", isOn: Binding(get: { notifications.trendEnabled }, set: { notifications.setTrendEnabled($0) }))
                .disabled(!notifications.enabled || store.isDemo)
                .accessibilityIdentifier("notifications.trend")
            if notifications.trendEnabled {
                Stepper("比较窗口：\(notifications.trendParameters.windowMinutes) 分钟", value: trendBinding(\.windowMinutes), in: 15...30, step: 5)
                Stepper("对比：\(notifications.trendParameters.comparisonMinutes) 分钟前", value: trendBinding(\.comparisonMinutes), in: 45...120, step: 15)
                Stepper("变化门槛：\(notifications.trendParameters.scoreThreshold) 分", value: trendBinding(\.scoreThreshold), in: 10...30, step: 5)
                Stepper("提醒间隔：\(notifications.trendParameters.cooldownMinutes) 分钟", value: trendBinding(\.cooldownMinutes), in: 30...120, step: 15)
                Text("每窗至少 3 个有效五分钟格、覆盖 8 分钟；仅静止清醒数据，至少 3 天个人基线。心率变化还须达到 8 bpm，最近两格方向一致。新 HRV 通知后静默趋势提醒 15 分钟。")
                    .font(.caption).foregroundStyle(.secondary)
                Text(notifications.trendStatus).font(.footnote)
                    .accessibilityIdentifier("notifications.trendStatus")
            }
            Button("发送测试通知（5 秒后）") { Task { await notifications.sendTest() } }
                .accessibilityIdentifier("notifications.test")
            Button("打开系统通知设置") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
            LabeledContent("通知权限", value: notifications.permission)
            Text(notifications.backgroundStatus).font(.footnote)
                .accessibilityIdentifier("notifications.backgroundStatus")
            LabeledContent("最近健康更新回调") { Text(LabFormat.optionalTime(notifications.lastCallback)) }
            Text(notifications.callbackType).font(.caption).foregroundStyle(.secondary)
            LabeledContent("最近通知提交") { Text(LabFormat.optionalTime(notifications.lastNotice)) }
            Text(notifications.deliveryStatus).font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("notifications.deliveryStatus")
        } header: {
            Text("健康更新通知")
        } footer: {
            Text(store.isDemo
                 ? "模拟数据不触发健康通知；测试按钮只验证本地通知。后台健康唤醒需真机测试。"
                 : "新 HRV 测量按更新通知；心率仅在明显升高或缓解时提醒，同方向持续变化不反复通知。心率趋势分使用固定基线，可能不同于看板综合分。首次同步、无变化或数据不足不提醒。iOS 决定唤醒与展示时间。")
        }
        .task { await notifications.refreshPermission() }
    }

    private func trendBinding(_ key: WritableKeyPath<HeartRateTrendParameters, Int>) -> Binding<Int> {
        Binding(get: { notifications.trendParameters[keyPath: key] }, set: {
            var parameters = notifications.trendParameters; parameters[keyPath: key] = $0
            notifications.setTrendParameters(parameters)
        })
    }
}
