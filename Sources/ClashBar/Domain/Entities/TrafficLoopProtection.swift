import Foundation

enum TrafficLoopDirection: Equatable {
    case ingress
    case egress
}

struct TrafficLoopRateSample: Equatable {
    let tunInterfaceName: String
    let direction: TrafficLoopDirection
    let coreBytesPerSecond: Double
    let tunBytesPerSecond: Double
    let tunPacketsPerSecond: Double
    let externalPacketsPerSecond: Double
}

enum TrafficLoopProtectionDecision: Equatable {
    case none
    case armed
    case confirm(TrafficLoopRateSample)
}

struct TrafficLoopProtectionState: Equatable {
    static let minimumTunPacketsPerSecond: Double = 10000
    static let externalPacketRatio: Double = 8
    static let externalPacketMargin: Double = 5000
    static let minimumCoreBytesPerSecond: Double = 64 * 1024
    static let tunToCoreByteRatio: Double = 1.5
    static let requiredConfirmationSamples = 3

    private(set) var lockedInterfaceName: String?
    private(set) var lockedDirection: TrafficLoopDirection?
    private(set) var confirmationCount = 0

    var isConfirming: Bool {
        self.lockedInterfaceName != nil && self.lockedDirection != nil
    }

    mutating func observe(_ sample: TrafficLoopRateSample) -> TrafficLoopProtectionDecision {
        guard self.isConfirming else {
            return self.armIfNeeded(sample)
        }
        guard self.lockedInterfaceName == sample.tunInterfaceName,
              self.lockedDirection == sample.direction,
              Self.isConservationViolation(sample)
        else {
            self.reset()
            return .none
        }

        self.confirmationCount += 1
        guard self.confirmationCount >= Self.requiredConfirmationSamples else { return .none }
        self.reset()
        return .confirm(sample)
    }

    mutating func reset() {
        self.lockedInterfaceName = nil
        self.lockedDirection = nil
        self.confirmationCount = 0
    }

    static func isConservationViolation(_ sample: TrafficLoopRateSample) -> Bool {
        guard sample.tunPacketsPerSecond > self.minimumTunPacketsPerSecond else { return false }
        guard sample.tunPacketsPerSecond >=
            sample.externalPacketsPerSecond * self.externalPacketRatio + self.externalPacketMargin
        else { return false }
        guard sample.coreBytesPerSecond >= self.minimumCoreBytesPerSecond else { return false }
        return sample.tunBytesPerSecond >= sample.coreBytesPerSecond * self.tunToCoreByteRatio
    }

    private mutating func armIfNeeded(_ sample: TrafficLoopRateSample) -> TrafficLoopProtectionDecision {
        guard sample.tunPacketsPerSecond > Self.minimumTunPacketsPerSecond else { return .none }
        self.lockedInterfaceName = sample.tunInterfaceName
        self.lockedDirection = sample.direction
        self.confirmationCount = 0
        return .armed
    }
}

struct TrafficLoopConnectionCandidate: Equatable {
    let id: String
    let start: String
    let processPath: String
    let directionalDelta: Int64
}

struct FindTrafficLoopConnectionCandidateUseCase {
    static let minimumDirectionalDelta: Int64 = 64 * 1024
    static let minimumDominantShare: Double = 0.8

    func execute(
        first: ConnectionTrafficCountersSnapshot,
        second: ConnectionTrafficCountersSnapshot,
        direction: TrafficLoopDirection,
        excludedProcessPaths: Set<String>) -> TrafficLoopConnectionCandidate?
    {
        guard first.isComplete, second.isComplete else { return nil }
        for previous in first.entriesByID.values where Self.isTun(previous) {
            guard let current = second.entriesByID[previous.id],
                  Self.isTun(current),
                  current.start == previous.start
            else { return nil }
        }

        let exclusions = Set(excludedProcessPaths.map(Self.normalizedPath))
        var totalDelta: Int64 = 0
        var ranked: [(entry: ConnectionTrafficEntry, delta: Int64)] = []
        for entry in second.entriesByID.values where Self.isTun(entry) {
            let counter = Self.counter(entry, direction: direction)
            let delta: Int64
            if let previous = first.entriesByID[entry.id] {
                guard previous.start == entry.start else { return nil }
                let previousCounter = Self.counter(previous, direction: direction)
                guard counter >= previousCounter else { return nil }
                delta = counter - previousCounter
            } else {
                delta = counter
            }
            let (updatedTotal, overflow) = totalDelta.addingReportingOverflow(delta)
            guard !overflow else { return nil }
            totalDelta = updatedTotal
            ranked.append((entry, delta))
        }

        ranked.sort { $0.delta > $1.delta }
        guard totalDelta >= Self.minimumDirectionalDelta,
              let best = ranked.first,
              best.delta >= Self.minimumDirectionalDelta,
              best.delta > (ranked.dropFirst().first?.delta ?? -1),
              Double(best.delta) / Double(totalDelta) >= Self.minimumDominantShare,
              let start = best.entry.start?.trimmedNonEmpty,
              let processPath = best.entry.processPath?.trimmedNonEmpty,
              processPath.hasPrefix("/"),
              !Self.isProtectedProcessPath(processPath, exclusions: exclusions)
        else { return nil }

        return TrafficLoopConnectionCandidate(
            id: best.entry.id,
            start: start,
            processPath: processPath,
            directionalDelta: best.delta)
    }

    private static func isTun(_ entry: ConnectionTrafficEntry) -> Bool {
        entry.type?.caseInsensitiveCompare("tun") == .orderedSame
    }

    private static func counter(_ entry: ConnectionTrafficEntry, direction: TrafficLoopDirection) -> Int64 {
        direction == .ingress ? entry.download : entry.upload
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path.lowercased()
    }

    private static func isProtectedProcessPath(_ path: String, exclusions: Set<String>) -> Bool {
        let normalized = self.normalizedPath(path)
        return exclusions.contains(normalized)
            || normalized.contains("mihomo")
            || normalized.contains("clash")
    }
}

struct VerifyTrafficLoopCausalRecoveryUseCase {
    func execute(
        preClose: TrafficLoopRateSample,
        postClose: TrafficLoopRateSample,
        candidateIsAbsent: Bool) -> Bool
    {
        guard candidateIsAbsent,
              preClose.tunInterfaceName == postClose.tunInterfaceName,
              preClose.direction == postClose.direction,
              TrafficLoopProtectionState.isConservationViolation(preClose)
        else { return false }
        let packetsRecovered = postClose.tunPacketsPerSecond <= preClose.tunPacketsPerSecond * 0.2
        return packetsRecovered && !TrafficLoopProtectionState.isConservationViolation(postClose)
    }
}
