import Foundation

#if targetEnvironment(simulator)
enum DemoData {
    static func make(now: Date, calendar: Calendar) -> HealthDataset {
        let source = DataSource(id: "simulated-watch", name: "模拟 Apple Watch（非真实数据）", isAppleWatch: true)
        let phone = DataSource(id: "simulated-iphone", name: "模拟 iPhone（非真实数据）", isAppleWatch: false)
        var data = HealthDataset(sources: [source, phone], fetchedAt: now, isDemo: true)
        let today = calendar.startOfDay(for: now)
        for offset in -36...0 {
            let day = calendar.date(byAdding: .day, value: offset, to: today)!
            let nightStart = day.addingTimeInterval(3600)
            let nightEnd = day.addingTimeInterval(7 * 3600)
            if nightEnd <= now {
                data.intervals.append(ContextInterval(id: "sleep-\(offset)", start: nightStart, end: nightEnd, sourceID: source.id, kind: .sleep))
            }
            let restingTime = day.addingTimeInterval(11.5 * 3_600)
            if restingTime <= now {
                data.quantities.append(QuantityRecord(id: "rhr-\(offset)", start: restingTime,
                    end: restingTime, sourceID: source.id, kind: .restingHeartRate,
                    value: 61 + sin(Double(offset) * 0.7) * 2))
            }
            for minute in stride(from: 0, to: 1440, by: 6) {
                let date = day.addingTimeInterval(Double(minute * 60))
                guard date <= now else { continue }
                let asleep = minute >= 60 && minute < 420
                let wave = sin(Double(minute) / 90 + Double(offset) * 0.7)
                let bpm = (asleep ? 55.0 : 70.0) + 5 * wave + (offset == 0 && minute > 660 ? 5 : 0)
                // Deliberate afternoon gaps demonstrate absence rather than flat fabricated data.
                if minute < 900 || minute > 960 {
                    data.quantities.append(QuantityRecord(id: "hr-\(offset)-\(minute)", start: date, end: date, sourceID: source.id, kind: .heartRate, value: bpm, motion: .sedentary))
                }
            }
            for hour in [2, 5, 9, 13, 18, 22] {
                let start = day.addingTimeInterval(Double(hour * 3600))
                guard start.addingTimeInterval(65) <= now else { continue }
                let amplitude = 0.025 + 0.012 * (1 + sin(Double(offset + hour) * 0.4))
                var beats = [Beat(offset: 0, precededByGap: false)]
                var elapsed = 0.0
                for i in 1...80 {
                    elapsed += 0.8 + amplitude * (i.isMultiple(of: 2) ? 1 : -1)
                    beats.append(Beat(offset: elapsed, precededByGap: false))
                }
                data.heartbeats.append(HeartbeatRecord(id: "hrv-\(offset)-\(hour)", start: start,
                    end: start.addingTimeInterval(elapsed), sourceID: source.id, beats: beats))
                data.quantities.append(QuantityRecord(id: "sdnn-\(offset)-\(hour)", start: start,
                    end: start.addingTimeInterval(elapsed), sourceID: source.id, kind: .sdnn,
                    value: 30 + Double((hour + offset + 50) % 24)))
            }
        }
        let unmatchedTime = today.addingTimeInterval(3 * 60)
        if unmatchedTime <= now {
            data.quantities.append(QuantityRecord(id: "sdnn-without-series-demo", start: unmatchedTime,
                end: unmatchedTime, sourceID: source.id, kind: .sdnn, value: 42))
        }
        for dayOffset in [-1, 0] {
            let dayStart = calendar.date(byAdding: .day, value: dayOffset, to: today)!
            let movingEnd = dayStart.addingTimeInterval(10.5 * 3_600)
            if movingEnd <= now {
                data.quantities.append(QuantityRecord(id: "phone-movement-demo-\(dayOffset)",
                    start: movingEnd.addingTimeInterval(-10 * 60), end: movingEnd,
                    sourceID: phone.id, kind: .steps, value: 120))
                for minute in [22, 28, 34] {
                    let activeTime = dayStart.addingTimeInterval(10 * 3_600 + Double(minute * 60))
                    guard activeTime <= now else { continue }
                    data.quantities.append(QuantityRecord(id: "watch-active-demo-\(dayOffset)-\(minute)",
                        start: activeTime, end: activeTime, sourceID: source.id,
                        kind: .heartRate, value: 90, motion: .active))
                }
            }
        }
        return data
    }
}
#endif
