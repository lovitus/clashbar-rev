import Darwin
import Foundation

struct NetworkInterfaceCounterSnapshot: Sendable {
    let timestamp: TimeInterval
    let receivedBytesByName: [String: UInt64]
}

private struct SystemNetworkInterfaceCounterSampler: Sendable {
    func sample() -> NetworkInterfaceCounterSnapshot? {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else { return nil }
        defer { freeifaddrs(firstAddress) }

        var counters: [String: UInt64] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let address = cursor {
            let interface = address.pointee
            if let socketAddress = interface.ifa_addr,
               socketAddress.pointee.sa_family == UInt8(AF_LINK),
               let rawData = interface.ifa_data
            {
                let name = String(cString: interface.ifa_name)
                let data = rawData.assumingMemoryBound(to: if_data.self).pointee
                counters[name] = UInt64(data.ifi_ibytes)
            }
            cursor = interface.ifa_next
        }

        return NetworkInterfaceCounterSnapshot(
            timestamp: ProcessInfo.processInfo.systemUptime,
            receivedBytesByName: counters)
    }
}

actor TrafficLoopMonitor {
    private let sampler = SystemNetworkInterfaceCounterSampler()
    private var previousInterfaceSnapshot: NetworkInterfaceCounterSnapshot?
    private var state = TrafficLoopProtectionState()
    private var recoveryBudget = TrafficLoopRecoveryBudget()

    func observe(coreDownloadBytesPerSecond: Int64) -> TrafficLoopProtectionDecision {
        guard !self.recoveryBudget.isBlocked else { return .none }
        guard let current = sampler.sample() else {
            self.previousInterfaceSnapshot = nil
            self.state.reset()
            return .none
        }
        defer { self.previousInterfaceSnapshot = current }

        guard let previous = self.previousInterfaceSnapshot else { return .none }
        guard let rateSample = Self.makeRateSample(
            previous: previous,
            current: current,
            coreDownloadBytesPerSecond: coreDownloadBytesPerSecond)
        else {
            self.state.reset()
            return .none
        }

        return self.state.observe(rateSample)
    }

    nonisolated static func makeRateSample(
        previous: NetworkInterfaceCounterSnapshot,
        current: NetworkInterfaceCounterSnapshot,
        coreDownloadBytesPerSecond: Int64)
        -> TrafficLoopRateSample?
    {
        let elapsed = current.timestamp - previous.timestamp
        guard elapsed >= 0.2, elapsed <= 5 else { return nil }

        var receivedRates: [String: Double] = [:]
        for (name, currentBytes) in current.receivedBytesByName {
            guard let previousBytes = previous.receivedBytesByName[name], currentBytes >= previousBytes else { continue }
            receivedRates[name] = Double(currentBytes - previousBytes) / elapsed
        }

        guard let dominantTun = receivedRates
            .filter({ $0.key.hasPrefix("utun") })
            .max(by: { $0.value < $1.value })
        else {
            return nil
        }

        let externalIngress = receivedRates.reduce(into: 0.0) { total, item in
            let (name, rate) = item
            guard name != dominantTun.key, name != "lo0" else { return }
            total += rate
        }

        return TrafficLoopRateSample(
            timestamp: current.timestamp,
            coreDownloadBytesPerSecond: Double(max(0, coreDownloadBytesPerSecond)),
            dominantTunIngressBytesPerSecond: dominantTun.value,
            externalIngressBytesPerSecond: externalIngress)
    }

    func beginRecoveryCooldown() {
        self.state.beginRecoveryCooldown(at: ProcessInfo.processInfo.systemUptime)
    }

    func claimRecoveryAttempt() -> Bool {
        self.recoveryBudget.claim(at: ProcessInfo.processInfo.systemUptime)
    }

    func reset() {
        self.previousInterfaceSnapshot = nil
        self.state.reset()
        self.recoveryBudget.reset()
    }
}
