import Foundation
import HealthKit

@MainActor
final class HealthKitReader {
    var onChange: ((String, Error?) async -> Void)?

    private let store: HKHealthStore
    private var anchors: [SampleKey: HKQueryAnchor] = [:]
    private var observers: [HKObserverQuery] = []
    private var generation = 0

    init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    func requestReadAccess() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitReaderError.healthDataUnavailable
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.requestAuthorization(toShare: [], read: Self.readTypes) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: HealthKitReaderError.authorizationNotCompleted)
                }
            }
        }

        startObserving()
    }

    func refresh(existing: HealthDataset, now: Date) async throws -> HealthDataset {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitReaderError.healthDataUnavailable
        }

        startObserving()

        let refreshGeneration = generation
        let window = RefreshWindow(now: now)
        var working = existing.pruned(to: window.start, now: now)
        var nextAnchors = anchors
        var sourceAccumulator = SourceAccumulator(existing: working.sources)

        let heartbeatDelta = try await fetchHeartbeatDelta(window: window, anchor: nextAnchors[.heartbeat])
        nextAnchors[.heartbeat] = heartbeatDelta.anchor
        sourceAccumulator.add(heartbeatDelta.sources)
        working.applyHeartbeatDelta(heartbeatDelta, window: window)

        for kind in QuantityKind.allReadableHealthKitKinds {
            let delta = try await fetchQuantityDelta(kind: kind, window: window, anchor: nextAnchors[.quantity(kind)])
            nextAnchors[.quantity(kind)] = delta.anchor
            sourceAccumulator.add(delta.sources)
            working.applyQuantityDelta(delta, kind: kind, window: window)
        }

        for kind in IntervalKind.allReadableHealthKitKinds {
            let delta = try await fetchIntervalDelta(kind: kind, window: window, anchor: nextAnchors[.interval(kind)])
            nextAnchors[.interval(kind)] = delta.anchor
            sourceAccumulator.add(delta.sources)
            working.applyIntervalDelta(delta, kind: kind, window: window)
        }

        working.sources = sourceAccumulator.sources.sorted { lhs, rhs in
            if lhs.isAppleWatch != rhs.isAppleWatch { return lhs.isAppleWatch && !rhs.isAppleWatch }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        working.fetchedAt = now
        working.isDemo = false

        guard refreshGeneration == generation else {
            throw HealthKitReaderError.staleRefreshDiscarded
        }
        anchors = nextAnchors
        return working
    }

    func reset() {
        generation += 1
        anchors.removeAll()
    }

    func stopObserving() {
        observers.forEach(store.stop)
        observers.removeAll()
    }

    func configureBackgroundDelivery(enabled: Bool) async -> String {
        let types: [HKSampleType] = [HKSeriesType.heartbeat(), Self.quantityType(.heartRateVariabilitySDNN), Self.quantityType(.heartRate), HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!]
        var failures: [String] = []
        for type in types {
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let completion: @Sendable (Bool, Error?) -> Void = { success, error in
                        if let error { continuation.resume(throwing: error) }
                        else if success { continuation.resume() }
                        else { continuation.resume(throwing: HealthKitReaderError.authorizationNotCompleted) }
                    }
                    if enabled { store.enableBackgroundDelivery(for: type, frequency: .immediate, withCompletion: completion) }
                    else { store.disableBackgroundDelivery(for: type, withCompletion: completion) }
                }
            } catch { failures.append("\(type.identifier)：\(error.localizedDescription)") }
        }
        if !failures.isEmpty { return "后台接收部分注册失败：" + failures.joined(separator: "；") }
        return enabled ? "已注册 HRV / 心率 / 睡眠后台接收（由 iOS 调度）" : "未开启后台接收"
    }

    func startObserving() {
        guard observers.isEmpty, HKHealthStore.isHealthDataAvailable() else { return }
        let types = Self.readTypes.compactMap { $0 as? HKSampleType }
            .sorted { $0.identifier < $1.identifier }
        observers = types.map { sampleType in
            let query = HKObserverQuery(sampleType: sampleType, predicate: nil) { [weak self] _, completion, error in
                Task { @MainActor in
                    // HealthKit's background budget ends when this completion is called.
                    // Await reading, calculating and queuing the notification first.
                    defer { completion() }
                    await self?.onChange?(sampleType.identifier, error)
                }
            }
            store.execute(query)
            return query
        }
    }
}

