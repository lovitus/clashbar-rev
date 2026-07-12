import XCTest
@testable import ClashBar

final class StreamLifecycleStateTests: XCTestCase {
    func testNewSessionInvalidatesPreviousGeneration() {
        var state = StreamLifecycleState()
        let first = state.beginSession(at: Date(timeIntervalSince1970: 10))
        let second = state.beginSession(at: Date(timeIntervalSince1970: 20))

        XCTAssertFalse(state.owns(first))
        XCTAssertTrue(state.owns(second))
    }

    func testCancelInvalidatesGenerationAndCanPreserveReconnectHistory() {
        var state = StreamLifecycleState()
        let generation = state.beginSession(at: Date(timeIntervalSince1970: 10))
        _ = state.scheduleReconnect(
            delayNanoseconds: 1_000_000_000,
            at: Date(timeIntervalSince1970: 11),
            rollingWindow: 60)

        state.cancel(resetReconnectState: false)

        XCTAssertFalse(state.owns(generation))
        XCTAssertEqual(state.reconnectAttemptValue(), 1)
    }

    func testSinglePayloadDoesNotMakeSessionStable() {
        var state = StreamLifecycleState()
        _ = state.beginSession(at: Date(timeIntervalSince1970: 10))
        state.recordValidPayload()
        state.recordDisconnect(
            error: "lost",
            at: Date(timeIntervalSince1970: 11),
            stableAfter: 30,
            stablePayloads: 30)

        let snapshot = state.snapshot(
            key: "logs",
            hasSocket: false,
            hasReceiveTask: false,
            hasReconnectTask: false)
        XCTAssertEqual(snapshot.consecutiveUnhealthySessions, 1)
        XCTAssertEqual(snapshot.validPayloadCount, 0)
    }

    func testStableDurationResetsUnhealthySessionCount() {
        var state = StreamLifecycleState()
        _ = state.beginSession(at: Date(timeIntervalSince1970: 0))
        state.recordDisconnect(
            error: "first",
            at: Date(timeIntervalSince1970: 1),
            stableAfter: 30,
            stablePayloads: 30)
        _ = state.beginSession(at: Date(timeIntervalSince1970: 10))
        state.recordDisconnect(
            error: "later",
            at: Date(timeIntervalSince1970: 41),
            stableAfter: 30,
            stablePayloads: 30)

        XCTAssertEqual(
            state.snapshot(
                key: "traffic",
                hasSocket: false,
                hasReceiveTask: false,
                hasReconnectTask: false)
                .consecutiveUnhealthySessions,
            0)
    }

    func testOpenBreakerInvalidatesOwnerAndBlocksAcquisition() {
        var state = StreamLifecycleState()
        let generation = state.beginSession(at: Date(timeIntervalSince1970: 10))

        state.setBreakerState(.open(until: Date(timeIntervalSince1970: 40)))

        XCTAssertFalse(state.allowsAcquisition)
        XCTAssertFalse(state.owns(generation))
    }

    func testRollingReconnectWindowIsBoundedByTime() {
        var state = StreamLifecycleState()
        _ = state.scheduleReconnect(
            delayNanoseconds: 1,
            at: Date(timeIntervalSince1970: 0),
            rollingWindow: 60)
        _ = state.scheduleReconnect(
            delayNanoseconds: 1,
            at: Date(timeIntervalSince1970: 30),
            rollingWindow: 60)
        _ = state.scheduleReconnect(
            delayNanoseconds: 1,
            at: Date(timeIntervalSince1970: 61),
            rollingWindow: 60)

        XCTAssertEqual(
            state.snapshot(
                key: "memory",
                hasSocket: false,
                hasReceiveTask: false,
                hasReconnectTask: true)
                .rollingReconnectStarts,
            2)
    }
}
