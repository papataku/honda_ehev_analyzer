import Foundation

/// One request lane for all previously verified, complete-positive read-only DIDs.
/// No hard candidate cap: priority changes dynamically instead of truncating the list.
public enum DriveSamplingPriority: String, Sendable {
    case learning
    case active
    case watch
    case dormant
}

public enum DriveOperatingContext: String, Hashable, Sendable {
    case unknown
    case ev
    case engine
    case regeneration
    case traction

    public static func classify(speedKmh: Double?, engineRPM: Double?, powerKW: Double?) -> Self {
        guard let speedKmh, speedKmh > 0 else { return .unknown }
        if let powerKW, powerKW < -2 { return .regeneration }
        if let engineRPM, engineRPM > 150 { return .engine }
        if let powerKW, powerKW > 2 { return .traction }
        return .ev
    }
}

public struct DriveSamplingSummary: Equatable, Sendable {
    public let total: Int
    public let learning: Int
    public let active: Int
    public let watch: Int
    public let dormant: Int
    public let successfulSamples: Int
    public let failedSamples: Int
}

public struct DriveSamplingChange: Sendable {
    public let previous: DriveSamplingPriority
    public let current: DriveSamplingPriority
    public let reason: String
}

/// Scheduling policy:
/// - Learning entries get baseline samples even if the catalogue grows.
/// - A changing payload is sampled more often.
/// - Unchanged responses are downgraded to sparse probes, not removed.
/// - Entries tested in >=2 driving conditions may become dormant.
/// - On a new operating condition, wake dormant entries for re-evaluation.
/// - Errors back off individually and never count as proof of constant data.
/// - 1/4 of opportunities are reserved for sparse/learning rechecks.
/// No concurrent ELM requests or rate promises are made by this scheduler.
public final class AdaptiveDriveDIDScheduler {
    private struct Entry {
        let candidate: DriveDID
        var priority: DriveSamplingPriority = .learning
        var nextDue: Date = .distantPast
        var lastPayload: Data?
        var successful: Int = 0
        var unchanged: Int = 0
        var changed: Int = 0
        var failed: Int = 0
        var consecutiveFailures: Int = 0
        var contexts: Set<DriveOperatingContext> = []
    }

    private var entries: [String: Entry] = [:]
    private var currentContext: DriveOperatingContext = .unknown
    private var selections = 0

    public init(candidates: [DriveDID]) {
        for did in candidates { entries[did.id] = Entry(candidate: did) }
    }

    public func addCandidates(_ candidates: [DriveDID]) {
        for candidate in candidates where entries[candidate.id] == nil {
            entries[candidate.id] = Entry(candidate: candidate)
        }
    }

    public var summary: DriveSamplingSummary {
        var learning = 0, active = 0, watch = 0, dormant = 0
        var successful = 0, failed = 0
        for entry in entries.values {
            switch entry.priority {
            case .learning: learning += 1
            case .active: active += 1
            case .watch: watch += 1
            case .dormant: dormant += 1
            }
            successful += entry.successful
            failed += entry.failed
        }
        return DriveSamplingSummary(
            total: entries.count, learning: learning, active: active,
            watch: watch, dormant: dormant, successfulSamples: successful,
            failedSamples: failed
        )
    }

    public func priority(for id: String) -> DriveSamplingPriority? {
        entries[id]?.priority
    }

    public func next(now: Date, context: DriveOperatingContext) -> DriveDID? {
        if context != currentContext {
            currentContext = context
            if context != .unknown {
                // A new drive state can reveal a formerly constant field.
                for key in entries.keys {
                    guard var entry = entries[key] else { continue }
                    if entry.priority == .dormant || entry.priority == .watch {
                        entry.nextDue = min(entry.nextDue, now)
                        entries[key] = entry
                    }
                }
            }
        }
        let due = entries.values.filter { $0.nextDue <= now }
        guard !due.isEmpty else { return nil }

        selections += 1
        let sparseTurn = selections % 4 == 0
        let preferred: [DriveSamplingPriority] = sparseTurn
            ? [.watch, .dormant, .learning, .active]
            : [.active, .learning, .watch, .dormant]

        for tier in preferred {
            let tierEntries = due.filter { $0.priority == tier }
            if let next = tierEntries.min(by: {
                if $0.nextDue != $1.nextDue { return $0.nextDue < $1.nextDue }
                return $0.candidate.id < $1.candidate.id
            }) { return next.candidate }
        }
        return nil
    }

    @discardableResult
    public func observe(
        _ candidate: DriveDID,
        payload: Data?,
        at now: Date,
        context: DriveOperatingContext
    ) -> DriveSamplingChange? {
        guard var entry = entries[candidate.id] else { return nil }
        let previous = entry.priority

        if let payload, !payload.isEmpty {
            let changed = entry.lastPayload.map { $0 != payload } ?? false
            entry.successful += 1
            entry.consecutiveFailures = 0
            if context != .unknown { entry.contexts.insert(context) }

            if changed {
                entry.changed += 1
                entry.unchanged = 0
                entry.priority = .active
            } else if entry.lastPayload != nil {
                entry.unchanged += 1
                if entry.unchanged >= 12 && entry.contexts.count >= 2 {
                    entry.priority = .dormant
                } else if entry.unchanged >= 7 {
                    entry.priority = .watch
                }
            }

            entry.lastPayload = payload
            let seconds: TimeInterval
            switch entry.priority {
            case .learning: seconds = 1.0
            case .active: seconds = 0.8
            case .watch: seconds = 12.0
            case .dormant: seconds = 90.0
            }
            entry.nextDue = now.addingTimeInterval(seconds)
        } else {
            entry.failed += 1
            entry.consecutiveFailures += 1
            // A failed response is never evidence of constant payload.
            let retry = min(60.0, 5.0 * pow(2.0, Double(min(entry.consecutiveFailures - 1, 4))))
            entry.nextDue = now.addingTimeInterval(retry)
        }

        entries[candidate.id] = entry
        guard previous != entry.priority else { return nil }
        let reason = entry.priority == .active ? "payload_changed" :
            (entry.priority == .dormant ? "constant_across_contexts" : "repeated_unchanged")
        return DriveSamplingChange(previous: previous, current: entry.priority, reason: reason)
    }
}