private extension HealthKitReader {
    static var readTypes: Set<HKObjectType> {
        [
            HKSeriesType.heartbeat(),
            quantityType(.heartRate),
            quantityType(.heartRateVariabilitySDNN),
            quantityType(.restingHeartRate),
            quantityType(.stepCount),
            HKObjectType.workoutType(),
            HKObjectType.categoryType(forIdentifier: .sleepAnalysis),
            HKObjectType.categoryType(forIdentifier: .mindfulSession)
        ]
        .compactMap { $0 }
        .reduce(into: Set<HKObjectType>()) { $0.insert($1) }
    }

    static func quantityType(_ identifier: HKQuantityTypeIdentifier) -> HKQuantityType {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else {
            preconditionFailure("HealthKit quantity type \(identifier.rawValue) is unavailable")
        }
        return type
    }

    func fetchHeartbeatDelta(window: RefreshWindow, anchor: HKQueryAnchor?) async throws -> HeartbeatDelta {
        let type = HKSeriesType.heartbeat()
        let predicate = HKQuery.predicateForSamples(withStart: window.start, end: window.end, options: [.strictEndDate])

        let result = try await anchoredObjects(type: type, predicate: predicate, anchor: anchor)
        let samples = result.samples.compactMap { $0 as? HKHeartbeatSeriesSample }
        var records: [HeartbeatRecord] = []
        var sources: [DataSource] = []

        for sample in samples {
            let beats = try await heartbeatBeats(for: sample)
            let record = HeartbeatRecord(
                id: sample.uuid.uuidString,
                start: sample.startDate,
                end: sample.endDate,
                sourceID: sample.sourceID,
                beats: beats
            )
            records.append(record)
            sources.append(sample.dataSource)
        }

        return HeartbeatDelta(
            records: records,
            deletedIDs: result.deletedIDs,
            sources: sources,
            anchor: result.anchor,
            isFullScan: anchor == nil
        )
    }

    func heartbeatBeats(for sample: HKHeartbeatSeriesSample) async throws -> [Beat] {
        var beats: [Beat] = []
        let descriptor = HKHeartbeatSeriesQueryDescriptor(sample)
        for try await heartbeat in descriptor.results(for: store) {
            beats.append(
                Beat(
                    offset: heartbeat.timeIntervalSinceStart,
                    precededByGap: heartbeat.precededByGap
                )
            )
        }
        return beats
    }

    func fetchQuantityDelta(kind: QuantityKind, window: RefreshWindow, anchor: HKQueryAnchor?) async throws -> QuantityDelta {
        let type = Self.quantityType(kind.healthKitIdentifier)
        let predicate = HKQuery.predicateForSamples(withStart: window.start, end: window.end, options: [.strictEndDate])
        let result = try await anchoredObjects(type: type, predicate: predicate, anchor: anchor)
        let records = result.samples.compactMap { sample -> QuantityRecord? in
            guard let quantitySample = sample as? HKQuantitySample else { return nil }
            return QuantityRecord(
                id: quantitySample.uuid.uuidString,
                start: quantitySample.startDate,
                end: quantitySample.endDate,
                sourceID: quantitySample.sourceID,
                kind: kind,
                value: quantitySample.quantity.doubleValue(for: kind.unit),
                motion: kind == .heartRate ? MotionContext(metadata: quantitySample.metadata) : .unknown
            )
        }

        return QuantityDelta(
            records: records,
            deletedIDs: result.deletedIDs,
            sources: result.samples.map(\.dataSource),
            anchor: result.anchor,
            isFullScan: anchor == nil
        )
    }

