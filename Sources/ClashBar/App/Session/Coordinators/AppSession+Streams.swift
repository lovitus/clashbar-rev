import Foundation

@MainActor
extension AppSession {
    private var computeNextStreamReconnectDelayUseCase: ComputeNextStreamReconnectDelayUseCase {
        ComputeNextStreamReconnectDelayUseCase()
    }

    private var normalizeWebSocketPayloadUseCase: NormalizeWebSocketPayloadUseCase {
        NormalizeWebSocketPayloadUseCase()
    }

    private var decodeStreamLogPayloadUseCase: DecodeStreamLogPayloadUseCase {
        DecodeStreamLogPayloadUseCase()
    }

    private var shouldEmitStreamDisconnectLogUseCase: ShouldEmitStreamDisconnectLogUseCase {
        ShouldEmitStreamDisconnectLogUseCase()
    }

    enum StreamKind: CaseIterable, Hashable {
        case traffic
        case memory
        case connections
        case logs

        var key: String {
            switch self {
            case .traffic: "traffic"
            case .memory: "memory"
            case .connections: "connections"
            case .logs: "logs"
            }
        }

        var label: String {
            switch self {
            case .traffic: "app.stream.label.traffic"
            case .memory: "app.stream.label.memory"
            case .connections: "app.stream.label.connections"
            case .logs: "app.stream.label.logs"
            }
        }
    }

