import Foundation

struct TrafficLoopRateSample: Equatable {
    let timestamp: TimeInterval
    let coreDownloadBytesPerSecond: Double
    let dominantTunIngressBytesPerSecond: Double
    let externalIngressBytesPerSecond: Double
}

enum TrafficLoopProtectionDecision: Equatable {
    case none
    case confirm
}

struct TrafficLoopProtectionState: Equatable {
    static let minimumCoreDownloadBytesPerSecond: Double = 32 * 1024 * 1024
    static let requiredSuspiciousDuration: TimeInterval = 3
    static let recoveryCooldown: TimeInterval = 15

    private(set) var suspiciousSince: TimeInterval?
    private(set) var cooldownUntil: TimeInterval?

    mutating func observe(_ sample: TrafficLoopRateSample) -> TrafficLoopProtectionDecision {
        if let cooldownUntil, sample.timestamp < cooldownUntil {
            self.suspiciousSince = nil
            return .none
        }
        self.cooldownUntil = nil

        guard Self.isConservationViolation(sample) else {
            self.suspiciousSince = nil
            return .none
        }

        if self.suspiciousSince == nil {
            self.suspiciousSince = sample.timestamp
            return .none
        }

        guard sample.timestamp - (self.suspiciousSince ?? sample.timestamp) >= Self.requiredSuspiciousDuration else {
            return .none
        }

        self.suspiciousSince = nil
        return .confirm
    }

    mutating func beginRecoveryCooldown(at timestamp: TimeInterval) {
        self.suspiciousSince = nil
        self.cooldownUntil = timestamp + Self.recoveryCooldown
    }

    mutating func reset() {
        self.suspiciousSince = nil
        self.cooldownUntil = nil
    }

    private static func isConservationViolation(_ sample: TrafficLoopRateSample) -> Bool {
        let coreDown = sample.coreDownloadBytesPerSecond
        guard coreDown >= self.minimumCoreDownloadBytesPerSecond else { return false }
        guard sample.dominantTunIngressBytesPerSecond >= coreDown * 1.5 else { return false }
        return sample.externalIngressBytesPerSecond * 8 < coreDown
    }
}

struct TrafficLoopConnectionCandidate: Equatable {
    let id: String
    let downloadDelta: Int64
}

struct FindTrafficLoopConnectionCandidateUseCase {
    static let minimumDownloadDelta: Int64 = 16 * 1024 * 1024

    func execute(
        first: ConnectionTrafficCountersSnapshot,
        second: ConnectionTrafficCountersSnapshot)
        -> TrafficLoopConnectionCandidate?
    {
        guard first.isComplete, second.isComplete else { return nil }
        let totalDelta = max(0, second.downloadTotal - first.downloadTotal)
        guard totalDelta >= Self.minimumDownloadDelta else { return nil }

        var best: TrafficLoopConnectionCandidate?
        for (id, download) in second.downloadByID {
            guard let previous = first.downloadByID[id] else { continue }
            let delta = max(0, download - previous)
            if delta > (best?.downloadDelta ?? -1) {
                best = TrafficLoopConnectionCandidate(id: id, downloadDelta: delta)
            }
        }

        guard let best, best.downloadDelta >= Self.minimumDownloadDelta else { return nil }
        guard Double(best.downloadDelta) / Double(totalDelta) >= 0.8 else { return nil }
        return best
    }
}

struct TrafficLoopRecoveryBudget: Equatable {
    static let rollingWindow: TimeInterval = 10 * 60
    static let maximumAttempts = 2

    private(set) var attemptTimestamps: [TimeInterval] = []
    private(set) var isBlocked = false

    mutating func claim(at timestamp: TimeInterval) -> Bool {
        guard !self.isBlocked else { return false }
        self.attemptTimestamps.removeAll { timestamp - $0 >= Self.rollingWindow }
        guard self.attemptTimestamps.count < Self.maximumAttempts else {
            self.isBlocked = true
            return false
        }
        self.attemptTimestamps.append(timestamp)
        return true
    }

    mutating func reset() {
        self.attemptTimestamps.removeAll(keepingCapacity: false)
        self.isBlocked = false
    }
}