    func fetchIntervalDelta(kind: IntervalKind, window: RefreshWindow, anchor: HKQueryAnchor?) async throws -> IntervalDelta {
        let type = kind.sampleType
        let predicate = HKQuery.predicateForSamples(withStart: window.start, end: window.end, options: [.strictEndDate])
        let result = try await anchoredObjects(type: type, predicate: predicate, anchor: anchor)
        let intervals = result.samples.flatMap { sample -> [ContextInterval] in
            switch kind {
            case .sleep, .awake:
                guard let category = sample as? HKCategorySample else { return [] }
                return category.sleepIntervals(sourceID: category.sourceID)
            case .workout:
                guard sample is HKWorkout else { return [] }
                return [
                    ContextInterval(
                        id: sample.uuid.uuidString,
                        start: sample.startDate,
                        end: sample.endDate,
                        sourceID: sample.sourceID,
                        kind: .workout
                    )
                ]
            case .mindfulness:
                guard let category = sample as? HKCategorySample else { return [] }
                return [
                    ContextInterval(
                        id: category.uuid.uuidString,
                        start: category.startDate,
                        end: category.endDate,
                        sourceID: category.sourceID,
                        kind: .mindfulness
                    )
                ]
            }
        }

        return IntervalDelta(
            intervals: intervals,
            deletedIDs: result.deletedIDs,
            sources: result.samples.map(\.dataSource),
            anchor: result.anchor,
            isFullScan: anchor == nil
        )
    }

    func anchoredObjects(type: HKSampleType, predicate: NSPredicate, anchor: HKQueryAnchor?) async throws -> AnchoredResult {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: type,
                predicate: predicate,
                anchor: anchor,
                limit: HKObjectQueryNoLimit
            ) { _, samples, deletedObjects, newAnchor, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume(
                    returning: AnchoredResult(
                        samples: samples ?? [],
                        deletedIDs: (deletedObjects ?? []).map { $0.uuid.uuidString },
                        anchor: newAnchor ?? anchor
                    )
                )
            }
            store.execute(query)
        }
    }
}

enum HealthKitReaderError: LocalizedError {
    case healthDataUnavailable
    case authorizationNotCompleted
    case staleRefreshDiscarded

    var errorDescription: String? {
        switch self {
        case .healthDataUnavailable:
            return "HealthKit is not available on this device."
        case .authorizationNotCompleted:
            return "HealthKit authorization did not complete."
        case .staleRefreshDiscarded:
            return "A HealthKit refresh completed after local data was reset and was discarded."
        }
    }
}

private enum SampleKey: Hashable {
    case heartbeat
    case quantity(QuantityKind)
    case interval(IntervalKind)
}

private struct RefreshWindow {
    var start: Date
    var end: Date

    init(now: Date, calendar: Calendar = .autoupdatingCurrent) {
        end = now
        let today = calendar.startOfDay(for: now)
        start = calendar.date(byAdding: .day, value: -36, to: today) ?? now.addingTimeInterval(-36 * 24 * 60 * 60)
    }
}

private struct AnchoredResult {
    var samples: [HKSample]
    var deletedIDs: [String]
    var anchor: HKQueryAnchor?
}

private struct HeartbeatDelta {
    var records: [HeartbeatRecord]
    var deletedIDs: [String]
    var sources: [DataSource]
    var anchor: HKQueryAnchor?
    var isFullScan: Bool
}

private struct QuantityDelta {
    var records: [QuantityRecord]
    var deletedIDs: [String]
    var sources: [DataSource]
    var anchor: HKQueryAnchor?
    var isFullScan: Bool
}

private struct IntervalDelta {
    var intervals: [ContextInterval]
    var deletedIDs: [String]
    var sources: [DataSource]
    var anchor: HKQueryAnchor?
    var isFullScan: Bool
}

