import XCTest
@testable import ClashBar

final class TrafficLoopProtectionTests: XCTestCase {
    func testRequiresSustainedConservationViolation() {
        var state = TrafficLoopProtectionState()
        let mib = 1024.0 * 1024.0

        XCTAssertEqual(state.observe(.init(
            timestamp: 0,
            coreDownloadBytesPerSecond: 100 * mib,
            dominantTunIngressBytesPerSecond: 200 * mib,
            externalIngressBytesPerSecond: 8_000)), .none)
        XCTAssertEqual(state.observe(.init(
            timestamp: 2.9,
            coreDownloadBytesPerSecond: 100 * mib,
            dominantTunIngressBytesPerSecond: 200 * mib,
            externalIngressBytesPerSecond: 8_000)), .none)
        XCTAssertEqual(state.observe(.init(
            timestamp: 3.0,
            coreDownloadBytesPerSecond: 100 * mib,
            dominantTunIngressBytesPerSecond: 200 * mib,
            externalIngressBytesPerSecond: 8_000)), .confirm)
    }

    func testRejectsNormalDownloadWithPhysicalIngress() {
        var state = TrafficLoopProtectionState()
        let mib = 1024.0 * 1024.0
        for second in 0 ... 10 {
            XCTAssertEqual(state.observe(.init(
                timestamp: TimeInterval(second),
                coreDownloadBytesPerSecond: 100 * mib,
                dominantTunIngressBytesPerSecond: 200 * mib,
                externalIngressBytesPerSecond: 95 * mib)), .none)
        }
    }

    func testRejectsLowRateVirtualTraffic() {
        var state = TrafficLoopProtectionState()
        let mib = 1024.0 * 1024.0
        for second in 0 ... 10 {
            XCTAssertEqual(state.observe(.init(
                timestamp: TimeInterval(second),
                coreDownloadBytesPerSecond: 4 * mib,
                dominantTunIngressBytesPerSecond: 100 * mib,
                externalIngressBytesPerSecond: 0)), .none)
        }
    }

    func testCooldownSuppressesImmediateRetrigger() {
        var state = TrafficLoopProtectionState()
        let mib = 1024.0 * 1024.0
        let sample: (TimeInterval) -> TrafficLoopRateSample = { timestamp in
            .init(
                timestamp: timestamp,
                coreDownloadBytesPerSecond: 100 * mib,
                dominantTunIngressBytesPerSecond: 200 * mib,
                externalIngressBytesPerSecond: 0)
        }

        XCTAssertEqual(state.observe(sample(0)), .none)
        XCTAssertEqual(state.observe(sample(3)), .confirm)
        state.beginRecoveryCooldown(at: 3)
        XCTAssertEqual(state.observe(sample(17.9)), .none)
        XCTAssertEqual(state.observe(sample(18)), .none)
        XCTAssertEqual(state.observe(sample(21)), .confirm)
    }

    func testTrafficCounterDecoderRejectsIncompleteBoundedBaseline() throws {
        let entries: [[String: Any]] = (0 ... ConnectionTrafficCountersSnapshot.retainedConnectionLimit).map {
            index in
            ["id": "connection-\(index)", "download": index]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "downloadTotal": 1_000_000_000,
            "connections": entries,
        ])

        let snapshot = try JSONDecoder().decode(ConnectionTrafficCountersSnapshot.self, from: data)
        XCTAssertEqual(snapshot.downloadByID.count, ConnectionTrafficCountersSnapshot.retainedConnectionLimit)
        XCTAssertEqual(snapshot.totalCount, ConnectionTrafficCountersSnapshot.retainedConnectionLimit + 1)
        XCTAssertEqual(snapshot.downloadTotal, 1_000_000_000)
        XCTAssertFalse(snapshot.isComplete)
    }

    func testRateSampleMatchesValidatedMachineCounters() throws {
        let previous = NetworkInterfaceCounterSnapshot(
            timestamp: 0,
            receivedBytesByName: [
                "en1": 2_989_518_837,
                "utun5": 2_835_938_760_252,
            ])
        let current = NetworkInterfaceCounterSnapshot(
            timestamp: 1.05,
            receivedBytesByName: [
                "en1": 2_989_525_823,
                "utun5": 2_836_152_052_386,
            ])

        let sample = try XCTUnwrap(TrafficLoopMonitor.makeRateSample(
            previous: previous,
            current: current,
            coreDownloadBytesPerSecond: 100 * 1024 * 1024))

        XCTAssertGreaterThan(sample.dominantTunIngressBytesPerSecond, 190 * 1024 * 1024)
        XCTAssertLessThan(sample.externalIngressBytesPerSecond, 10_000)
    }

    func testCandidateMustDominateDownloadDelta() {
        let mib: Int64 = 1024 * 1024
        let first = counters(
            ["loop": 1_000, "other": 500],
            downloadTotal: 1_500)
        let second = counters(
            ["loop": 101 * mib, "other": mib],
            downloadTotal: 102 * mib)

        let candidate = FindTrafficLoopConnectionCandidateUseCase().execute(first: first, second: second)
        XCTAssertEqual(candidate?.id, "loop")
    }

    func testCandidateRejectsDistributedTraffic() {
        let mib: Int64 = 1024 * 1024
        let first = counters(["a": 0, "b": 0], downloadTotal: 0)
        let second = counters(
            ["a": 30 * mib, "b": 30 * mib],
            downloadTotal: 60 * mib)

        XCTAssertNil(FindTrafficLoopConnectionCandidateUseCase().execute(first: first, second: second))
    }

    func testCandidateFindsNewLoopBehindLargeIdleConnections() {
        let mib: Int64 = 1024 * 1024
        var firstValues: [String: Int64] = [:]
        var secondValues: [String: Int64] = [:]
        for index in 0 ..< 40 {
            firstValues["idle-\(index)"] = 10 * 1024 * mib
            secondValues["idle-\(index)"] = 10 * 1024 * mib
        }
        firstValues["loop"] = 1
        secondValues["loop"] = 100 * mib

        let candidate = FindTrafficLoopConnectionCandidateUseCase().execute(
            first: counters(firstValues, downloadTotal: 400 * 1024 * mib),
            second: counters(secondValues, downloadTotal: 400 * 1024 * mib + 100 * mib))

        XCTAssertEqual(candidate?.id, "loop")
    }

    func testCandidateRejectsIncompleteSnapshot() {
        let mib: Int64 = 1024 * 1024
        let first = counters(["loop": 0], downloadTotal: 0, isComplete: false)
        let second = counters(["loop": 100 * mib], downloadTotal: 100 * mib)
        XCTAssertNil(FindTrafficLoopConnectionCandidateUseCase().execute(first: first, second: second))
    }

    func testRecoveryBudgetBlocksAfterTwoAttemptsUntilReset() {
        var budget = TrafficLoopRecoveryBudget()
        XCTAssertTrue(budget.claim(at: 0))
        XCTAssertTrue(budget.claim(at: 1))
        XCTAssertFalse(budget.claim(at: 2))
        XCTAssertTrue(budget.isBlocked)
        XCTAssertFalse(budget.claim(at: 1_000))

        budget.reset()
        XCTAssertTrue(budget.claim(at: 1_001))
        XCTAssertFalse(budget.isBlocked)
    }

    private func counters(
        _ values: [String: Int64],
        downloadTotal: Int64,
        isComplete: Bool = true)
        -> ConnectionTrafficCountersSnapshot
    {
        ConnectionTrafficCountersSnapshot(
            totalCount: values.count,
            downloadTotal: downloadTotal,
            downloadByID: values,
            isComplete: isComplete)
    }
}
