import XCTest
@testable import ClashBar

final class TrafficLoopProtectionTests: XCTestCase {
    func testArmsThenRequiresThreeConsecutiveConservationViolations() {
        var state = TrafficLoopProtectionState()
        XCTAssertEqual(state.observe(self.rate()), .armed)
        XCTAssertEqual(state.observe(self.rate()), .none)
        XCTAssertEqual(state.observe(self.rate()), .none)
        XCTAssertEqual(state.observe(self.rate()), .confirm(self.rate()))
    }

    func testPacketPretriggerArmsBeforeCoreCountersAlign() {
        var state = TrafficLoopProtectionState()
        XCTAssertEqual(state.observe(self.rate(coreBytes: 0)), .armed)
        XCTAssertEqual(state.observe(self.rate()), .none)
        XCTAssertEqual(state.observe(self.rate()), .none)
        XCTAssertEqual(state.observe(self.rate()), .confirm(self.rate()))
    }

    func testConfirmationResetsWhenPhysicalPacketsExplainTunTraffic() {
        var state = TrafficLoopProtectionState()
        XCTAssertEqual(state.observe(self.rate()), .armed)
        XCTAssertEqual(state.observe(self.rate(externalPackets: 18000)), .none)
        XCTAssertFalse(state.isConfirming)
    }

    func testFieldPacketLoopTriggersConservationViolation() throws {
        let previous = self.networkSnapshot(
            timestamp: 0,
            received: ["en1": (1_000_000, 20000), "lo0": (100_000, 1000), "utun5": (2_000_000, 30000)])
        let current = self.networkSnapshot(
            timestamp: 1,
            received: ["en1": (1_005_000, 20040), "lo0": (101_000, 1010), "utun5": (9_500_000, 177_000)])

        let sample = try XCTUnwrap(TrafficLoopMonitor.makeRateSample(
            previous: previous,
            current: current,
            tunInterfaceName: "utun5",
            direction: .ingress,
            coreUploadBytesPerSecond: 0,
            coreDownloadBytesPerSecond: 1_550_000))

        XCTAssertEqual(sample.tunPacketsPerSecond, 147_000)
        XCTAssertEqual(sample.externalPacketsPerSecond, 50)
        XCTAssertTrue(TrafficLoopProtectionState.isConservationViolation(sample))
    }

    func testNormalHighSpeedDownloadIsNotConservationViolation() throws {
        let previous = self.networkSnapshot(
            timestamp: 0,
            received: ["en1": (0, 0), "utun5": (0, 0)])
        let current = self.networkSnapshot(
            timestamp: 1,
            received: ["en1": (17_000_000, 11500), "utun5": (18_000_000, 12000)])
        let sample = try XCTUnwrap(TrafficLoopMonitor.makeRateSample(
            previous: previous,
            current: current,
            tunInterfaceName: "utun5",
            direction: .ingress,
            coreUploadBytesPerSecond: 0,
            coreDownloadBytesPerSecond: 12_000_000))
        XCTAssertFalse(TrafficLoopProtectionState.isConservationViolation(sample))
    }

    func testOtherTunTrafficCountsAsExternalEvidence() throws {
        let previous = self.networkSnapshot(
            timestamp: 0,
            received: ["en1": (0, 0), "utun4": (0, 0), "utun5": (0, 0)])
        let current = self.networkSnapshot(
            timestamp: 1,
            received: ["en1": (1000, 10), "utun4": (5_000_000, 20000), "utun5": (7_500_000, 30000)])
        let sample = try XCTUnwrap(TrafficLoopMonitor.makeRateSample(
            previous: previous,
            current: current,
            tunInterfaceName: "utun5",
            direction: .ingress,
            coreUploadBytesPerSecond: 0,
            coreDownloadBytesPerSecond: 1_000_000))
        XCTAssertEqual(sample.externalPacketsPerSecond, 20010)
        XCTAssertFalse(TrafficLoopProtectionState.isConservationViolation(sample))
    }