private struct SourceAccumulator {
    private(set) var sourcesByID: [String: DataSource]

    init(existing: [DataSource]) {
        sourcesByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
    }

    mutating func add(_ sources: [DataSource]) {
        for source in sources {
            sourcesByID[source.id] = source
        }
    }

    var sources: [DataSource] {
        Array(sourcesByID.values)
    }
}

private extension HKSample {
    var sourceID: String {
        let components = [
            sourceRevision.source.bundleIdentifier,
            sourceRevision.productType ?? "unknown-product",
            sourceIdentityPart
        ].joined(separator: "::")
        return sourceIdentityPart.hasPrefix("ambiguous::") ? "ambiguous::\(components)" : components
    }

    var dataSource: DataSource {
        DataSource(id: sourceID, name: displaySourceName, isAppleWatch: isAppleWatch)
    }

    var isAppleWatch: Bool {
        guard let device else {
            return sourceRevision.productType?.localizedCaseInsensitiveContains("Watch") == true
        }
        return [
            device.model,
            device.name,
            sourceRevision.productType
        ].compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains("Watch") }
    }

    var sourceIdentityPart: String {
        guard let device else { return ambiguousSourcePart(extraParts: []) }
        if let localIdentifier = device.localIdentifier, !localIdentifier.isEmpty {
            return "local:\(localIdentifier)"
        }
        if let udi = device.udiDeviceIdentifier, !udi.isEmpty {
            return "udi:\(udi)"
        }

        return ambiguousSourcePart(extraParts: [
            device.manufacturer,
            device.model,
            device.hardwareVersion
        ])
    }

    var displaySourceName: String {
        let baseName = sourceRevision.source.name
        if let localIdentifier = device?.localIdentifier, !localIdentifier.isEmpty {
            return "\(baseName) · \(localIdentifier.suffix(6))"
        }
        if let udi = device?.udiDeviceIdentifier, !udi.isEmpty {
            return "\(baseName) · \(udi.suffix(6))"
        }

        return "\(baseName) · 身份不明确（仅原始记录）"
    }

    func ambiguousSourcePart(extraParts: [String?]) -> String {
        let components = ([
            sourceRevision.source.name,
            sourceRevision.productType
        ] + extraParts)
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let signature = components.isEmpty ? "unknown-source" : components.joined(separator: "|")
        return "ambiguous::\(signature)"
    }
}

private extension QuantityKind {
    static var allReadableHealthKitKinds: [QuantityKind] {
        [.heartRate, .sdnn, .restingHeartRate, .steps]
    }

    var healthKitIdentifier: HKQuantityTypeIdentifier {
        switch self {
        case .heartRate:
            return .heartRate
        case .sdnn:
            return .heartRateVariabilitySDNN
        case .restingHeartRate:
            return .restingHeartRate
        case .steps:
            return .stepCount
        }
    }

    var unit: HKUnit {
        switch self {
        case .heartRate, .restingHeartRate:
            return HKUnit.count().unitDivided(by: .minute())
        case .sdnn:
            return HKUnit.secondUnit(with: .milli)
        case .steps:
            return .count()
        }
    }
}

private extension IntervalKind {
    static var allReadableHealthKitKinds: [IntervalKind] {
        [.sleep, .workout, .mindfulness]
    }

    var sampleType: HKSampleType {
        switch self {
        case .sleep, .awake:
            return HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
        case .workout:
            return HKObjectType.workoutType()
        case .mindfulness:
            return HKObjectType.categoryType(forIdentifier: .mindfulSession)!
        }
    }
}

private extension MotionContext {
    init(metadata: [String: Any]?) {
        guard let raw = metadata?[HKMetadataKeyHeartRateMotionContext] as? NSNumber else {
            self = .unknown
            return
        }

        switch raw.intValue {
        case 1:
            self = .sedentary
        case 2:
            self = .active
        default:
            self = .unknown
        }
    }
}

