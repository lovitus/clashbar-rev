import Darwin
import Foundation

struct NetworkInterfaceCounters: Equatable {
    let receivedBytes: UInt64
    let sentBytes: UInt64
    let receivedPackets: UInt64
    let sentPackets: UInt64
}

struct NetworkInterfaceCounterSnapshot: Equatable {
    let timestamp: TimeInterval
    let countersByName: [String: NetworkInterfaceCounters]
}

private struct SystemNetworkInterfaceCounterSampler {
    func sample() -> NetworkInterfaceCounterSnapshot? {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else { return nil }
        defer { freeifaddrs(firstAddress) }

        var counters: [String: NetworkInterfaceCounters] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let address = cursor {
            let interface = address.pointee
            if let socketAddress = interface.ifa_addr,
               socketAddress.pointee.sa_family == UInt8(AF_LINK),
               let rawData = interface.ifa_data
            {
                let name = String(cString: interface.ifa_name)
                let data = rawData.assumingMemoryBound(to: if_data.self).pointee
                counters[name] = NetworkInterfaceCounters(
                    receivedBytes: UInt64(data.ifi_ibytes),
                    sentBytes: UInt64(data.ifi_obytes),
                    receivedPackets: UInt64(data.ifi_ipackets),
                    sentPackets: UInt64(data.ifi_opackets))
            }
            cursor = interface.ifa_next
        }

        return NetworkInterfaceCounterSnapshot(
            timestamp: ProcessInfo.processInfo.systemUptime,
            countersByName: counters)
    }
}

