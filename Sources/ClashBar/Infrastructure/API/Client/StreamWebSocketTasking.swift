import Foundation

protocol StreamWebSocketTasking: AnyObject, Sendable {
    func resume()
    func receive() async throws -> URLSessionWebSocketTask.Message
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

extension URLSessionWebSocketTask: StreamWebSocketTasking {}
