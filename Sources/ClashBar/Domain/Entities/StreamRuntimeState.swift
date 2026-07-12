import Foundation

enum StreamCircuitBreakerState: Equatable {
    case closed
    case open(until: Date?)
    case halfOpen

    var allowsAcquisition: Bool {
        switch self {
        case .closed, .halfOpen:
            true
        case .open:
            false
        }
    }
}

struct StreamRuntimeSnapshot: Equatable {
    let key: String
    let generation: UInt64
    let breakerState: StreamCircuitBreakerState
    let hasSocket: Bool
    let hasReceiveTask: Bool
    let hasReconnectTask: Bool
    let rollingReconnectStarts: Int
    let consecutiveUnhealthySessions: Int
    let validPayloadCount: Int
    let sessionStartedAt: Date?
    let nextReconnectAt: Date?
    let lastError: String?
}

struct StreamLifecycleState: Equatable {
    private(set) var generation: UInt64 = 0
    private(set) var breakerState: StreamCircuitBreakerState = .closed
    private(set) var reconnectAttempt = 0
    private(set) var reconnectStarts: [Date] = []
    private(set) var consecutiveUnhealthySessions = 0
    private(set) var validPayloadCount = 0
    private(set) var sessionStartedAt: Date?
    private(set) var nextReconnectAt: Date?
    private(set) var lastError: String?

    var allowsAcquisition: Bool {
        self.breakerState.allowsAcquisition
    }

    mutating func beginSession(at now: Date) -> UInt64 {
        self.generation &+= 1
        self.sessionStartedAt = now
        self.validPayloadCount = 0
        self.nextReconnectAt = nil
        self.lastError = nil
        return self.generation
    }

    mutating func cancel(resetReconnectState: Bool) {
        self.generation &+= 1
        self.sessionStartedAt = nil
        self.validPayloadCount = 0
        self.nextReconnectAt = nil
        if resetReconnectState {
            self.reconnectAttempt = 0
            self.reconnectStarts.removeAll(keepingCapacity: false)
            self.consecutiveUnhealthySessions = 0
            self.lastError = nil
        }
    }

    func owns(_ candidateGeneration: UInt64) -> Bool {
        self.generation == candidateGeneration
    }

    mutating func recordValidPayload() {
        self.validPayloadCount = min(Int.max, self.validPayloadCount + 1)
    }

    mutating func recordDisconnect(error: String, at now: Date, stableAfter: TimeInterval, stablePayloads: Int) {
        let duration = self.sessionStartedAt.map { now.timeIntervalSince($0) } ?? 0
        let stable = duration >= stableAfter || self.validPayloadCount >= stablePayloads
        if stable {
            self.reconnectAttempt = 0
            self.consecutiveUnhealthySessions = 0
        } else {
            self.consecutiveUnhealthySessions = min(Int.max, self.consecutiveUnhealthySessions + 1)
        }
        self.sessionStartedAt = nil
        self.validPayloadCount = 0
        self.lastError = error
    }

    mutating func scheduleReconnect(
        delayNanoseconds: UInt64,
        at now: Date,
        rollingWindow: TimeInterval) -> Date
    {
        self.reconnectStarts.removeAll { now.timeIntervalSince($0) > rollingWindow }
        self.reconnectStarts.append(now)
        self.reconnectAttempt = min(self.reconnectAttempt + 1, 8)
        let next = now.addingTimeInterval(Double(delayNanoseconds) / 1_000_000_000)
        self.nextReconnectAt = next
        return next
    }

    mutating func clearScheduledReconnect() {
        self.nextReconnectAt = nil
    }

    mutating func setBreakerState(_ state: StreamCircuitBreakerState) {
        self.breakerState = state
        if !state.allowsAcquisition {
            self.generation &+= 1
            self.sessionStartedAt = nil
            self.validPayloadCount = 0
            self.nextReconnectAt = nil
        }
    }

    func reconnectAttemptValue() -> Int {
        self.reconnectAttempt
    }

    func snapshot(
        key: String,
        hasSocket: Bool,
        hasReceiveTask: Bool,
        hasReconnectTask: Bool) -> StreamRuntimeSnapshot
    {
        StreamRuntimeSnapshot(
            key: key,
            generation: self.generation,
            breakerState: self.breakerState,
            hasSocket: hasSocket,
            hasReceiveTask: hasReceiveTask,
            hasReconnectTask: hasReconnectTask,
            rollingReconnectStarts: self.reconnectStarts.count,
            consecutiveUnhealthySessions: self.consecutiveUnhealthySessions,
            validPayloadCount: self.validPayloadCount,
            sessionStartedAt: self.sessionStartedAt,
            nextReconnectAt: self.nextReconnectAt,
            lastError: self.lastError)
    }
}
