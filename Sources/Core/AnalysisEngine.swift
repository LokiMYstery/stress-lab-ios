import Foundation

struct AnalysisEngine {
    static func heartRateTrend(dataset: HealthDataset, sourceID: String, parameters: ExperimentParameters,
                               trend: HeartRateTrendParameters, now: Date, calendar: Calendar) -> HeartRateTrendEvaluation? {
        let context = OptimizedContext(dataset: dataset, sourceID: sourceID, parameters: parameters)
        let start = now.addingTimeInterval(-Double(trend.comparisonMinutes + trend.windowMinutes) * 60)
        guard context.state(at: now) == .awake, context.targetActivityReason(at: now) == nil,
              !context.overlaps(kind: .sleep, range: start..<now),
              !context.workouts.contains(where: {
                  $0.start < now && $0.end.addingTimeInterval(parameters.workoutRecoveryMinutes * 60) >= start
              }) else { return nil }
        let baseline = OptimizedBaseline(hrv: [], heartRateBins: context.heartRateBins(calendar: calendar),
            restingHeartRates: [], parameters: parameters, calendar: calendar)
        let records = context.stationaryTrendRecords(from: start, to: now)
        var evaluation = HeartRateTrendEvaluator.evaluate(records: records, baseline: baseline.hrSummary(before: now, state: .awake),
            parameters: parameters, trend: trend, now: now)
        if sourceID.hasPrefix("ambiguous::") { evaluation?.provisional = true }
        return evaluation
    }

    static let binSeconds: TimeInterval = 6 * 60
    private static let ambiguousSourcePrefix = "ambiguous::"

    static func analyze(
        dataset: HealthDataset,
        sourceID: String,
        parameters: ExperimentParameters,
        version: String,
        day: Date,
        now: Date,
        calendar: Calendar
    ) -> AnalysisResult {
        OptimizedAnalysis(dataset: dataset, sourceID: sourceID, parameters: parameters, version: version, day: day, now: now, calendar: calendar).run()
    }

    static func defaultSourceID(in dataset: HealthDataset) -> String {
        dataset.sources.first(where: { $0.isAppleWatch })?.id ?? dataset.sources.first?.id ?? ""
    }

    static func rmssd(record: HeartbeatRecord, parameters: ExperimentParameters) -> (raw: Double?, filtered: Double?, duration: Double, pairs: Int, rawDuration: Double, rawPairs: Int, reasons: [String]) {
        let beats = record.beats
        guard beats.count >= 3 else { return (nil, nil, 0, 0, 0, 0, ["beats_below_threshold"]) }
        var previous = beats[0].offset
        var rawIntervals: [Double] = []
        var rawDiffs: [Double] = []
        var segment: [Double] = []
        var filteredDiffs: [Double] = []
        var duration = 0.0
        var rawDuration = 0.0
        var rejected = 0

        func flush() {
            guard segment.count >= 2 else {
                segment.removeAll()
                return
            }
            duration += segment.reduce(0, +)
            for index in 1..<segment.count {
                filteredDiffs.append(segment[index] - segment[index - 1])
            }
            segment.removeAll()
        }

        for beat in beats.dropFirst() {
            let interval = beat.offset - previous
            previous = beat.offset
            guard interval.isFinite, interval > 0 else {
                rejected += 1
                flush()
                rawIntervals.removeAll()
                continue
            }
            if beat.precededByGap {
                rejected += 1
                flush()
                rawIntervals.removeAll()
                continue
            }
            if let last = rawIntervals.last { rawDiffs.append(interval - last) }
            rawIntervals.append(interval)
            rawDuration += interval
            let ms = interval * 1000
            if ms >= parameters.minIntervalMS && ms <= parameters.maxIntervalMS {
                segment.append(interval)
            } else {
                rejected += 1
                flush()
            }
        }
        flush()

        var reasons: [String] = []
        if rejected > 0 { reasons.append("rejected_intervals") }
        if duration < parameters.minimumDuration { reasons.append("duration_below_threshold") }
        if filteredDiffs.count < parameters.minimumPairs { reasons.append("pairs_below_threshold") }
        let filtered = duration >= parameters.minimumDuration && filteredDiffs.count >= parameters.minimumPairs ? rmsMilliseconds(filteredDiffs) : nil
        return (rmsMilliseconds(rawDiffs), filtered, duration, filteredDiffs.count, rawDuration, rawDiffs.count, reasons)
    }

