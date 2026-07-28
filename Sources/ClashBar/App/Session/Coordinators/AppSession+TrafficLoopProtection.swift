import Foundation

@MainActor
extension AppSession {
    func evaluateTrafficLoopProtection(_ snapshot: TrafficSnapshot) {
        guard !self.isRemoteTarget, self.coreRepository.isRunning else {
            self.resetTrafficLoopProtection()
            return
        }
        guard self.trafficLoopObservationTask == nil, self.trafficLoopRecoveryTask == nil else { return }

        let monitor = self.trafficLoopMonitor
        self.trafficLoopObservationTask = Task { @MainActor [weak self] in
            let decision = await monitor.observe(coreDownloadBytesPerSecond: snapshot.down)
            guard let self, !Task.isCancelled else { return }
            self.trafficLoopObservationTask = nil
            guard decision == .confirm, self.trafficLoopRecoveryTask == nil else { return }
            self.startTrafficLoopConfirmation()
        }
    }

    func resetTrafficLoopProtection() {
        self.trafficLoopObservationTask?.cancel()
        self.trafficLoopObservationTask = nil
        self.trafficLoopRecoveryTask?.cancel()
        self.trafficLoopRecoveryTask = nil
        let monitor = self.trafficLoopMonitor
        Task { await monitor.reset() }
    }

    private func startTrafficLoopConfirmation() {
        self.trafficLoopRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.trafficLoopRecoveryTask = nil }

            do {
                await self.trafficLoopMonitor.beginRecoveryCooldown()
                let client = try self.clientOrThrow()
                let first: ConnectionTrafficCountersSnapshot = try await client.request(.connections(interval: nil))
                try await self.streamClock.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, !self.isRemoteTarget, self.coreRepository.isRunning else { return }
                let second: ConnectionTrafficCountersSnapshot = try await client.request(.connections(interval: nil))

                guard let candidate = FindTrafficLoopConnectionCandidateUseCase().execute(
                    first: first,
                    second: second)
                else { return }

                guard await self.trafficLoopMonitor.claimRecoveryAttempt() else {
                    self.appendLog(level: "error", message: self.tr("log.traffic_loop.recovery_limit_reached"))
                    return
                }

                try await self.makeCloseConnectionUseCase(using: client).execute(id: candidate.id)
                self.appendLog(
                    level: "warning",
                    message: self.tr(
                        "log.traffic_loop.connection_closed",
                        ValueFormatter.bytesInteger(candidate.downloadDelta)))
            } catch is CancellationError {
                return
            } catch {
                self.appendLog(
                    level: "error",
                    message: self.tr("log.traffic_loop.recovery_failed", error.localizedDescription))
            }
        }
    }
}