actor TrafficLoopMonitor {
    static let minimumSampleInterval: TimeInterval = 0.8
    static let maximumSampleInterval: TimeInterval = 1.5
    static let idleProbeStartInterval: TimeInterval = 10
    static let maximumRecoveryAttempts = 3

    private let sampler = SystemNetworkInterfaceCounterSampler()
    private var generation: UInt64 = 0
    private var baseline: NetworkInterfaceCounterSnapshot?
    private var nextIdleProbeAt: TimeInterval = 0
    private var rapidWatchUntil: TimeInterval = 0
    private var recoveryAttempts: [TimeInterval] = []
    private var state = TrafficLoopProtectionState()
    private var isRecovering = false

    func observe(
        coreUploadBytesPerSecond: Int64,
        coreDownloadBytesPerSecond: Int64,
        tunInterfaceName: String,
        generation: UInt64) -> TrafficLoopProtectionDecision
    {
        guard self.accept(generation: generation) else { return .none }
        guard !self.isRecovering else { return .none }
        guard let current = self.sampler.sample() else {
            self.resetSamplingState()
            return .none
        }

        guard current.countersByName[tunInterfaceName] != nil else {
            self.resetSamplingState()
            return .none
        }

        guard let baseline = self.baseline else {
            if self.state.isConfirming || current.timestamp >= self.nextIdleProbeAt {
                self.baseline = current
            }
            return .none
        }

        let elapsed = current.timestamp - baseline.timestamp
        guard elapsed >= Self.minimumSampleInterval else { return .none }
        guard elapsed <= Self.maximumSampleInterval else {
            self.restartSampling(from: current)
            return .none
        }

        let sample: TrafficLoopRateSample? = if let direction = self.state.lockedDirection {
            Self.makeRateSample(
                previous: baseline,
                current: current,
                tunInterfaceName: tunInterfaceName,
                direction: direction,
                coreUploadBytesPerSecond: coreUploadBytesPerSecond,
                coreDownloadBytesPerSecond: coreDownloadBytesPerSecond)
        } else {
            Self.makePreferredRateSample(
                previous: baseline,
                current: current,
                tunInterfaceName: tunInterfaceName,
                coreUploadBytesPerSecond: coreUploadBytesPerSecond,
                coreDownloadBytesPerSecond: coreDownloadBytesPerSecond)
        }

        guard let sample else {
            self.restartSampling(from: current)
            return .none
        }

        let decision = self.state.observe(sample)
        if case .confirm = decision {
            self.isRecovering = true
            self.baseline = nil
            return decision
        }

        if self.state.isConfirming {
            self.baseline = current
        } else {
            self.baseline = nil
            self.nextIdleProbeAt = current.timestamp + self.idleDelay(at: current.timestamp)
        }
        return decision
    }

    func captureNetworkSnapshot(generation: UInt64) -> NetworkInterfaceCounterSnapshot? {
        guard generation == self.generation else { return nil }
        return self.sampler.sample()
    }

    func claimRecoveryAttempt(generation: UInt64) -> Bool {
        guard generation == self.generation else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        self.recoveryAttempts.removeAll { now - $0 >= 30 }
        guard self.recoveryAttempts.count < Self.maximumRecoveryAttempts else { return false }
        self.recoveryAttempts.append(now)
        return true
    }

    func finishRecovery(generation: UInt64, cooldown: TimeInterval, rapidWatchDuration: TimeInterval) {
        guard generation == self.generation else { return }
        let now = ProcessInfo.processInfo.systemUptime
        self.isRecovering = false
        self.state.reset()
        self.baseline = nil
        self.nextIdleProbeAt = now + max(0, cooldown)
        self.rapidWatchUntil = max(self.rapidWatchUntil, now + max(0, rapidWatchDuration))
    }

    func reset(generation: UInt64) {
        guard generation > self.generation else { return }
        self.generation = generation
        self.isRecovering = false
        self.rapidWatchUntil = 0
        self.recoveryAttempts.removeAll(keepingCapacity: false)
        self.resetSamplingState()
    }

    nonisolated static func makePreferredRateSample(
        previous: NetworkInterfaceCounterSnapshot,
        current: NetworkInterfaceCounterSnapshot,
        tunInterfaceName: String,
        coreUploadBytesPerSecond: Int64,
        coreDownloadBytesPerSecond: Int64) -> TrafficLoopRateSample?
    {
        let ingress = self.makeRateSample(
            previous: previous,
            current: current,
            tunInterfaceName: tunInterfaceName,
            direction: .ingress,
            coreUploadBytesPerSecond: coreUploadBytesPerSecond,
            coreDownloadBytesPerSecond: coreDownloadBytesPerSecond)
        let egress = self.makeRateSample(
            previous: previous,
            current: current,
            tunInterfaceName: tunInterfaceName,
            direction: .egress,
            coreUploadBytesPerSecond: coreUploadBytesPerSecond,
            coreDownloadBytesPerSecond: coreDownloadBytesPerSecond)

        let samples = [ingress, egress].compactMap(\.self)
        return samples
            .filter(TrafficLoopProtectionState.isConservationViolation)
            .max(by: { $0.tunPacketsPerSecond < $1.tunPacketsPerSecond })
            ?? samples.max(by: { $0.tunPacketsPerSecond < $1.tunPacketsPerSecond })
    }

    nonisolated static func makeRateSample(
        previous: NetworkInterfaceCounterSnapshot,
        current: NetworkInterfaceCounterSnapshot,
        tunInterfaceName: String,
        direction: TrafficLoopDirection,
        coreUploadBytesPerSecond: Int64,
        coreDownloadBytesPerSecond: Int64) -> TrafficLoopRateSample?
    {
        let elapsed = current.timestamp - previous.timestamp
        guard elapsed >= Self.minimumSampleInterval, elapsed <= Self.maximumSampleInterval else { return nil }
        guard Set(previous.countersByName.keys) == Set(current.countersByName.keys) else { return nil }
        guard let previousTun = previous.countersByName[tunInterfaceName],
              let currentTun = current.countersByName[tunInterfaceName]
        else { return nil }

        let tunBytes: UInt64
        let tunPackets: UInt64
        switch direction {
        case .ingress:
            guard currentTun.receivedBytes >= previousTun.receivedBytes,
                  currentTun.receivedPackets >= previousTun.receivedPackets
            else { return nil }
            tunBytes = currentTun.receivedBytes - previousTun.receivedBytes
            tunPackets = currentTun.receivedPackets - previousTun.receivedPackets
        case .egress:
            guard currentTun.sentBytes >= previousTun.sentBytes,
                  currentTun.sentPackets >= previousTun.sentPackets
            else { return nil }
            tunBytes = currentTun.sentBytes - previousTun.sentBytes
            tunPackets = currentTun.sentPackets - previousTun.sentPackets
        }

        var externalPackets: UInt64 = 0
        for (name, currentCounters) in current.countersByName where name != tunInterfaceName {
            guard let previousCounters = previous.countersByName[name] else { return nil }
            switch direction {
            case .ingress:
                guard currentCounters.receivedBytes >= previousCounters.receivedBytes,
                      currentCounters.receivedPackets >= previousCounters.receivedPackets
                else { return nil }
                externalPackets += currentCounters.receivedPackets - previousCounters.receivedPackets
            case .egress:
                guard currentCounters.sentBytes >= previousCounters.sentBytes,
                      currentCounters.sentPackets >= previousCounters.sentPackets
                else { return nil }
                externalPackets += currentCounters.sentPackets - previousCounters.sentPackets
            }
        }

        let coreBytesPerSecond: Int64 = switch direction {
        case .ingress: coreDownloadBytesPerSecond
        case .egress: coreUploadBytesPerSecond
        }
        return TrafficLoopRateSample(
            tunInterfaceName: tunInterfaceName,
            direction: direction,
            coreBytesPerSecond: Double(max(0, coreBytesPerSecond)),
            tunBytesPerSecond: Double(tunBytes) / elapsed,
            tunPacketsPerSecond: Double(tunPackets) / elapsed,
            externalPacketsPerSecond: Double(externalPackets) / elapsed)
    }

    private func accept(generation: UInt64) -> Bool {
        guard generation >= self.generation else { return false }
        if generation > self.generation {
            self.generation = generation
            self.isRecovering = false
            self.rapidWatchUntil = 0
            self.recoveryAttempts.removeAll(keepingCapacity: false)
            self.resetSamplingState()
        }
        return true
    }

    private func resetSamplingState(nextIdleProbeAt: TimeInterval = 0) {
        self.baseline = nil
        self.nextIdleProbeAt = nextIdleProbeAt
        self.state.reset()
    }

    private func restartSampling(from current: NetworkInterfaceCounterSnapshot) {
        self.state.reset()
        self.baseline = current
        self.nextIdleProbeAt = current.timestamp
    }

    private func idleDelay(at timestamp: TimeInterval) -> TimeInterval {
        timestamp < self.rapidWatchUntil ? 0 : Self.idleProbeStartInterval - 1
    }
}