    private static func rmsMilliseconds(_ diffs: [Double]) -> Double? {
        guard !diffs.isEmpty else { return nil }
        let value = sqrt(diffs.map { $0 * $0 }.reduce(0, +) / Double(diffs.count)) * 1000
        return value.isFinite ? value : nil
    }
}

private struct OptimizedAnalysis {
    let dataset: HealthDataset
    let sourceID: String
    let parameters: ExperimentParameters
    let version: String
    let day: Date
    let now: Date
    let calendar: Calendar

    private var sourceIsAmbiguous: Bool { sourceID.hasPrefix("ambiguous::") }

    func run() -> AnalysisResult {
        let context = OptimizedContext(dataset: dataset, sourceID: sourceID, parameters: parameters)
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        let measuredHRV = dataset.heartbeats
            .filter { $0.sourceID == sourceID && $0.end <= now }
            .map { hrvPoint(for: $0, context: context) }
            .sorted { $0.date < $1.date }
        let baseline = OptimizedBaseline(hrv: measuredHRV, heartRateBins: context.heartRateBins(calendar: calendar), restingHeartRates: context.restingHeartRates, parameters: parameters, calendar: calendar)
        let allHRV = measuredHRV.map { point in
            var point = point
            let reference = baseline.hrvSummary(before: point.date, state: point.state)
            let origin: HRVAssessmentOrigin = reference.ready && !sourceIsAmbiguous ? .personal
                : reference.median == nil ? .default : .provisional
            let score: Int
            if let rmssd = point.rmssd, rmssd > 0 {
                let median = reference.median ?? log(parameters.defaultRMSSDMS)
                let scale = reference.scale ?? parameters.defaultHRVScale
                let z = (median - log(rmssd)) / max(scale, parameters.hrvScaleFloor)
                score = parameters.hrvCalibratedScore(for: z) ?? 50
            } else {
                score = 50
            }
            point.assessment = HRVAssessment(score: score, origin: origin, baseline: reference)
            return point
        }
        let dayHRV = allHRV.filter { $0.date >= dayStart && $0.date < dayEnd }
        let sleep = context.intervals(kind: .sleep, overlapping: dayStart..<dayEnd)
        let pressureEnd = pressureEndDate(dayStart: dayStart, dayEnd: dayEnd)

        var pressure: [PressurePoint] = []
        var cursor = dayStart
        while cursor < dayEnd && cursor <= pressureEnd {
            pressure.append(point(at: cursor, context: context, hrv: allHRV, baseline: baseline, defaultCurrent: false))
            guard let next = calendar.date(byAdding: .second, value: Int(AnalysisEngine.binSeconds), to: cursor), next > cursor else { break }
            cursor = next
        }

        let current = point(at: now, context: context, hrv: allHRV, baseline: baseline, defaultCurrent: true)
        guard parameters.mappingVersion >= 2 else {
            return AnalysisResult(hrv: dayHRV, pressure: pressure, current: current, sleep: sleep)
        }

        let recent: [PressurePoint]
        let lookback = max(30, parameters.redCooldownMinutes) * 60
        if calendar.isDate(dayStart, inSameDayAs: now) {
            recent = pressure.filter { $0.date < now && $0.date >= now.addingTimeInterval(-lookback) }
        } else {
            let currentDayStart = calendar.startOfDay(for: now)
            let first = max(currentDayStart, now.addingTimeInterval(-lookback))
            let elapsed = first.timeIntervalSince(currentDayStart)
            var cursor = currentDayStart.addingTimeInterval(floor(elapsed / AnalysisEngine.binSeconds) * AnalysisEngine.binSeconds)
            var preceding: [PressurePoint] = []
            while cursor < now {
                preceding.append(point(at: cursor, context: context, hrv: allHRV, baseline: baseline, defaultCurrent: false))
                cursor = cursor.addingTimeInterval(AnalysisEngine.binSeconds)
            }
            recent = preceding
        }
        let calibrated = markAcuteEvents(pressure)
        let calibratedCurrent = markAcuteEvents(recent + [current]).last ?? current
        return AnalysisResult(hrv: dayHRV, pressure: calibrated, current: calibratedCurrent, sleep: sleep)
    }

