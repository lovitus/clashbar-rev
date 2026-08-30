import Foundation

@MainActor
extension AppSession {
    private static var trafficLoopSampleIntervalNanoseconds: UInt64 {
        1_000_000_000
    }

    func evaluateTrafficLoopProtection(_ snapshot: TrafficSnapshot) {
        guard !self.isRemoteTarget,
              self.coreRepository.isRunning,
              self.isTunEnabled,
              let tunDevice = self.currentTunDeviceName?.trimmedNonEmpty,
              self.trafficLoopObservationTask == nil,
              self.trafficLoopRecoveryTask == nil
        else { return }

        let generation = self.trafficLoopProtectionGeneration
        let monitor = self.trafficLoopMonitor
        let task = Task { @MainActor [weak self] in
            let decision = await monitor.observe(
                coreUploadBytesPerSecond: snapshot.up,
                coreDownloadBytesPerSecond: snapshot.down,
                tunInterfaceName: tunDevice,
                generation: generation)

            guard let self, generation == self.trafficLoopProtectionGeneration else { return }
            self.trafficLoopObservationTask = nil
            guard !Task.isCancelled,
                  self.isTrafficLoopContextValid(generation: generation, tunDevice: tunDevice),
                  case let .confirm(pretriggerSample) = decision
            else { return }
            self.startTrafficLoopRecovery(
                pretriggerSample: pretriggerSample,
                generation: generation,
                tunDevice: tunDevice)
        }
        self.trafficLoopObservationTask = task
    }

    func updateTrafficLoopRuntime(tunEnabled: Bool?, deviceName: String?) {
        let normalizedDevice = deviceName?.trimmedNonEmpty
        let changed = normalizedDevice != self.currentTunDeviceName
            || (tunEnabled.map { $0 != self.isTunEnabled } ?? false)
        self.currentTunDeviceName = normalizedDevice
        if changed || tunEnabled == false {
            self.resetTrafficLoopProtection()
        }
    }

    func resetTrafficLoopProtection(clearTunDevice: Bool = false) {
        self.trafficLoopProtectionGeneration &+= 1
        let generation = self.trafficLoopProtectionGeneration
        self.trafficLoopObservationTask?.cancel()
        self.trafficLoopObservationTask = nil
        self.trafficLoopRecoveryTask?.cancel()
        self.trafficLoopRecoveryTask = nil
        if clearTunDevice { self.currentTunDeviceName = nil }
        let monitor = self.trafficLoopMonitor
        Task { await monitor.reset(generation: generation) }
    }