private extension HKCategorySample {
    func sleepIntervals(sourceID: String) -> [ContextInterval] {
        guard let value = HKCategoryValueSleepAnalysis(rawValue: value) else { return [] }
        switch value {
        case .awake:
            return [
                ContextInterval(
                    id: "\(uuid.uuidString)-awake",
                    start: startDate,
                    end: endDate,
                    sourceID: sourceID,
                    kind: .awake
                )
            ]
        case .asleepUnspecified, .asleepCore, .asleepDeep, .asleepREM:
            return [
                ContextInterval(
                    id: "\(uuid.uuidString)-sleep",
                    start: startDate,
                    end: endDate,
                    sourceID: sourceID,
                    kind: .sleep
                )
            ]
        case .inBed:
            return []
        @unknown default:
            return []
        }
    }
}

private extension HealthDataset {
    func pruned(to start: Date, now: Date) -> HealthDataset {
        var copy = self
        copy.heartbeats = heartbeats.filter { $0.end >= start && $0.start <= now }
        copy.quantities = quantities.filter { $0.end >= start && $0.start <= now }
        copy.intervals = intervals.filter { $0.end >= start && $0.start <= now }
        return copy
    }

    mutating func applyHeartbeatDelta(_ delta: HeartbeatDelta, window: RefreshWindow) {
        let deleted = Set(delta.deletedIDs)
        let retained = heartbeats.filter { record in
            if delta.isFullScan { return !record.overlaps(window) }
            return !deleted.contains(record.id)
        }
        var byID = Dictionary(uniqueKeysWithValues: retained.map { ($0.id, $0) })
        for record in delta.records where record.overlaps(window) {
            byID[record.id] = record
        }
        heartbeats = byID.values.sorted { $0.start < $1.start }
    }

    mutating func applyQuantityDelta(_ delta: QuantityDelta, kind: QuantityKind, window: RefreshWindow) {
        let deleted = Set(delta.deletedIDs)
        let retained = quantities.filter { record in
            if record.kind != kind { return true }
            if delta.isFullScan { return !record.overlaps(window) }
            return !deleted.contains(record.id)
        }
        var byID = Dictionary(uniqueKeysWithValues: retained.map { ($0.id, $0) })
        for record in delta.records where record.overlaps(window) {
            byID[record.id] = record
        }
        quantities = byID.values.sorted { $0.start < $1.start }
    }

    mutating func applyIntervalDelta(_ delta: IntervalDelta, kind: IntervalKind, window: RefreshWindow) {
        let deleted = Set(delta.deletedIDs)
        var byID = Dictionary(uniqueKeysWithValues: intervals.filter { interval in
            switch kind {
            case .sleep:
                if delta.isFullScan {
                    return !(interval.kind == .sleep || interval.kind == .awake) || !interval.overlaps(window)
                }
                return !(interval.kind == .sleep || interval.kind == .awake) || !deleted.contains(interval.baseSleepID)
            default:
                if delta.isFullScan {
                    return interval.kind != kind || !interval.overlaps(window)
                }
                return interval.kind != kind || !deleted.contains(interval.id)
            }
        }.map { ($0.id, $0) })

        for interval in delta.intervals where interval.overlaps(window) {
            byID[interval.id] = interval
        }
        intervals = byID.values.sorted { $0.start < $1.start }
    }
}

private extension HeartbeatRecord {
    func overlaps(_ window: RefreshWindow) -> Bool {
        end >= window.start && start <= window.end
    }
}

private extension QuantityRecord {
    func overlaps(_ window: RefreshWindow) -> Bool {
        end >= window.start && start <= window.end
    }
}

private extension ContextInterval {
    func overlaps(_ window: RefreshWindow) -> Bool {
        end >= window.start && start <= window.end
    }

    var baseSleepID: String {
        id.replacingOccurrences(of: "-sleep", with: "").replacingOccurrences(of: "-awake", with: "")
    }
}
