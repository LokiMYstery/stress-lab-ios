import SwiftUI

enum StressLabStyle {
    static let background = Color(red: 0.965, green: 0.975, blue: 0.968)
    static let card = Color.white
    static let mint = Color(red: 0.43, green: 0.78, blue: 0.60)
    static let purple = Color(red: 0.50, green: 0.42, blue: 0.82)
    static let blue = Color(red: 0.43, green: 0.55, blue: 0.84)
    static let orange = Color(red: 0.94, green: 0.58, blue: 0.35)
    static let red = Color(red: 0.86, green: 0.28, blue: 0.30)
    static let muted = Color.secondary
    static let radius: CGFloat = 18
}

struct LabCard<Content: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(16)
        .background(StressLabStyle.card)
        .clipShape(RoundedRectangle(cornerRadius: StressLabStyle.radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: StressLabStyle.radius, style: .continuous)
                .stroke(Color.black.opacity(0.04), lineWidth: 1)
        }
    }
}

struct MetricPill: View {
    var label: String
    var value: String
    var tint: Color = StressLabStyle.mint

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .accessibilityIdentifier("metric.\(label)")
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(tint.opacity(0.11))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

enum LabFormat {
    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "M月d日 EEE"
        return formatter
    }()

    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static let dateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    static func optionalTime(_ date: Date?) -> String {
        guard let date else { return "无" }
        return dateTime.string(from: date)
    }

    static func ms(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "无" }
        return String(format: "%.1f ms", value)
    }

    static func bpm(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "无" }
        return String(format: "%.1f bpm", value)
    }
}

extension EstimateOrigin {
    var label: String {
        switch self {
        case .hrv: return "RMSSD 支撑"
        case .blended: return "RMSSD + 心率"
        case .heartRate: return "心率估算"
        case .default: return "默认参考"
        }
    }

    var tint: Color {
        switch self {
        case .hrv: return StressLabStyle.mint
        case .blended: return StressLabStyle.purple
        case .heartRate: return StressLabStyle.blue
        case .default: return .gray
        }
    }
}

extension BodyState {
    var label: String {
        switch self {
        case .awake: return "清醒"
        case .asleep: return "睡眠"
        }
    }
}

extension HRVPoint {
    var readableReasons: [String] {
        exclusionReasons.map { reason in
            switch reason {
            case "quality_filter_disabled": return "实验版已关闭 RMSSD 质量门槛"
            case "strict_gate_would_exclude": return "严格模式原本会隐藏此点"
            case "ambiguous_source": return "设备来源待核对"
            case "context_excluded": return "运动或正念时段不进入日常基线"
            case "malformed_record": return "测量时段异常"
            case "rejected_intervals": return "部分心跳间隔未通过严格模式检查"
            case "duration_below_threshold": return "有效时长不足"
            case "pairs_below_threshold", "beats_below_threshold": return "相邻心跳间隔不足，无法计算"
            default: return reason
            }
        }
    }
}