    func startStream(
        kind: StreamKind,
        preserveReconnectState: Bool = false,
        makeWebSocket: @escaping (MihomoAPIClient) throws -> any StreamWebSocketTasking,
        onPayload: @escaping (Data) -> Void)
    {
        self.cancelStream(kind, resetReconnectState: !preserveReconnectState)
        guard self.streamAllowsAcquisition(kind) else { return }

        do {
            guard let client = try? clientOrThrow() else { return }
            let ws = try makeWebSocket(client)
            let generation = self.beginStreamSession(kind)
            self.setWebSocketTask(ws, for: kind)
            ws.resume()

            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.receiveLoop(
                    kind: kind,
                    generation: generation,
                    onPayload: onPayload,
                    reconnect: { [weak self] expectedGeneration, delayNanoseconds in
                        self?.scheduleStreamReconnect(
                            kind: kind,
                            generation: expectedGeneration,
                            delayNanoseconds: delayNanoseconds,
                            makeWebSocket: makeWebSocket,
                            onPayload: onPayload)
                    })
            }
            self.setReceiveTask(task, for: kind)
        } catch {
            appendLog(
                level: "error",
                message: tr("log.stream.start_failed", tr(kind.label), error.localizedDescription))
        }
    }

    func cancelStream(_ kind: StreamKind, resetReconnectState: Bool = true) {
        self.receiveTask(for: kind)?.cancel()
        self.reconnectTask(for: kind)?.cancel()
        self.webSocketTask(for: kind)?.cancel(with: .goingAway, reason: nil)
        self.setReceiveTask(nil, for: kind)
        self.setReconnectTask(nil, for: kind)
        self.setWebSocketTask(nil, for: kind)
        self.updateStreamLifecycleState(kind) { state in
            state.cancel(resetReconnectState: resetReconnectState)
        }
        if kind == .connections {
            currentConnectionsStreamIntervalMilliseconds = nil
        }
        if kind == .logs {
            currentLogsStreamLevel = nil
        }
        if kind == .traffic {
            self.resetPendingTrafficSnapshotState()
        }
        if resetReconnectState {
            self.resetStreamReconnectState(for: kind)
        }
    }

    private func receiveLoop(
        kind: StreamKind,
        generation: UInt64,
        onPayload: @escaping (Data) -> Void,
        reconnect: @escaping (UInt64, UInt64) -> Void) async
    {
        while !Task.isCancelled {
            guard self.streamOwns(kind, generation: generation) else { return }
            guard let ws = webSocketTask(for: kind) else { return }

            let message: URLSessionWebSocketTask.Message
            do {
                message = try await ws.receive()
            } catch {
                if Task.isCancelled { return }
                guard self.streamOwns(kind, generation: generation) else { return }
                let disconnectMessage = error.localizedDescription
                if self.shouldLogStreamDisconnect(kind: kind, message: disconnectMessage) {
                    appendLog(level: "error", message: tr("log.stream.disconnected", tr(kind.label), disconnectMessage))
                }
                ws.cancel(with: .goingAway, reason: nil)
                self.setWebSocketTask(nil, for: kind)
                self.setReceiveTask(nil, for: kind)
                self.recordStreamDisconnect(kind, generation: generation, error: disconnectMessage)

                guard self.shouldReconnectStreamAfterDisconnect() else { return }
                guard self.streamAllowsAcquisition(kind) else { return }
                reconnect(generation, self.nextReconnectDelayNanoseconds(for: kind))
                return
            }

            guard let payload = normalizedWebSocketPayload(from: message) else { continue }
            guard self.streamOwns(kind, generation: generation) else { return }
            self.markStreamPayloadReceived(for: kind, generation: generation)
            onPayload(payload)
        }
    }

    private func scheduleStreamReconnect(
        kind: StreamKind,
        generation: UInt64,
        delayNanoseconds: UInt64,
        makeWebSocket: @escaping (MihomoAPIClient) throws -> any StreamWebSocketTasking,
        onPayload: @escaping (Data) -> Void)
    {
        guard self.streamOwns(kind, generation: generation) else { return }
        guard self.reconnectTask(for: kind) == nil else { return }
        self.recordStreamReconnectScheduled(kind, generation: generation, delayNanoseconds: delayNanoseconds)
        let streamClock = self.streamClock

        let task = Task { @MainActor [weak self] in
            do {
                try await streamClock.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            guard self.streamOwns(kind, generation: generation) else { return }
            self.setReconnectTask(nil, for: kind)
            self.clearScheduledStreamReconnect(kind, generation: generation)
            guard self.shouldReconnectStreamAfterDisconnect() else { return }
            guard self.streamAllowsAcquisition(kind) else { return }
            self.startStream(
                kind: kind,
                preserveReconnectState: true,
                makeWebSocket: makeWebSocket,
                onPayload: onPayload)
        }
        self.setReconnectTask(task, for: kind)
    }

    func receiveTask(for kind: StreamKind) -> Task<Void, Never>? {
        streamReceiveTasks[kind]
    }

    func setReceiveTask(_ task: Task<Void, Never>?, for kind: StreamKind) {
        if let task {
            streamReceiveTasks[kind] = task
        } else {
            streamReceiveTasks.removeValue(forKey: kind)
        }
    }

    func reconnectTask(for kind: StreamKind) -> Task<Void, Never>? {
        streamReconnectTasks[kind]
    }

    func setReconnectTask(_ task: Task<Void, Never>?, for kind: StreamKind) {
        if let task {
            streamReconnectTasks[kind] = task
        } else {
            streamReconnectTasks.removeValue(forKey: kind)
        }
    }

    func webSocketTask(for kind: StreamKind) -> (any StreamWebSocketTasking)? {
        streamWebSocketTasks[kind]
    }

    func setWebSocketTask(_ task: (any StreamWebSocketTasking)?, for kind: StreamKind) {
        if let task {
            streamWebSocketTasks[kind] = task
        } else {
            streamWebSocketTasks.removeValue(forKey: kind)
        }
    }

    func startTrafficStream() {
        self.startStream(
            kind: .traffic,
            makeWebSocket: { try $0.makeWebSocketTask(for: .traffic) },
            onPayload: { [weak self] payload in
                guard let self else { return }
                self.pendingTrafficPayload = payload
                self.flushPendingTrafficSnapshotIfNeeded()
            })
    }

    func flushPendingTrafficSnapshotIfNeeded(immediately: Bool = false) {
        guard self.pendingTrafficPayload != nil else { return }
        if immediately {
            self.publishPendingTrafficSnapshot()
            return
        }
        self.schedulePendingTrafficSnapshotPublishIfNeeded()
    }

    func startMemoryStream() {
        self.startDecodableStream(
            kind: .memory,
            makeWebSocket: { try $0.makeWebSocketTask(for: .memory) },
            onDecoded: { [weak self] (snapshot: MemorySnapshot) in
                guard let self else { return }
                memory = snapshot
                self.evaluateCoreMemoryControl(snapshot)
            })
    }

    func evaluateCoreMemoryControl(_ snapshot: MemorySnapshot) {
        guard !self.isRemoteTarget else { return }
        guard let thresholdBytes = self.coreMemoryControlLevel.thresholdBytes else { return }
        guard self.coreRepository.isRunning else { return }
        guard !self.isCoreActionProcessing else { return }
        guard snapshot.inuse >= thresholdBytes else { return }

        let now = Date()
        if let lastAttemptAt = self.lastCoreMemoryControlRestartAttemptAt,
           now.timeIntervalSince(lastAttemptAt) < self.coreMemoryControlRestartCooldown
        {
            return
        }

        self.lastCoreMemoryControlRestartAttemptAt = now
        self.appendLog(
            level: "warning",
            message: self.tr(
                "log.core.memory_control.triggered",
                ValueFormatter.bytesInteger(snapshot.inuse),
                self.tr(self.coreMemoryControlLevel.titleKey)))

        Task { [weak self] in
            await self?.restartCore()
        }
    }

    func startConnectionsStream(intervalMilliseconds: Int? = nil) {
        self.startDecodableStream(
            kind: .connections,
            makeWebSocket: { try $0.makeWebSocketTask(for: .connections(interval: intervalMilliseconds)) },
            onDecoded: { [weak self] (snapshot: ConnectionsSnapshot) in
                guard let self else { return }
                self.applyConnectionsSnapshot(snapshot)
            })
        currentConnectionsStreamIntervalMilliseconds = intervalMilliseconds
    }

    func startLogsStream() {
        let level = self.logsStreamLevelFilter()
        self.startStream(
            kind: .logs,
            makeWebSocket: { try $0.makeWebSocketTask(for: .logs(level: level)) },
            onPayload: { [weak self] payload in
                guard let self else { return }
                if let line = decodeLogLinePayload(payload) {
                    appendMihomoLog(level: line.level, message: line.message)
                }
            })
        currentLogsStreamLevel = level
    }

    func logsStreamLevelFilter() -> String? {
        let runtimeLevel = self.logLevel.trimmed.lowercased()
        if ConfigLogLevel(rawValue: runtimeLevel) != nil {
            return runtimeLevel
        }

        let level = self.settingsLogLevel.trimmed.lowercased()
        guard ConfigLogLevel(rawValue: level) != nil else { return nil }
        return level
    }

    func refreshLogsStreamLevelIfNeeded() {
        guard self.webSocketTask(for: .logs) != nil else { return }
        guard currentLogsStreamLevel != self.logsStreamLevelFilter() else { return }
        self.startLogsStream()
    }

    private func schedulePendingTrafficSnapshotPublishIfNeeded() {
        guard self.trafficDecodeTask == nil else { return }

        let elapsed = Date().timeIntervalSince(self.lastTrafficDecodeAt)
        let publishInterval = Double(self.trafficPublishIntervalNanoseconds) / 1_000_000_000
        if elapsed >= publishInterval {
            self.publishPendingTrafficSnapshot()
            return
        }

        let remainingDelay = max(0.01, publishInterval - elapsed)
        let remainingNanoseconds = UInt64(remainingDelay * 1_000_000_000)
        self.trafficDecodeTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: remainingNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.publishPendingTrafficSnapshot()
        }
    }

    private func publishPendingTrafficSnapshot() {
        self.trafficDecodeTask?.cancel()
        self.trafficDecodeTask = nil

        guard let payload = self.pendingTrafficPayload else { return }
        self.pendingTrafficPayload = nil

        guard let snapshot = try? self.streamJSONDecoder.decode(TrafficSnapshot.self, from: payload) else {
            return
        }
        self.lastTrafficDecodeAt = Date()
        self.applyTrafficSnapshot(snapshot)

        if self.pendingTrafficPayload != nil {
            self.schedulePendingTrafficSnapshotPublishIfNeeded()
        }
    }

    private func applyTrafficSnapshot(_ snapshot: TrafficSnapshot) {
        self.traffic = snapshot
        guard self.isPanelPresented else {
            if !self.trafficHistoryUp.isEmpty || !self.trafficHistoryDown
                .isEmpty || self.displayUpTotal != 0 || self.displayDownTotal != 0 || self.lastTrafficSampleAt != nil
            {
                self.clearTrafficPresentationHistory()
            }
            return
        }
        self.appendTrafficHistory(up: snapshot.up, down: snapshot.down)
        self.updateTrafficTotals(from: snapshot)
    }

    private func resetPendingTrafficSnapshotState() {
        self.trafficDecodeTask?.cancel()
        self.trafficDecodeTask = nil
        self.pendingTrafficPayload = nil
        self.lastTrafficDecodeAt = .distantPast
    }

    private func applyConnectionsSnapshot(_ snapshot: ConnectionsSnapshot) {
        let totalCount = snapshot.totalCount
        if connectionsStore.connectionsCount != totalCount {
            connectionsStore.connectionsCount = totalCount
        }

        if connectionsStore.connections != snapshot.connections {
            connectionsStore.connections = snapshot.connections
        }
    }

    private func resetStreamReconnectState(for kind: StreamKind) {
        streamLastDisconnectLogAt.removeValue(forKey: kind.key)
        streamLastDisconnectLogMessage.removeValue(forKey: kind.key)
    }

    private func shouldReconnectStreamAfterDisconnect() -> Bool {
        if self.autoManageCoreOnNetworkChangeEnabled, self.networkReachabilityStatus == .offline {
            return false
        }
        return self.isRemoteTarget || self.coreRepository.isRunning
    }

    private func markStreamPayloadReceived(for kind: StreamKind, generation: UInt64) {
        guard self.streamOwns(kind, generation: generation) else { return }
        self.updateStreamLifecycleState(kind) { state in
            state.recordValidPayload()
        }
    }

    private func nextReconnectDelayNanoseconds(for kind: StreamKind) -> UInt64 {
        let attempt = self.streamLifecycleState(for: kind).reconnectAttemptValue()
        let result = self.computeNextStreamReconnectDelayUseCase.execute(
            currentAttempt: attempt,
            baseDelayNanoseconds: streamReconnectBaseDelayNanoseconds,
            maxDelayNanoseconds: streamReconnectMaxDelayNanoseconds,
            jitter: self.streamJitterSource.nextFactor())
        return result.delayNanoseconds
    }

    func streamAllowsAcquisition(_ kind: StreamKind) -> Bool {
        self.streamLifecycleState(for: kind).allowsAcquisition
    }

    func setStreamBreakerState(_ state: StreamCircuitBreakerState, for kind: StreamKind) {
        if !state.allowsAcquisition {
            self.receiveTask(for: kind)?.cancel()
            self.reconnectTask(for: kind)?.cancel()
            self.webSocketTask(for: kind)?.cancel(with: .goingAway, reason: nil)
            self.setReceiveTask(nil, for: kind)
            self.setReconnectTask(nil, for: kind)
            self.setWebSocketTask(nil, for: kind)
        }
        self.updateStreamLifecycleState(kind) { lifecycle in
            lifecycle.setBreakerState(state)
        }
        self.updateDataAcquisitionPolicy()
    }

    func streamRuntimeSnapshot(for kind: StreamKind) -> StreamRuntimeSnapshot {
        self.streamLifecycleState(for: kind).snapshot(
            key: kind.key,
            hasSocket: self.webSocketTask(for: kind) != nil,
            hasReceiveTask: self.receiveTask(for: kind) != nil,
            hasReconnectTask: self.reconnectTask(for: kind) != nil)
    }

    private func streamLifecycleState(for kind: StreamKind) -> StreamLifecycleState {
        streamLifecycleStates[kind] ?? StreamLifecycleState()
    }

    private func updateStreamLifecycleState(
        _ kind: StreamKind,
        mutation: (inout StreamLifecycleState) -> Void)
    {
        var state = self.streamLifecycleState(for: kind)
        mutation(&state)
        streamLifecycleStates[kind] = state
    }

    private func beginStreamSession(_ kind: StreamKind) -> UInt64 {
        var generation: UInt64 = 0
        self.updateStreamLifecycleState(kind) { state in
            generation = state.beginSession(at: self.streamClock.now())
        }
        return generation
    }

    private func streamOwns(_ kind: StreamKind, generation: UInt64) -> Bool {
        self.streamLifecycleState(for: kind).owns(generation)
    }

    private func recordStreamDisconnect(_ kind: StreamKind, generation: UInt64, error: String) {
        guard self.streamOwns(kind, generation: generation) else { return }
        self.updateStreamLifecycleState(kind) { state in
            state.recordDisconnect(
                error: error,
                at: self.streamClock.now(),
                stableAfter: 30,
                stablePayloads: 30)
        }
    }

    private func recordStreamReconnectScheduled(
        _ kind: StreamKind,
        generation: UInt64,
        delayNanoseconds: UInt64)
    {
        guard self.streamOwns(kind, generation: generation) else { return }
        self.updateStreamLifecycleState(kind) { state in
            _ = state.scheduleReconnect(
                delayNanoseconds: delayNanoseconds,
                at: self.streamClock.now(),
                rollingWindow: 60)
        }
    }

    private func clearScheduledStreamReconnect(_ kind: StreamKind, generation: UInt64) {
        guard self.streamOwns(kind, generation: generation) else { return }
        self.updateStreamLifecycleState(kind) { state in
            state.clearScheduledReconnect()
        }
    }

    private func shouldLogStreamDisconnect(kind: StreamKind, message: String) -> Bool {
        let key = kind.key
        let now = Date()
        let lastAt = streamLastDisconnectLogAt[key]
        let lastMessage = streamLastDisconnectLogMessage[key]

        let shouldEmit = self.shouldEmitStreamDisconnectLogUseCase.execute(
            now: now,
            lastLoggedAt: lastAt,
            lastLoggedMessage: lastMessage,
            currentMessage: message,
            throttleInterval: streamDisconnectLogThrottleInterval)

        if shouldEmit {
            streamLastDisconnectLogAt[key] = now
            streamLastDisconnectLogMessage[key] = message
        }
        return shouldEmit
    }

    func normalizedWebSocketPayload(from message: URLSessionWebSocketTask.Message) -> Data? {
        self.normalizeWebSocketPayloadUseCase.execute(message: message)
    }

    func startDecodableStream<Payload: Decodable>(
        kind: StreamKind,
        makeWebSocket: @escaping (MihomoAPIClient) throws -> any StreamWebSocketTasking,
        onDecoded: @escaping (Payload) -> Void)
    {
        self.startStream(
            kind: kind,
            makeWebSocket: makeWebSocket,
            onPayload: { [weak self] payload in
                guard let self else { return }
                guard let decoded = try? self.streamJSONDecoder.decode(Payload.self, from: payload) else {
                    // Ignore malformed/empty payloads without reconnecting to avoid log storms.
                    return
                }
                onDecoded(decoded)
            })
    }

    func decodeLogLinePayload(_ payload: Data) -> (level: String, message: String)? {
        self.decodeStreamLogPayloadUseCase.execute(payload: payload, decoder: self.streamJSONDecoder)
    }
}