    func testEgressUsesSentCountersAndCoreUpload() throws {
        let previous = self.networkSnapshot(timestamp: 0, sent: ["en1": (0, 0), "utun5": (0, 0)])
        let current = self.networkSnapshot(
            timestamp: 1,
            sent: ["en1": (1000, 10), "utun5": (2_000_000, 40000)])
        let sample = try XCTUnwrap(TrafficLoopMonitor.makeRateSample(
            previous: previous,
            current: current,
            tunInterfaceName: "utun5",
            direction: .egress,
            coreUploadBytesPerSecond: 500_000,
            coreDownloadBytesPerSecond: 99_000_000))
        XCTAssertEqual(sample.coreBytesPerSecond, 500_000)
        XCTAssertEqual(sample.tunPacketsPerSecond, 40000)
    }

    func testPreferredDirectionChoosesViolationOverHigherNormalPPS() throws {
        let previous = self.networkSnapshot(
            timestamp: 0,
            received: ["en1": (0, 0), "utun5": (0, 0)],
            sent: ["en1": (0, 0), "utun5": (0, 0)])
        let current = self.networkSnapshot(
            timestamp: 1,
            received: ["en1": (1000, 10), "utun5": (2_000_000, 30000)],
            sent: ["en1": (2_500_000, 49000), "utun5": (3_000_000, 50000)])

        let sample = try XCTUnwrap(TrafficLoopMonitor.makePreferredRateSample(
            previous: previous,
            current: current,
            tunInterfaceName: "utun5",
            coreUploadBytesPerSecond: 1_000_000,
            coreDownloadBytesPerSecond: 1_000_000))

        XCTAssertEqual(sample.direction, .ingress)
        XCTAssertTrue(TrafficLoopProtectionState.isConservationViolation(sample))
    }

    func testRateSampleRequiresExactTunDevice() {
        let snapshot = self.networkSnapshot(timestamp: 0, received: ["utun4": (0, 0)])
        XCTAssertNil(TrafficLoopMonitor.makeRateSample(
            previous: snapshot,
            current: self.networkSnapshot(timestamp: 1, received: ["utun4": (1_000_000, 20000)]),
            tunInterfaceName: "utun5",
            direction: .ingress,
            coreUploadBytesPerSecond: 0,
            coreDownloadBytesPerSecond: 500_000))
    }

