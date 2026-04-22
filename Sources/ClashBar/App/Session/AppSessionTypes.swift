import Foundation

enum RuntimeVisualStatus {
    case stopped
    case starting
    case runningHealthy
    case runningDegraded
    case failed
}

enum StartTrigger {
    case manual
    case auto
    case networkRecovery
}

enum StopTrigger {
    case manual
    case networkLoss
}

enum CoreActionState {
    case idle
    case starting
    case stopping
    case restarting
}

enum CoreUpgradeState: Equatable {
    case idle
    case running
    case succeeded
    case alreadyLatest(version: String?)
    case failed(message: String)
}

enum SystemProxyHelperRuntimeState: Equatable {
    case unknown
    case running
    case failed
}

enum SystemProxyHelperActionState: Equatable {
    case idle
    case installing
    case reinstalling
}

enum SystemProxyHelperIssue: Equatable {
    case none
    case notInstalled
    case registrationFailed
    case systemPolicyBlocked
    case signatureMismatch
    case needsApproval
    case installLocationInvalid
    case helperMissing
    case timeout
    case connectionFailed
    case operationFailed
    case permissionDenied
    case migrationFailed
    case unknown
}

enum ConfigLogLevel: String, CaseIterable {
    case silent
    case error
    case warning
    case info
    case debug
}

enum ConfigPatchValue {
    case bool(Bool)
    case int(Int)
    case string(String)
    indirect case object([String: ConfigPatchValue])

    var jsonValue: JSONValue {
        switch self {
        case let .bool(value):
            .bool(value)
        case let .int(value):
            .int(value)
        case let .string(value):
            .string(value)
        case let .object(value):
            .object(value.mapValues(\.jsonValue))
        }
    }
}

enum StatusBarDisplayMode: String, CaseIterable, Identifiable {
    case iconOnly = "icon_only"
    case iconAndSpeed = "icon_and_speed"
    case speedOnly = "speed_only"

    var id: String {
        rawValue
    }
}

enum AppAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String {
        rawValue
    }
}

enum CoreMemoryControlLevel: String, CaseIterable, Identifiable {
    case off
    case mb500
    case gb1
    case gb2
    case gb5

    var id: String {
        rawValue
    }

    var titleKey: String {
        switch self {
        case .off:
            "ui.settings.core_memory_control.off"
        case .mb500:
            "ui.settings.core_memory_control.500mb"
        case .gb1:
            "ui.settings.core_memory_control.1gb"
        case .gb2:
            "ui.settings.core_memory_control.2gb"
        case .gb5:
            "ui.settings.core_memory_control.5gb"
        }
    }

    var thresholdBytes: Int64? {
        switch self {
        case .off:
            nil
        case .mb500:
            500 * 1_024 * 1_024
        case .gb1:
            1_024 * 1_024 * 1_024
        case .gb2:
            2 * 1_024 * 1_024 * 1_024
        case .gb5:
            5 * 1_024 * 1_024 * 1_024
        }
    }
}

struct DataAcquisitionPolicy: Equatable {
    let enableTrafficStream: Bool
    let enableMemoryStream: Bool
    let enableConnectionsStream: Bool
    let connectionsIntervalMilliseconds: Int?
    let enableLogsStream: Bool
    let mediumFrequencyIntervalNanoseconds: UInt64
    let lowFrequencyIntervalNanoseconds: UInt64
}

enum ProviderRefreshTrigger {
    case start
    case restart
    case configSwitch
}

enum ProviderRefreshPhase {
    case idle
    case updating
    case succeeded
    case failed
    case cancelled
}

struct ProviderRefreshStatus {
    let phase: ProviderRefreshPhase
    let trigger: ProviderRefreshTrigger?
    let progressDone: Int
    let progressTotal: Int
    let message: String?
    let updatedAt: Date?

    static let idle = ProviderRefreshStatus(
        phase: .idle,
        trigger: nil,
        progressDone: 0,
        progressTotal: 0,
        message: nil,
        updatedAt: nil)
}

struct MenuBarSpeedLines: Equatable {
    let up: String
    let down: String

    static let zero = MenuBarSpeedLines(up: "↑0K", down: "↓0K")
}

enum RemoteConfigAutoUpdatePolicy: String, CaseIterable, Identifiable, Codable {
    case disabled
    case hourly
    case every6Hours = "every_6_hours"
    case every12Hours = "every_12_hours"
    case daily

    var id: String {
        self.rawValue
    }

    var interval: TimeInterval? {
        switch self {
        case .disabled:
            nil
        case .hourly:
            60 * 60
        case .every6Hours:
            6 * 60 * 60
        case .every12Hours:
            12 * 60 * 60
        case .daily:
            24 * 60 * 60
        }
    }