    private func markAcuteEvents(_ points: [PressurePoint]) -> [PressurePoint] {
        var marked = points
        var lastRedDate: Date?
        for index in marked.indices {
            guard let score = points[index].score, score >= 81 else { continue }
            let prior = points[..<index].compactMap { point -> (Date, Double)? in
                guard point.date >= points[index].date.addingTimeInterval(-30 * 60),
                      point.date < points[index].date, let value = point.score else { return nil }
                return (point.date, Double(value))
            }
            let center = prior.map(\.1).median()
            let latest = prior.last?.1
            let sharpRise = prior.count >= 2 && center != nil && latest != nil &&
                Double(score) - center! >= parameters.redJumpThreshold &&
                Double(score) - latest! >= max(12, parameters.redJumpThreshold * 0.75)
            let cooledDown = lastRedDate.map {
                points[index].date.timeIntervalSince($0) >= parameters.redCooldownMinutes * 60
            } ?? true
            let justMeasuredHRV = parameters.mappingVersion >= 3 && points[index].hrvWeight >= 0.999 &&
                points[index].hrvDate.map {
                    points[index].date >= $0 && points[index].date.timeIntervalSince($0) <= AnalysisEngine.binSeconds
                } == true
            if justMeasuredHRV || (sharpRise && cooledDown) {
                marked[index].reasons.append(justMeasuredHRV ? "fresh_hrv_score_anchor" : "acute_rise_confirmed")
                lastRedDate = points[index].date
            } else {
                marked[index].score = 80
                marked[index].reasons.append("acute_red_suppressed")
            }
        }
        return marked
    }

    private func pressureEndDate(dayStart: Date, dayEnd: Date) -> Date {
        let nowDay = calendar.startOfDay(for: now)
        if dayStart < nowDay { return dayEnd.addingTimeInterval(-0.001) }
        if dayStart == nowDay { return min(dayEnd.addingTimeInterval(-0.001), now) }
        return dayStart.addingTimeInterval(-1)
    }

    private func hrvPoint(for record: HeartbeatRecord, context: OptimizedContext) -> HRVPoint {
        let computed = AnalysisEngine.rmssd(record: record, parameters: parameters)
        let presentedRMSSD = parameters.hrvFilterEnabled ? computed.filtered : computed.raw
        let malformed = record.end < record.start
        let range = malformed ? record.end..<record.end : record.start..<record.end
        let excluded = context.overlaps(kind: .workout, range: range) || context.overlaps(kind: .mindfulness, range: range)
        var reasons = parameters.hrvFilterEnabled ? computed.reasons : ["quality_filter_disabled"]
        if !parameters.hrvFilterEnabled && computed.filtered == nil && computed.raw != nil {
            reasons.append("strict_gate_would_exclude")
        }
        if malformed { reasons.append("malformed_record") }
        if excluded { reasons.append("context_excluded") }
        if sourceIsAmbiguous { reasons.append("ambiguous_source") }
        return HRVPoint(id: record.id, date: record.end, start: record.start, sourceID: record.sourceID, rawRMSSD: computed.raw, rmssd: presentedRMSSD, validDuration: parameters.hrvFilterEnabled ? computed.duration : computed.rawDuration, pairCount: parameters.hrvFilterEnabled ? computed.pairs : computed.rawPairs, state: context.state(at: record.end), exclusionReasons: Array(Set(reasons)).sorted(), baselineEligible: (presentedRMSSD ?? 0) > 0 && !excluded && !malformed)
    }

