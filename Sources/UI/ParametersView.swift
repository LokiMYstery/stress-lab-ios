import SwiftUI

struct ParametersView: View {
    @EnvironmentObject private var store: LabStore
    @Environment(\.dismiss) private var dismiss
    @State private var parameters = ExperimentParameters()

    var body: some View {
        NavigationStack {
            Form {
                Section("基线") {
                    Stepper("基线窗口 \(parameters.baselineDays) 天", value: $parameters.baselineDays, in: 7...30)
                    Stepper("最少覆盖 \(parameters.minimumDays) 天", value: $parameters.minimumDays, in: 1...parameters.baselineDays)
                    Stepper("RMSSD 最少 \(parameters.minimumHRVRecords) 条", value: $parameters.minimumHRVRecords, in: 1...200)
                    Stepper("心率最少 \(parameters.minimumHRBins) 格", value: $parameters.minimumHRBins, in: 1...1000)
                }

                Section("数据时效") {
                    SliderRow(title: "心率窗口", value: $parameters.heartRateFreshMinutes, range: 1...60, suffix: "分钟")
                    SliderRow(title: "RMSSD 权重衰减", value: $parameters.hrvLifetimeHours, range: 0.25...12, suffix: "小时")
                    SliderRow(title: "运动恢复排除", value: $parameters.workoutRecoveryMinutes, range: 0...120, suffix: "分钟")
                }

                Section {
                    Toggle("启用 RMSSD 质量过滤", isOn: $parameters.hrvFilterEnabled)
                    SliderRow(title: "最小间隔", value: $parameters.minIntervalMS, range: 200...1000, suffix: "ms")
                    SliderRow(title: "最大间隔", value: $parameters.maxIntervalMS, range: 1000...3000, suffix: "ms")
                    SliderRow(title: "连续片段", value: $parameters.minimumDuration, range: 10...300, suffix: "秒")
                    Stepper("相邻差 \(parameters.minimumPairs) 组", value: $parameters.minimumPairs, in: 2...300)
                } header: {
                    Text("RMSSD 质量门槛")
                } footer: {
                    Text("关闭时不按间隔范围、时长或组数隐藏测量；仍断开漏拍、倒序和无效时间。仅用于与 StressWatch 对照。")
                }

                Section("分值映射") {
                    SliderRow(title: "中心值", value: $parameters.center, range: 1...100, suffix: "")
                    if parameters.mappingVersion == 0 {
                        SliderRow(title: "V0 单一斜率", value: $parameters.slope, range: 1...50, suffix: "")
                    } else {
                        SliderRow(title: "压力升高斜率", value: $parameters.pressureSlope, range: 1...30, suffix: "")
                        SliderRow(title: "恢复方向斜率", value: $parameters.recoverySlope, range: 1...30, suffix: "")
                        SliderRow(title: "静息心率权重", value: $parameters.restingHRWeight, range: 0...1, suffix: "")
                        SliderRow(title: "静息心率尺度下限", value: $parameters.restingHRScaleFloor, range: 3...20, suffix: "bpm")
                    }
                    SliderRow(title: "lnRMSSD 下限", value: $parameters.hrvScaleFloor, range: 0.05...1, suffix: "")
                    SliderRow(title: "心率下限", value: $parameters.hrScaleFloor, range: 1...20, suffix: "bpm")
                }

                if parameters.mappingVersion >= 2 {
                    Section {
                        SliderRow(title: "红色最小跃升", value: $parameters.redJumpThreshold, range: 5...50, suffix: "分")
                        SliderRow(title: "两次红色最短间隔", value: $parameters.redCooldownMinutes, range: 0...180, suffix: "分钟")
                    } header: {
                        Text("V2 突变红色规则")
                    } footer: {
                        Text("只有前 30 分钟与最近一格都出现明显上升，且越过冷却期，才标红；其他高分上限显示橙色。")
                    }
                }

                if parameters.mappingVersion >= 3 {
                    Section {
                        SliderRow(title: "最低参考分", value: $parameters.hrvScoreFloor, range: 1...20, suffix: "")
                        SliderRow(title: "拐点原分数", value: $parameters.hrvScoreMidpoint, range: 20...80, suffix: "")
                        SliderRow(title: "曲线陡峭度", value: $parameters.hrvScoreSteepness, range: 0.03...0.4, suffix: "")
                    } header: {
                        Text("V3 HRV 点分数校准")
                    } footer: {
                        Text("根据已配对测量点拟合的单调 S 曲线；V0/V1/V2 保持旧口径，便于同日对照。")
                    }
                }

                if parameters.mappingVersion >= 2 {
                    Section {
                        if parameters.useStepMovement {
                            SliderRow(title: "步数观察窗口", value: $parameters.movementStepWindowMinutes, range: 1...20, suffix: "分钟")
                            SliderRow(title: "该窗口的步数门槛", value: $parameters.movementStepThreshold, range: 1...200, suffix: "步")
                        } else {
                            LabeledContent("当前依据", value: "Apple Watch 心率 active 标记")
                        }
                    } header: {
                        Text("频繁移动排除")
                    } footer: {
                        Text(parameters.useStepMovement
                             ? "此历史参数版本还会用步数判定；新版默认仅依据手表心率 active 标记。运动记录及恢复期始终单独排除。"
                             : "只在手表心率样本明确标记 active 后的五分钟内留空；步数不参与。运动记录及恢复期仍单独排除。")
                    }
                }

                Section {
                    SliderRow(title: "RMSSD 默认参考", value: $parameters.defaultRMSSDMS, range: 10...200, suffix: "ms")
                    SliderRow(title: "心率默认参考", value: $parameters.defaultHeartRateBPM, range: 40...120, suffix: "bpm")
                    SliderRow(title: "RMSSD 默认尺度", value: $parameters.defaultHRVScale, range: 0.1...2, suffix: "")
                    SliderRow(title: "心率默认尺度", value: $parameters.defaultHeartRateScale, range: 3...30, suffix: "bpm")
                } header: {
                    Text("历史不足时的实验参照")
                } footer: {
                    Text("V0 产品参数，不代表人群正常值；可调整并回算对照。")
                }

                if let error = parameters.validationError {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("实验参数")
            .onAppear {
                parameters = store.selectedVersion.parameters
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("恢复默认") {
                        parameters = ExperimentParameters()
                    }
                    .accessibilityIdentifier("parameters.restore")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("重新计算") {
                        store.applyParameters(parameters)
                        dismiss()
                    }
                    .disabled(parameters.validationError != nil)
                    .accessibilityIdentifier("parameters.apply")
                }
            }
        }
    }
}

private struct SliderRow: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var suffix: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text(formattedValue)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range)
        }
    }

    private var formattedValue: String {
        if value < 1, range.upperBound <= 1, suffix.isEmpty { return String(format: "%.3f", value) }
        let rounded = value >= 10 ? String(Int(value.rounded())) : String(format: "%.2f", value)
        return suffix.isEmpty ? rounded : "\(rounded) \(suffix)"
    }
}