    var titleKey: String {
        switch self {
        case .disabled:
            "ui.quick.remote_auto_update.disabled"
        case .hourly:
            "ui.quick.remote_auto_update.hourly"
        case .every6Hours:
            "ui.quick.remote_auto_update.every_6_hours"
        case .every12Hours:
            "ui.quick.remote_auto_update.every_12_hours"
        case .daily:
            "ui.quick.remote_auto_update.daily"
        }
    }

    var isEnabled: Bool {
        self.interval != nil
    }
}

struct MenuBarDisplay: Equatable {
    let mode: StatusBarDisplayMode
    let symbolName: String?
    let speedLines: MenuBarSpeedLines?
    let isRunning: Bool
}

struct CoreFeatureRecoveryState {
    let systemProxyEnabled: Bool
    let tunEnabled: Bool

    var shouldRecoverAnyFeature: Bool {
        self.systemProxyEnabled || self.tunEnabled
    }
}

struct EditableSettingsSnapshot: Equatable, Codable {
    let allowLan: Bool
    let ipv6: Bool
    let tcpConcurrent: Bool
    let tunEnabled: Bool
    let logLevel: String
    let port: String
    let socksPort: String
    let mixedPort: String
    let redirPort: String
    let tproxyPort: String

    private enum CodingKeys: String, CodingKey {
        case allowLan
        case ipv6
        case tcpConcurrent
        case tunEnabled
        case logLevel
        case port
        case socksPort
        case mixedPort
        case redirPort
        case tproxyPort
    }

    init(config: ConfigSnapshot) {
        self.allowLan = config.allowLan ?? false
        self.ipv6 = config.ipv6 ?? false
        self.tcpConcurrent = config.tcpConcurrent ?? false
        self.tunEnabled = config.tunEnabled ?? false
        self.logLevel = ConfigLogLevel(rawValue: config.logLevel ?? "")?.rawValue ?? ConfigLogLevel.info.rawValue
        self.port = config.port.map(String.init) ?? ""
        self.socksPort = config.socksPort.map(String.init) ?? ""
        self.mixedPort = config.mixedPort.map(String.init) ?? ""
        self.redirPort = config.redirPort.map(String.init) ?? ""
        self.tproxyPort = config.tproxyPort.map(String.init) ?? ""
    }

    init(
        allowLan: Bool,
        ipv6: Bool,
        tcpConcurrent: Bool,
        tunEnabled: Bool,
        logLevel: String,
        port: String,
        socksPort: String,
        mixedPort: String,
        redirPort: String,
        tproxyPort: String)
    {
        self.allowLan = allowLan
        self.ipv6 = ipv6
        self.tcpConcurrent = tcpConcurrent
        self.tunEnabled = tunEnabled
        self.logLevel = logLevel
        self.port = port
        self.socksPort = socksPort
        self.mixedPort = mixedPort
        self.redirPort = redirPort
        self.tproxyPort = tproxyPort
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.allowLan = try container.decode(Bool.self, forKey: .allowLan)
        self.ipv6 = try container.decode(Bool.self, forKey: .ipv6)
        self.tcpConcurrent = try container.decodeIfPresent(Bool.self, forKey: .tcpConcurrent) ?? false
        self.tunEnabled = try container.decodeIfPresent(Bool.self, forKey: .tunEnabled) ?? false
        self.logLevel = try container.decode(String.self, forKey: .logLevel)
        self.port = try container.decode(String.self, forKey: .port)
        self.socksPort = try container.decode(String.self, forKey: .socksPort)
        self.mixedPort = try container.decode(String.self, forKey: .mixedPort)
        self.redirPort = try container.decode(String.self, forKey: .redirPort)
        self.tproxyPort = try container.decode(String.self, forKey: .tproxyPort)
    }
}

extension EditableSettingsSnapshot {
    func withTunEnabled(_ enabled: Bool) -> EditableSettingsSnapshot {
        EditableSettingsSnapshot(
            allowLan: self.allowLan,
            ipv6: self.ipv6,
            tcpConcurrent: self.tcpConcurrent,
            tunEnabled: enabled,
            logLevel: self.logLevel,
            port: self.port,
            socksPort: self.socksPort,
            mixedPort: self.mixedPort,
            redirPort: self.redirPort,
            tproxyPort: self.tproxyPort)
    }
}

struct SystemProxyPorts: Equatable {
    let httpPort: Int?
    let httpsPort: Int?
    let socksPort: Int?

    static let disabled = SystemProxyPorts(httpPort: nil, httpsPort: nil, socksPort: nil)

    var hasEnabledPort: Bool {
        self.httpPort != nil || self.httpsPort != nil || self.socksPort != nil
    }

    var primaryPort: Int? {
        self.httpPort ?? self.httpsPort ?? self.socksPort
    }
}
