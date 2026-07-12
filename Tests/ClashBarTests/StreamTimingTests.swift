import Foundation
import XCTest
@testable import ClashBar

private final class FakeStreamClock: StreamClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var sleeps: [UInt64] = []

    init(now: Date) {
        self.current = now
    }

    func now() -> Date {
        self.lock.withLock { self.current }
    }

    func sleep(nanoseconds: UInt64) async throws {
        self.lock.withLock {
            self.sleeps.append(nanoseconds)
            self.current.addTimeInterval(Double(nanoseconds) / 1_000_000_000)
        }
    }

    func recordedSleeps() -> [UInt64] {
        self.lock.withLock { self.sleeps }
    }
}

private struct FakeStreamJitterSource: StreamJitterSource {
    let value: Double

    func nextFactor() -> Double {
        self.value
    }
}

final class StreamTimingTests: XCTestCase {
    func testFakeClockAdvancesWithoutWallClockSleep() async throws {
        let clock = FakeStreamClock(now: Date(timeIntervalSince1970: 10))

        try await clock.sleep(nanoseconds: 2_000_000_000)

        XCTAssertEqual(clock.now(), Date(timeIntervalSince1970: 12))
        XCTAssertEqual(clock.recordedSleeps(), [2_000_000_000])
    }

    func testFakeJitterIsDeterministic() {
        XCTAssertEqual(FakeStreamJitterSource(value: 1.05).nextFactor(), 1.05)
    }
}
