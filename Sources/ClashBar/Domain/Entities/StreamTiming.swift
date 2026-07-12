import Foundation

protocol StreamClock: Sendable {
    func now() -> Date
    func sleep(nanoseconds: UInt64) async throws
}

struct SystemStreamClock: StreamClock {
    func now() -> Date {
        Date()
    }

    func sleep(nanoseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

protocol StreamJitterSource: Sendable {
    func nextFactor() -> Double
}

struct SystemStreamJitterSource: StreamJitterSource {
    func nextFactor() -> Double {
        Double.random(in: 0.85...1.15)
    }
}