    func testRealConnectionContractDecodesStringPortAndProcessMetadata() throws {
        let data = Data(#"""
        {
          "uploadTotal":123,"downloadTotal":456,
          "connections":[{"id":"loop","upload":10,"download":20,"start":"2026-08-30T01:02:03Z",
          "metadata":{"type":"TUN","network":"udp","sourceIP":"198.18.0.1",
          "destinationIP":"17.0.0.1","destinationPort":"443","processPath":"/System/Test.app/Test"}}]
        }
        """#.utf8)
        let snapshot = try JSONDecoder().decode(ConnectionTrafficCountersSnapshot.self, from: data)
        let entry = try XCTUnwrap(snapshot.entriesByID["loop"])
        XCTAssertTrue(snapshot.isComplete)
        XCTAssertEqual(entry.type, "TUN")
        XCTAssertEqual(entry.processPath, "/System/Test.app/Test")
    }

    func testCounterDecoderRejectsIncompleteBoundedSnapshot() throws {
        let entries: [[String: Any]] = (0...ConnectionTrafficCountersSnapshot.retainedConnectionLimit).map {
            ["id": "connection-\($0)", "upload": 0, "download": $0]
        }
        let data = try JSONSerialization.data(withJSONObject: ["connections": entries])
        let snapshot = try JSONDecoder().decode(ConnectionTrafficCountersSnapshot.self, from: data)
        XCTAssertEqual(snapshot.entriesByID.count, ConnectionTrafficCountersSnapshot.retainedConnectionLimit)
        XCTAssertFalse(snapshot.isComplete)
    }

    func testCandidateUsesDirectionalTunDeltaAndDominance() {
        let first = self.connectionSnapshot([
            self.entry(id: "loop", upload: 0, download: 10),
            self.entry(id: "other", upload: 0, download: 10),
            self.entry(id: "proxy", upload: 0, download: 10, type: "Mixed"),
        ])
        let second = self.connectionSnapshot([
            self.entry(id: "loop", upload: 0, download: 900_000),
            self.entry(id: "other", upload: 0, download: 100_000),
            self.entry(id: "proxy", upload: 0, download: 9_000_000, type: "Mixed"),
        ])
        let candidate = FindTrafficLoopConnectionCandidateUseCase().execute(
            first: first,
            second: second,
            direction: .ingress,
            excludedProcessPaths: [])
        XCTAssertEqual(candidate?.id, "loop")
    }

    func testCandidateRejectsDistributedOrExcludedTraffic() {
        let first = self.connectionSnapshot([
            self.entry(id: "a", upload: 0, download: 0),
            self.entry(id: "b", upload: 0, download: 0),
        ])
        let second = self.connectionSnapshot([
            self.entry(id: "a", upload: 0, download: 500_000),
            self.entry(id: "b", upload: 0, download: 500_000),
        ])
        XCTAssertNil(FindTrafficLoopConnectionCandidateUseCase().execute(
            first: first,
            second: second,
            direction: .ingress,
            excludedProcessPaths: []))

        let dominant = self.connectionSnapshot([self.entry(id: "a", upload: 0, download: 900_000)])
        XCTAssertNil(FindTrafficLoopConnectionCandidateUseCase().execute(
            first: self.connectionSnapshot([self.entry(id: "a", upload: 0, download: 0)]),
            second: dominant,
            direction: .ingress,
            excludedProcessPaths: ["/Applications/Test.app/Test"]))

        let protected = self.connectionSnapshot([
            self.entry(
                id: "a",
                upload: 0,
                download: 900_000,
                processPath: "/Applications/ClashHelper.app/ClashHelper"),
        ])
        XCTAssertNil(FindTrafficLoopConnectionCandidateUseCase().execute(
            first: self.connectionSnapshot([]),
            second: protected,
            direction: .ingress,
            excludedProcessPaths: []))
    }

    func testCandidateAllowsNewIDButRejectsDisappearedTunID() {
        let empty = self.connectionSnapshot([])
        let new = self.connectionSnapshot([self.entry(id: "new", upload: 0, download: 900_000)])
        XCTAssertEqual(FindTrafficLoopConnectionCandidateUseCase().execute(
            first: empty,
            second: new,
            direction: .ingress,
            excludedProcessPaths: [])?.id, "new")
        XCTAssertNil(FindTrafficLoopConnectionCandidateUseCase().execute(
            first: new,
            second: empty,
            direction: .ingress,
            excludedProcessPaths: []))
        XCTAssertNil(FindTrafficLoopConnectionCandidateUseCase().execute(
            first: new,
            second: self.connectionSnapshot([self.entry(id: "new", upload: 0, download: 1_000_000, type: "Mixed")]),
            direction: .ingress,
            excludedProcessPaths: []))
    }

    func testCandidateMustKeepDominatingFreshWindow() throws {
        let candidate = try XCTUnwrap(FindTrafficLoopConnectionCandidateUseCase().execute(
            first: self.connectionSnapshot([self.entry(id: "loop", upload: 0, download: 0)]),
            second: self.connectionSnapshot([self.entry(id: "loop", upload: 0, download: 900_000)]),
            direction: .ingress,
            excludedProcessPaths: []))
        let fresh = FindTrafficLoopConnectionCandidateUseCase().execute(
            first: self.connectionSnapshot([self.entry(id: "loop", upload: 0, download: 900_000)]),
            second: self.connectionSnapshot([self.entry(id: "loop", upload: 0, download: 1_000_000)]),
            direction: .ingress,
            excludedProcessPaths: [])
        XCTAssertEqual(fresh?.id, candidate.id)
        XCTAssertNil(FindTrafficLoopConnectionCandidateUseCase().execute(
            first: self.connectionSnapshot([self.entry(id: "loop", upload: 0, download: 900_000)]),
            second: self.connectionSnapshot([self.entry(id: "loop", upload: 0, download: 900_000)]),
            direction: .ingress,
            excludedProcessPaths: []))
    }

    func testCausalRecoveryRequiresIDAbsenceAndPacketDrop() {
        let pre = self.rate(tunPackets: 100_000)
        let post = self.rate(tunPackets: 1000, coreBytes: 10000, tunBytes: 20000)
        let useCase = VerifyTrafficLoopCausalRecoveryUseCase()
        XCTAssertTrue(useCase.execute(preClose: pre, postClose: post, candidateIsAbsent: true))
        XCTAssertFalse(useCase.execute(preClose: pre, postClose: post, candidateIsAbsent: false))
        XCTAssertFalse(useCase.execute(
            preClose: pre,
            postClose: self.rate(tunPackets: 90000),
            candidateIsAbsent: true))
        XCTAssertFalse(useCase.execute(
            preClose: self.rate(tunPackets: 10001),
            postClose: self.rate(tunPackets: 4999, coreBytes: 10000, tunBytes: 20000),
            candidateIsAbsent: true))
    }

    func testRuntimeConfigDecodesExactTunDevice() throws {
        let config = try JSONDecoder().decode(
            ConfigSnapshot.self,
            from: Data(#"{"tun":{"enable":true,"stack":"mixed","device":"utun5"}}"#.utf8))
        XCTAssertEqual(config.tun?.device, "utun5")
    }

    private func rate(
        tunPackets: Double = 100_000,
        externalPackets: Double = 100,
        coreBytes: Double = 1_000_000,
        tunBytes: Double = 2_000_000) -> TrafficLoopRateSample
    {
        TrafficLoopRateSample(
            tunInterfaceName: "utun5",
            direction: .ingress,
            coreBytesPerSecond: coreBytes,
            tunBytesPerSecond: tunBytes,
            tunPacketsPerSecond: tunPackets,
            externalPacketsPerSecond: externalPackets)
    }

    private func networkSnapshot(
        timestamp: TimeInterval,
        received: [String: (UInt64, UInt64)] = [:],
        sent: [String: (UInt64, UInt64)] = [:]) -> NetworkInterfaceCounterSnapshot
    {
        let names = Set(received.keys).union(sent.keys)
        return NetworkInterfaceCounterSnapshot(
            timestamp: timestamp,
            countersByName: Dictionary(uniqueKeysWithValues: names.map { name in
                let rx = received[name] ?? (0, 0)
                let tx = sent[name] ?? (0, 0)
                return (name, NetworkInterfaceCounters(
                    receivedBytes: rx.0,
                    sentBytes: tx.0,
                    receivedPackets: rx.1,
                    sentPackets: tx.1))
            }))
    }

    private func entry(
        id: String,
        upload: Int64,
        download: Int64,
        type: String = "TUN",
        processPath: String = "/Applications/Test.app/Test") -> ConnectionTrafficEntry
    {
        ConnectionTrafficEntry(
            id: id,
            upload: upload,
            download: download,
            start: "2026-08-30T01:02:03Z",
            type: type,
            processPath: processPath)
    }

    private func connectionSnapshot(
        _ entries: [ConnectionTrafficEntry],
        isComplete: Bool = true) -> ConnectionTrafficCountersSnapshot
    {
        ConnectionTrafficCountersSnapshot(
            totalCount: entries.count,
            downloadTotal: entries.reduce(0) { $0 + $1.download },
            entriesByID: Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) }),
            isComplete: isComplete)
    }
}
