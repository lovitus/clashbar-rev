import XCTest
@testable import ClashBar

final class ComputeNextStreamReconnectDelayUseCaseTests: XCTestCase {
    func testInjectedJitterProducesDeterministicDelay() {
        let result = ComputeNextStreamReconnectDelayUseCase().execute(
            currentAttempt: 2,
            baseDelayNanoseconds: 1_000_000_000,
            maxDelayNanoseconds: 30_000_000_000,
            jitter: 1.0)

        XCTAssertEqual(result.delayNanoseconds, 4_000_000_000)
        XCTAssertEqual(result.nextAttempt, 3)
    }

    func testInjectedJitterIsClamped() {
        let low = ComputeNextStreamReconnectDelayUseCase().execute(
            currentAttempt: 0,
            baseDelayNanoseconds: 1_000_000_000,
            maxDelayNanoseconds: 30_000_000_000,
            jitter: 0)
        let high = ComputeNextStreamReconnectDelayUseCase().execute(
            currentAttempt: 0,
            baseDelayNanoseconds: 1_000_000_000,
            maxDelayNanoseconds: 30_000_000_000,
            jitter: 2)

        XCTAssertEqual(low.delayNanoseconds, 1_000_000_000)
        XCTAssertEqual(high.delayNanoseconds, 1_150_000_000)
    }
}