    private func point(at date: Date, context: OptimizedContext, hrv: [HRVPoint], baseline: OptimizedBaseline, defaultCurrent: Bool) -> PressurePoint {
        let state = context.state(at: date)
        let activityReason = context.targetActivityReason(at: date)
        let targetBlocked = activityReason != nil
        let hrvBase = baseline.hrvSummary(before: date, state: state)
        let hrBase = baseline.hrSummary(before: date, state: state)
        let restingBase = baseline.restingHRSummary(before: date)
        let hrvSignal = targetBlocked ? nil : latestHRV(at: date, state: state, hrv: hrv)
        let hrSignal = targetBlocked ? nil : context.recentHeartRate(at: date, state: state)
        let restingSignal = parameters.mappingVersion >= 1 && !targetBlocked ? context.recentRestingHeartRate(at: date) : nil
        var reasons: [String] = []
        if let activityReason { reasons.append(activityReason) }
        if sourceIsAmbiguous { reasons.append("ambiguous_source") }

        let hrvZ: Double?
        if let hrvSignal, let rmssd = hrvSignal.point.rmssd, rmssd > 0 {
            let median = hrvBase.median ?? log(parameters.defaultRMSSDMS)
            let scale = hrvBase.scale ?? parameters.defaultHRVScale
            hrvZ = (median - log(rmssd)) / max(scale, parameters.hrvScaleFloor)
            if hrvBase.median == nil { reasons.append("hrv_default_reference") }
            else if !hrvBase.ready { reasons.append("hrv_baseline_provisional") }
        } else {
            hrvZ = nil
            reasons.append(hrvBase.ready ? "no_fresh_same_state_rmssd" : "hrv_baseline_insufficient")
        }

        let hrZ: Double?
        if let hrSignal {
            let median = hrBase.median ?? parameters.defaultHeartRateBPM
            let scale = hrBase.scale ?? parameters.defaultHeartRateScale
            hrZ = (hrSignal.value - median) / max(scale, parameters.hrScaleFloor)
            if hrBase.median == nil { reasons.append("hr_default_reference") }
            else if !hrBase.ready { reasons.append("hr_baseline_provisional") }
            if hrSignal.motionUnknown { reasons.append("motion_unknown") }
        } else {
            hrZ = nil
            reasons.append(hrBase.ready ? "no_fresh_stationary_hr" : "hr_baseline_insufficient")
        }

        let restingZ: Double?
        if let restingSignal, let median = restingBase.median, let scale = restingBase.scale {
            restingZ = (restingSignal.value - median) / max(scale, parameters.restingHRScaleFloor)
            reasons.append(restingBase.ready ? "rhr_corrob" : "rhr_baseline_provisional")
        } else {
            restingZ = nil
        }
        let heartSignalZ: Double?
        switch (hrZ, restingZ) {
        case let (ordinary?, resting?):
            heartSignalZ = (1 - parameters.restingHRWeight) * ordinary + parameters.restingHRWeight * resting
        case let (ordinary?, nil):
            heartSignalZ = ordinary
        case let (nil, resting?):
            heartSignalZ = resting
            reasons.append("rhr_only")
        case (nil, nil):
            heartSignalZ = nil
        }

        let weight = hrvSignal?.weight ?? 0
        let origin: EstimateOrigin
        let score: Int?
        if parameters.mappingVersion >= 3 {
            let hrvScore = hrvZ.flatMap { parameters.hrvCalibratedScore(for: $0) }
            let heartScore = heartSignalZ.flatMap { parameters.mappedScore(for: $0) }
            switch (hrvScore, heartScore) {
            case let (h?, r?):
                score = Int((weight * Double(h) + (1 - weight) * Double(r)).rounded())
                origin = weight > 0.95 ? .hrv : .blended
            case let (h?, nil):
                score = h
                origin = .hrv
                reasons.append("single_signal_hrv")
            case let (nil, r?):
                score = r
                origin = .heartRate
                reasons.append("single_signal_hr")
            default:
                score = defaultCurrent && !targetBlocked ? 50 : nil
                origin = .default
            }
        } else {
            switch (hrvZ, heartSignalZ) {
            case let (h?, r?):
                score = parameters.mappedScore(for: h * weight + r * (1 - weight))
                origin = weight > 0.95 ? .hrv : .blended
            case let (h?, nil):
                score = parameters.mappedScore(for: h)
                origin = .hrv
                reasons.append("single_signal_hrv")
            case let (nil, r?):
                score = parameters.mappedScore(for: r)
                origin = .heartRate
                reasons.append("single_signal_hr")
            default:
                score = defaultCurrent && !targetBlocked ? 50 : nil
                origin = .default
            }
        }

        var output = PressurePoint(date: date, score: score, origin: origin, state: state, hrvDate: hrvSignal?.point.date, heartRateDate: hrSignal?.date, rmssd: hrvSignal?.point.rmssd, heartRate: hrSignal?.value, hrvWeight: score == nil ? 0 : weight, hrvBaseline: hrvBase, heartRateBaseline: hrBase, reasons: Array(Set(reasons)).sorted(), algorithmVersion: version)
        output.restingHeartRate = restingSignal?.value
        output.restingHeartRateDate = restingSignal?.date
        output.restingHeartRateBaseline = restingBase
        return output
    }

