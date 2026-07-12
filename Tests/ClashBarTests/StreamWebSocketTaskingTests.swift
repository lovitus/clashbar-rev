import Foundation
import XCTest
@testable import ClashBar

private final class FakeStreamWebSocketTask: StreamWebSocketTasking, @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [URLSessionWebSocketTask.Message]
    private(set) var resumeCount = 0
    private(set) var cancelCount = 0

    init(messages: [URLSessionWebSocketTask.Message]) {
        self.messages = messages
    }

    func resume() {
        self.lock.withLock {
            self.resumeCount += 1
        }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try self.lock.withLock {
            guard !self.messages.isEmpty else { throw URLError(.networkConnectionLost) }
            return self.messages.removeFirst()
        }
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        self.lock.withLock {
            self.cancelCount += 1
        }
    }
}

final class StreamWebSocketTaskingTests: XCTestCase {
    func testFakeTransportSupportsDeterministicPayloadAndDisconnect() async throws {
        let task = FakeStreamWebSocketTask(messages: [.data(Data("ok".utf8))])

        task.resume()
        let message = try await task.receive()
        task.cancel(with: .goingAway, reason: nil)

        switch message {
        case let .data(data):
            XCTAssertEqual(data, Data("ok".utf8))
        case .string:
            XCTFail("Expected a data payload")
        @unknown default:
            XCTFail("Unexpected WebSocket message type")
        }
        XCTAssertEqual(task.resumeCount, 1)
        XCTAssertEqual(task.cancelCount, 1)
        do {
            _ = try await task.receive()
            XCTFail("Expected the fake transport to disconnect")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
        }
    }
}