    private func startTrafficLoopRecovery(
        pretriggerSample: TrafficLoopRateSample,
        generation: UInt64,
        tunDevice: String)
    {
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var recovered = false
            do {
                recovered = try await self.performTrafficLoopRecovery(
                    direction: pretriggerSample.direction,
                    generation: generation,
                    tunDevice: tunDevice)
            } catch is CancellationError {
                // Expected when the core, TUN, config, or target changes.
            } catch {
                if self.isTrafficLoopContextValid(generation: generation, tunDevice: tunDevice) {
                    self.appendLog(
                        level: "error",
                        message: self.tr("log.traffic_loop.recovery_failed", error.localizedDescription))
                }
            }

            await self.trafficLoopMonitor.finishRecovery(
                generation: generation,
                cooldown: recovered ? 0 : 10,
                rapidWatchDuration: recovered ? 30 : 0)
            guard generation == self.trafficLoopProtectionGeneration else { return }
            self.trafficLoopRecoveryTask = nil
        }
        self.trafficLoopRecoveryTask = task
    }

    private func performTrafficLoopRecovery(
        direction: TrafficLoopDirection,
        generation: UInt64,
        tunDevice: String) async throws -> Bool
    {
        guard self.isTrafficLoopContextValid(generation: generation, tunDevice: tunDevice) else {
            throw CancellationError()
        }
        let client = try self.clientOrThrow()
        let exclusions = self.trafficLoopExcludedProcessPaths()
        let first: ConnectionTrafficCountersSnapshot = try await client.request(.connections(interval: nil))
        guard self.isTrafficLoopContextValid(generation: generation, tunDevice: tunDevice) else {
            throw CancellationError()
        }
        guard first.isComplete,
              let networkBaseline = await self.trafficLoopMonitor.captureNetworkSnapshot(generation: generation)
        else { return self.skipTrafficLoopAttribution() }

        try await self.streamClock.sleep(nanoseconds: Self.trafficLoopSampleIntervalNanoseconds)
        guard self.isTrafficLoopContextValid(generation: generation, tunDevice: tunDevice) else {
            throw CancellationError()
        }

        async let secondRequest: ConnectionTrafficCountersSnapshot = client.request(.connections(interval: nil))
        let currentNetwork = await self.trafficLoopMonitor.captureNetworkSnapshot(generation: generation)
        let second = try await secondRequest
        guard self.isTrafficLoopContextValid(generation: generation, tunDevice: tunDevice) else {
            throw CancellationError()
        }
        guard let currentNetwork,
              let attributionRate = TrafficLoopMonitor.makeRateSample(
                  previous: networkBaseline,
                  current: currentNetwork,
                  tunInterfaceName: tunDevice,
                  direction: direction,
                  coreUploadBytesPerSecond: self.traffic.up,
                  coreDownloadBytesPerSecond: self.traffic.down),
              TrafficLoopProtectionState.isConservationViolation(attributionRate),
              let candidate = FindTrafficLoopConnectionCandidateUseCase().execute(
                  first: first,
                  second: second,
                  direction: direction,
                  excludedProcessPaths: exclusions)
        else { return self.skipTrafficLoopAttribution() }

        try await self.streamClock.sleep(nanoseconds: Self.trafficLoopSampleIntervalNanoseconds)
        guard self.isTrafficLoopContextValid(generation: generation, tunDevice: tunDevice) else {
            throw CancellationError()
        }

        async let justInTimeRequest: ConnectionTrafficCountersSnapshot = client.request(.connections(interval: nil))
        let justInTimeNetwork = await self.trafficLoopMonitor.captureNetworkSnapshot(generation: generation)
        let justInTime = try await justInTimeRequest
        guard self.isTrafficLoopContextValid(generation: generation, tunDevice: tunDevice) else {
            throw CancellationError()
        }
        guard let justInTimeNetwork,
              let preCloseRate = TrafficLoopMonitor.makeRateSample(
                  previous: currentNetwork,
                  current: justInTimeNetwork,
                  tunInterfaceName: tunDevice,
                  direction: direction,
                  coreUploadBytesPerSecond: self.traffic.up,
                  coreDownloadBytesPerSecond: self.traffic.down),
              TrafficLoopProtectionState.isConservationViolation(preCloseRate),
              let justInTimeCandidate = FindTrafficLoopConnectionCandidateUseCase().execute(
                  first: second,
                  second: justInTime,
                  direction: direction,
                  excludedProcessPaths: exclusions),
              justInTimeCandidate.id == candidate.id,
              justInTimeCandidate.start == candidate.start,
              justInTimeCandidate.processPath == candidate.processPath
        else { return self.skipTrafficLoopAttribution() }

        guard await self.trafficLoopMonitor.claimRecoveryAttempt(generation: generation) else {
            self.appendLog(level: "warning", message: self.tr("log.traffic_loop.recovery_limit_reached"))
            return false
        }
        guard self.isTrafficLoopContextValid(generation: generation, tunDevice: tunDevice) else {
            throw CancellationError()
        }

        try await self.makeCloseConnectionUseCase(using: client).execute(id: justInTimeCandidate.id)
        guard let postBaseline = await self.trafficLoopMonitor.captureNetworkSnapshot(generation: generation)
        else { return false }
        try await self.streamClock.sleep(nanoseconds: Self.trafficLoopSampleIntervalNanoseconds)
        guard self.isTrafficLoopContextValid(generation: generation, tunDevice: tunDevice) else {
            throw CancellationError()
        }

        async let postConnectionsRequest: ConnectionTrafficCountersSnapshot = client
            .request(.connections(interval: nil))
        let postNetwork = await self.trafficLoopMonitor.captureNetworkSnapshot(generation: generation)
        let postConnections = try await postConnectionsRequest
        guard self.isTrafficLoopContextValid(generation: generation, tunDevice: tunDevice) else {
            throw CancellationError()
        }
        guard let postNetwork,
              let postRate = TrafficLoopMonitor.makeRateSample(
                  previous: postBaseline,
                  current: postNetwork,
                  tunInterfaceName: tunDevice,
                  direction: direction,
                  coreUploadBytesPerSecond: self.traffic.up,
                  coreDownloadBytesPerSecond: self.traffic.down),
              VerifyTrafficLoopCausalRecoveryUseCase().execute(
                  preClose: preCloseRate,
                  postClose: postRate,
                  candidateIsAbsent: postConnections.isComplete
                      && postConnections.entriesByID[justInTimeCandidate.id] == nil)
        else {
            self.appendLog(level: "warning", message: self.tr("log.traffic_loop.causal_not_proven"))
            return false
        }

        self.appendLog(
            level: "warning",
            message: self.tr(
                "log.traffic_loop.connection_closed",
                ValueFormatter.bytesInteger(justInTimeCandidate.directionalDelta),
                String(Int(preCloseRate.tunPacketsPerSecond)),
                String(Int(postRate.tunPacketsPerSecond))))
        return true
    }

    private func skipTrafficLoopAttribution() -> Bool {
        self.appendLog(level: "warning", message: self.tr("log.traffic_loop.attribution_skipped"))
        return false
    }

    private func trafficLoopExcludedProcessPaths() -> Set<String> {
        Set([
            Bundle.main.executableURL?.path.trimmedNonEmpty,
            self.resolvedMihomoBinaryPath()?.trimmedNonEmpty,
        ].compactMap(\.self))
    }

    private func isTrafficLoopContextValid(generation: UInt64, tunDevice: String) -> Bool {
        !Task.isCancelled
            && generation == self.trafficLoopProtectionGeneration
            && !self.isRemoteTarget
            && self.coreRepository.isRunning
            && self.isTunEnabled
            && self.currentTunDeviceName == tunDevice
    }
}