    private func latestHRV(at date: Date, state: BodyState, hrv: [HRVPoint]) -> (point: HRVPoint, weight: Double)? {
        let lifetime = parameters.hrvLifetimeHours * 3_600
        guard lifetime > 0 else { return nil }
        guard let point = hrv.last(where: { $0.state == state && $0.baselineEligible && $0.rmssd != nil && $0.date > date.addingTimeInterval(-lifetime) && $0.date <= date }) else { return nil }
        let age = max(0, date.timeIntervalSince(point.date))
        let weight: Double
        if parameters.mappingVersion >= 3, age <= AnalysisEngine.binSeconds {
            weight = 1
        } else if parameters.mappingVersion >= 3 {
            weight = max(0, min(1, 1 - (age - AnalysisEngine.binSeconds) / (lifetime - AnalysisEngine.binSeconds)))
        } else {
            weight = max(0, min(1, 1 - age / lifetime))
        }
        guard weight > 0 else { return nil }
        return (point, weight)
    }
}

private final class OptimizedBaseline {
    private let hrvDaily: [BodyState: [Date: [Double]]]
    private let hrDaily: [BodyState: [Date: [Double]]]
    private let restingHRDaily: [Date: [Double]]
    private let parameters: ExperimentParameters
    private let calendar: Calendar
    private var hrvCache: [CacheKey: BaselineSummary] = [:]
    private var hrCache: [CacheKey: BaselineSummary] = [:]
    private var restingHRCache: [Date: BaselineSummary] = [:]

    init(hrv: [HRVPoint], heartRateBins: [OptimizedHeartRateBin], restingHeartRates: [QuantityRecord], parameters: ExperimentParameters, calendar: Calendar) {
        self.parameters = parameters
        self.calendar = calendar
        var hrvDaily: [BodyState: [Date: [Double]]] = [.awake: [:], .asleep: [:]]
        for point in hrv where point.baselineEligible {
            guard let rmssd = point.rmssd, rmssd > 0 else { continue }
            hrvDaily[point.state, default: [:]][calendar.startOfDay(for: point.date), default: []].append(log(rmssd))
        }
        self.hrvDaily = hrvDaily

        var hrDaily: [BodyState: [Date: [Double]]] = [.awake: [:], .asleep: [:]]
        for bin in heartRateBins {
            hrDaily[bin.state, default: [:]][calendar.startOfDay(for: bin.date), default: []].append(bin.value)
        }
        self.hrDaily = hrDaily

        var restingHRDaily: [Date: [Double]] = [:]
        for sample in restingHeartRates {
            restingHRDaily[calendar.startOfDay(for: sample.end), default: []].append(sample.value)
        }
        self.restingHRDaily = restingHRDaily
    }

    func hrvSummary(before target: Date, state: BodyState) -> BaselineSummary {
        let key = CacheKey(day: calendar.startOfDay(for: target), state: state)
        if let cached = hrvCache[key] { return cached }
        let value = summary(daily: hrvDaily[state] ?? [:], before: target, minimumSamples: parameters.minimumHRVRecords, scaleFloor: parameters.hrvScaleFloor)
        hrvCache[key] = value
        return value
    }

    func hrSummary(before target: Date, state: BodyState) -> BaselineSummary {
        let key = CacheKey(day: calendar.startOfDay(for: target), state: state)
        if let cached = hrCache[key] { return cached }
        let value = summary(daily: hrDaily[state] ?? [:], before: target, minimumSamples: parameters.minimumHRBins, scaleFloor: parameters.hrScaleFloor)
        hrCache[key] = value
        return value
    }

    func restingHRSummary(before target: Date) -> BaselineSummary {
        let day = calendar.startOfDay(for: target)
        if let cached = restingHRCache[day] { return cached }
        let value = summary(daily: restingHRDaily, before: target,
                            minimumSamples: parameters.minimumDays, scaleFloor: parameters.restingHRScaleFloor)
        restingHRCache[day] = value
        return value
    }

