import Foundation

enum CoreLifecycleStatus: Equatable {
    case stopped
    case starting
    case running(pid: Int32)
    case failed(reason: String)
}

protocol MihomoControlling: AnyObject {
    var status: CoreLifecycleStatus { get }
    var isRunning: Bool { get }
    var detectedBinaryPath: String? { get }
    @discardableResult
    func start(configPath: String, controller: String) throws -> CoreLifecycleStatus
    func stop()
    @discardableResult
    func restart(configPath: String, controller: String) throws -> CoreLifecycleStatus
}
