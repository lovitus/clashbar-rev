import Foundation

struct RemoteMachine: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var host: String
    var port: Int
    var secret: String?
    var useHTTPS: Bool

    var controllerAddress: String {
        let scheme = useHTTPS ? "https" : "http"
        return "\(scheme)://\(host):\(port)"
    }

    var displayAddress: String {
        "\(host):\(port)"
    }

    init(id: UUID = UUID(), name: String, host: String, port: Int = 9090, secret: String? = nil, useHTTPS: Bool = false) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.secret = secret
        self.useHTTPS = useHTTPS
    }
}

enum MachineTarget: Equatable, Hashable {
    case local
    case remote(RemoteMachine)

    var isLocal: Bool {
        if case .local = self { return true }
        return false
    }

    var remoteMachine: RemoteMachine? {
        if case let .remote(machine) = self { return machine }
        return nil
    }
}