    private func summary(daily: [Date: [Double]], before target: Date, minimumSamples: Int, scaleFloor: Double) -> BaselineSummary {
        let targetDay = calendar.startOfDay(for: target)
        let start = calendar.date(byAdding: .day, value: -parameters.baselineDays, to: targetDay) ?? targetDay.addingTimeInterval(-Double(parameters.baselineDays) * 86_400)
        let eligible = daily.filter { day, values in day >= start && day < targetDay && !values.isEmpty }
        let medians = eligible.values.compactMap { $0.median() }
        let samples = eligible.values.reduce(0) { $0 + $1.count }
        guard let median = medians.median() else {
            return BaselineSummary(median: nil, scale: nil, days: eligible.count, samples: samples, ready: false)
        }
        let mad = medians.map { abs($0 - median) }.median() ?? 0
        return BaselineSummary(median: median, scale: max(mad * 1.4826, scaleFloor), days: eligible.count, samples: samples, ready: eligible.count >= parameters.minimumDays && samples >= minimumSamples)
    }

    private struct CacheKey: Hashable {
        var day: Date
        var state: BodyState
    }
}

private struct OptimizedContext {
    let sourceID: String
    let parameters: ExperimentParameters
    let intervals: [ContextInterval]
    let heartRates: [QuantityRecord]
    let restingHeartRates: [QuantityRecord]
    let steps: [QuantityRecord]
    let workouts: [ContextInterval]
    let activeHeartRates: [QuantityRecord]

    init(dataset: HealthDataset, sourceID: String, parameters: ExperimentParameters) {
        self.sourceID = sourceID
        self.parameters = parameters
        self.intervals = dataset.intervals.filter { $0.sourceID == sourceID }
        let quantities = dataset.quantities.filter { $0.sourceID == sourceID }
        self.heartRates = quantities.filter { $0.kind == .heartRate && $0.value.isFinite && $0.value > 0 }
        self.restingHeartRates = quantities.filter { $0.kind == .restingHeartRate && $0.value.isFinite && $0.value > 0 }
        self.steps = dataset.quantities.filter { $0.kind == .steps && $0.value.isFinite && $0.value > 0 }
        self.workouts = dataset.intervals.filter { $0.kind == .workout }
        let watchIDs = Set(dataset.sources.filter(\.isAppleWatch).map(\.id))
        self.activeHeartRates = dataset.quantities.filter {
            $0.kind == .heartRate && $0.motion == .active && watchIDs.contains($0.sourceID)
        }
    }

    func intervals(kind: IntervalKind, overlapping range: Range<Date>) -> [ContextInterval] {
        intervals.filter { $0.kind == kind && overlaps($0, range) }
    }

    func state(at date: Date) -> BodyState {
        if intervals.contains(where: { $0.kind == .awake && contains($0, date) }) { return .awake }
        return intervals.contains(where: { $0.kind == .sleep && contains($0, date) }) ? .asleep : .awake
    }

    func targetActivityReason(at date: Date) -> String? {
        if workouts.contains(where: { date >= $0.start && date <= $0.end.addingTimeInterval(parameters.workoutRecoveryMinutes * 60) }) {
            return "target_activity_excluded"
        }
        if activeHeartRates.contains(where: { $0.end <= date && $0.end >= date.addingTimeInterval(-5 * 60) }) {
            return "frequent_movement"
        }
        guard parameters.useStepMovement else { return nil }
        let start = date.addingTimeInterval(-parameters.movementStepWindowMinutes * 60)
        var stepsBySource: [String: Double] = [:]
        for sample in steps {
            let duration = sample.end.timeIntervalSince(sample.start)
            guard duration >= 0, duration <= 30 * 60, sample.start <= date, sample.end >= start else { continue }
            let contribution: Double
            if duration == 0 {
                contribution = sample.end >= start && sample.end <= date ? sample.value : 0
            } else {
                let overlap = max(0, min(sample.end, date).timeIntervalSince(max(sample.start, start)))
                contribution = sample.value * overlap / duration
            }
            stepsBySource[sample.sourceID, default: 0] += contribution
        }
        return (stepsBySource.values.max() ?? 0) >= parameters.movementStepThreshold ? "frequent_movement" : nil
    }

    func overlaps(kind: IntervalKind, range: Range<Date>) -> Bool {
        intervals.contains { $0.kind == kind && overlaps($0, range) }
    }

    func recentHeartRate(at date: Date, state: BodyState) -> (date: Date, value: Double, motionUnknown: Bool)? {
        let start = date.addingTimeInterval(-parameters.heartRateFreshMinutes * 60)
        let records = heartRates.filter { $0.end >= start && $0.end <= date && sampleState($0) == state && validHeartRate($0, state: state) }
        let knownStill = records.filter { $0.motion == .sedentary }
        let selected = knownStill.isEmpty ? records : knownStill
        guard let median = selected.map(\.value).median() else { return nil }
        return (selected.map(\.end).max() ?? date, median, knownStill.isEmpty)
    }

    func stationaryTrendRecords(from start: Date, to end: Date) -> [QuantityRecord] {
        heartRates.filter {
            $0.end > start && $0.end <= end && $0.motion == .sedentary &&
            sampleState($0) == .awake && validHeartRate($0, state: .awake)
        }
    }

    func recentRestingHeartRate(at date: Date) -> (date: Date, value: Double)? {
        guard let latest = restingHeartRates.filter({ $0.end <= date && $0.end >= date.addingTimeInterval(-36 * 3_600) })
            .max(by: { $0.end < $1.end }) else { return nil }
        return (latest.end, latest.value)
    }

    func heartRateBins(calendar: Calendar) -> [OptimizedHeartRateBin] {
        var grouped: [OptimizedHeartRateBinKey: [QuantityRecord]] = [:]
        for record in heartRates {
            let state = sampleState(record)
            guard validHeartRate(record, state: state) else { continue }
            // A sample is not known until it has completed; bucket by end to avoid midnight look-ahead.
            let day = calendar.startOfDay(for: record.end)
            let bin = day.addingTimeInterval(floor(max(0, record.end.timeIntervalSince(day)) / AnalysisEngine.binSeconds) * AnalysisEngine.binSeconds)
            grouped[OptimizedHeartRateBinKey(day: day, bin: bin, state: state), default: []].append(record)
        }
        return grouped.compactMap { key, records in
            let knownStill = records.filter { $0.motion == .sedentary }
            let selected = knownStill.isEmpty ? records : knownStill
            guard let median = selected.map(\.value).median() else { return nil }
            return OptimizedHeartRateBin(date: key.bin, state: key.state, value: median)
        }
    }

    private func validHeartRate(_ record: QuantityRecord, state: BodyState) -> Bool {
        guard record.end >= record.start else { return false }
        let finalInstant = record.end > record.start ? record.end.addingTimeInterval(-0.001) : record.end
        guard self.state(at: record.start) == self.state(at: finalInstant) else { return false }
        guard !workouts.contains(where: {
            record.start <= $0.end.addingTimeInterval(parameters.workoutRecoveryMinutes * 60) && record.end >= $0.start
        }) else { return false }
        guard targetActivityReason(at: record.midpoint) == nil else { return false }
        switch state {
        case .awake:
            return record.motion != .active && sampleState(record) == .awake
        case .asleep:
            return record.motion != .active && sampleState(record) == .asleep
        }
    }

    private func sampleState(_ record: QuantityRecord) -> BodyState {
        state(at: record.midpoint)
    }

    private func contains(_ interval: ContextInterval, _ date: Date) -> Bool {
        date >= interval.start && date < interval.end
    }

    private func overlaps(_ interval: ContextInterval, _ range: Range<Date>) -> Bool {
        if range.lowerBound == range.upperBound { return contains(interval, range.lowerBound) }
        return interval.start < range.upperBound && interval.end > range.lowerBound
    }

    private func overlaps(_ record: QuantityRecord, _ range: Range<Date>) -> Bool {
        if range.lowerBound == range.upperBound { return range.lowerBound >= record.start && range.lowerBound < record.end }
        return record.start < range.upperBound && record.end > range.lowerBound
    }
}

private struct OptimizedHeartRateBin {
    var date: Date
    var state: BodyState
    var value: Double
}

private struct OptimizedHeartRateBinKey: Hashable {
    var day: Date
    var bin: Date
    var state: BodyState
}

private extension BaselineSummary {
    static var empty: BaselineSummary {
        BaselineSummary(median: nil, scale: nil, days: 0, samples: 0, ready: false)
    }
}

extension Array where Element == Double {
    func median() -> Double? {
        let values = filter { $0.isFinite }.sorted()
        guard !values.isEmpty else { return nil }
        let middle = values.count / 2
        if values.count.isMultiple(of: 2) {
            return (values[middle - 1] + values[middle]) / 2
        }
        return values[middle]
    }
}

private extension QuantityRecord {
    var midpoint: Date {
        if start == end { return start }
        return start.addingTimeInterval(end.timeIntervalSince(start) / 2)
    }
}
