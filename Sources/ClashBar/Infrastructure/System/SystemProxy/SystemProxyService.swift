import Foundation
import ProxyHelperShared
import Security
import ServiceManagement

enum SystemProxyServiceError: LocalizedError {
    case invalidHost
    case invalidPort
    case helperNotBundled
    case helperRequiresInstallToApplications
    case helperNeedsApproval
    case helperInvalidSignature(String)
    case helperRegistrationFailed(String)
    case helperRecoveryFailed(String)
    case helperConnectionFailed(String)
    case helperOperationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidHost:
            "Invalid proxy host."
        case .invalidPort:
            "Invalid proxy port."
        case .helperNotBundled:
            "Privileged helper not found in app bundle. Please rebuild and run the packaged app."
        case .helperRequiresInstallToApplications:
            "Privileged helper can only be installed from /Applications. " +
                "Move ClashBar.app to /Applications and reopen it."
        case .helperNeedsApproval:
            "Privileged helper requires approval in System Settings > Login Items."
        case let .helperInvalidSignature(message):
            "Privileged helper signature invalid: \(message)"
        case let .helperRegistrationFailed(message):
            "Failed to register privileged helper: \(message)"
        case let .helperRecoveryFailed(message):
            "Failed to recover privileged helper: \(message)"
        case let .helperConnectionFailed(message):
            "Failed to connect privileged helper: \(message)"
        case let .helperOperationFailed(message):
            "Privileged helper operation failed: \(message)"
        }
    }
}

private final class ContinuationBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<Value, Error>) {
        self.lock.lock()
        guard let continuation else {
            self.lock.unlock()
            return
        }
        self.continuation = nil
        self.lock.unlock()

        switch result {
        case let .success(value):
            continuation.resume(returning: value)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}

struct SystemProxyService {
    private let helperRecoveryMaxAttempts = 3
    private let helperRecoveryDelayNanoseconds: UInt64 = 1_500_000_000
    private let helperResponseTimeoutNanoseconds: UInt64 = 4_000_000_000
    private let fallbackReasonPrefix = "Using elevated system command fallback."

    func warmUpHelperIfPossible() async {
        guard self.isHelperBundledInMainApp() else { return }
        guard !self.isRunningFromReadOnlyVolume() else { return }

        let daemonService = self.helperService()
        switch daemonService.status {
        case .enabled:
            break
        case .notRegistered:
            do {
                try daemonService.register()
            } catch {
                guard daemonService.status == .enabled else { return }
            }
        case .requiresApproval, .notFound:
            return
        @unknown default:
            return
        }

        guard daemonService.status == .enabled else { return }
        _ = try? await self.invokeStateQueryWithRecovery()
    }

    func applySystemProxy(enabled: Bool, host: String, ports: SystemProxyPorts) async throws {
        try self.validateHost(host)

        do {
            if enabled {
                let resolvedPorts = try validateAndResolvePorts(ports, requiresEnabledPort: true)
                try await invokeMutationWithRecovery { helper, completion in
                    helper.clearSystemProxy(completion: completion)
                }
                try await invokeMutationWithRecovery { helper, completion in
                    helper.setSystemProxy(
                        host: host,
                        httpPort: resolvedPorts.httpPort,
                        httpsPort: resolvedPorts.httpsPort,
                        socksPort: resolvedPorts.socksPort,
                        completion: completion)
                }
            } else {
                try await self.invokeMutationWithRecovery { helper, completion in
                    helper.clearSystemProxy(completion: completion)
                }
            }
        } catch {
            guard self.shouldUseFallbackMode(error) else {
                throw error
            }
            try self.applySystemProxyFallback(enabled: enabled, host: host, ports: ports)
        }
    }

    func isSystemProxyEnabled() async throws -> Bool {
        do {
            let daemonService = self.helperService()
            guard daemonService.status == .enabled else {
                throw SystemProxyServiceError.helperRegistrationFailed(
                    "Helper service not enabled. status=\(daemonService.status.rawValue)")
            }
            return try await self.invokeStateQueryWithRecovery()
        } catch {
            guard self.shouldUseFallbackMode(error) else {
                throw error
            }
            return try self.readFallbackProxySnapshot().isEnabled
        }
    }

    func readSystemProxyActiveDisplay() async throws -> String? {
        do {
            let daemonService = self.helperService()
            guard daemonService.status == .enabled else {
                throw SystemProxyServiceError.helperRegistrationFailed(
                    "Helper service not enabled. status=\(daemonService.status.rawValue)")
            }

            guard let target = try await self.invokeActiveTargetQueryWithRecovery() else {
                return nil
            }
            return self.formatProxyDisplay(host: target.host, port: target.port)
        } catch {
            guard self.shouldUseFallbackMode(error) else {
                throw error
            }
            guard let target = try self.readFallbackProxySnapshot().activeTarget else {
                return nil
            }
            return self.formatProxyDisplay(host: target.host, port: target.port)
        }
    }

    func isSystemProxyConfigured(host: String, ports: SystemProxyPorts) async throws -> Bool {
        try self.validateHost(host)
        let resolvedPorts = try validateAndResolvePorts(ports, requiresEnabledPort: true)
        do {
            let daemonService = self.helperService()
            guard daemonService.status == .enabled else {
                throw SystemProxyServiceError.helperRegistrationFailed(
                    "Helper service not enabled. status=\(daemonService.status.rawValue)")
            }

            return try await self.invokeBooleanQueryWithRecovery { helper, completion in
                helper.isSystemProxyConfigured(
                    host: host,
                    httpPort: resolvedPorts.httpPort,
                    httpsPort: resolvedPorts.httpsPort,
                    socksPort: resolvedPorts.socksPort,
                    completion: completion)
            }
        } catch {
            guard self.shouldUseFallbackMode(error) else {
                throw error
            }
            return try self.readFallbackProxySnapshot().matches(
                expectedHost: host,
                httpPort: resolvedPorts.httpPort,
                httpsPort: resolvedPorts.httpsPort,
                socksPort: resolvedPorts.socksPort)
        }
    }

    func diagnoseAndRepairHelper() async -> SystemProxyHelperDiagnosis {
        if !self.isHelperBundledInMainApp() {
            return .fallback(message: self.fallbackDiagnosisMessage(SystemProxyServiceError.helperNotBundled))
        }
        if self.isRunningFromReadOnlyVolume() {
            return .fallback(message: self.fallbackDiagnosisMessage(SystemProxyServiceError.helperRequiresInstallToApplications))
        }

        for attempt in 0..<self.helperRecoveryMaxAttempts {
            do {
                try self.ensureHelperReadyForWrite()
                _ = try await self.invokeStateQueryWithoutRecovery()
                return .healthy
            } catch {
                if self.shouldUseFallbackMode(error) {
                    return .fallback(message: self.fallbackDiagnosisMessage(error))
                }
                if attempt == self.helperRecoveryMaxAttempts - 1 {
                    return .failed(message: self.helperFailureMessage(error))
                }
                do {
                    try await self.recoverHelperForRetry(error: error)
                } catch {
                    return .failed(message: self.helperFailureMessage(error))
                }
            }
        }

        return .failed(message: "Unknown helper failure.")
    }

    private func validateHost(_ host: String) throws {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            throw SystemProxyServiceError.invalidHost
        }
    }

    private func validateAndResolvePorts(
        _ ports: SystemProxyPorts,
        requiresEnabledPort: Bool) throws -> (httpPort: Int, httpsPort: Int, socksPort: Int)
    {
        let httpPort = try normalizePort(ports.httpPort)
        let httpsPort = try normalizePort(ports.httpsPort)
        let socksPort = try normalizePort(ports.socksPort)

        if requiresEnabledPort, httpPort == 0, httpsPort == 0, socksPort == 0 {
            throw SystemProxyServiceError.invalidPort
        }

        return (httpPort: httpPort, httpsPort: httpsPort, socksPort: socksPort)
    }

    private func normalizePort(_ value: Int?) throws -> Int {
        guard let value else { return 0 }
        guard (1...65535).contains(value) else {
            throw SystemProxyServiceError.invalidPort
        }
        return value
    }

    private func ensureHelperReadyForWrite() throws {
        guard self.isHelperBundledInMainApp() else {
            throw SystemProxyServiceError.helperNotBundled
        }
        guard !self.isRunningFromReadOnlyVolume() else {
            throw SystemProxyServiceError.helperRequiresInstallToApplications
        }
        try self.validateHelperSigningRequirements()

        let daemonService = self.helperService()
        do {
            try daemonService.register()
        } catch {
            if daemonService.status == .enabled {
                return
            }
            if daemonService.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
                throw SystemProxyServiceError.helperNeedsApproval
            }
            throw SystemProxyServiceError.helperRegistrationFailed(error.localizedDescription)
        }

        if daemonService.status == .enabled {
            return
        }

        if daemonService.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            throw SystemProxyServiceError.helperNeedsApproval
        }

        throw SystemProxyServiceError
            .helperRegistrationFailed(
                "Service remains unavailable after register call. status=\(daemonService.status.rawValue)")
    }

    private func isHelperBundledInMainApp() -> Bool {
        let bundleURL = Bundle.main.bundleURL
        let fileManager = FileManager.default

        let plistURL = bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons", isDirectory: true)
            .appendingPathComponent(ProxyHelperConstants.daemonPlistName, isDirectory: false)
        let helperURL = bundleURL
            .appendingPathComponent(ProxyHelperConstants.helperBundleProgram, isDirectory: false)

        return fileManager.fileExists(atPath: plistURL.path) && fileManager.fileExists(atPath: helperURL.path)
    }

    private func isRunningFromReadOnlyVolume() -> Bool {
        do {
            let values = try Bundle.main.bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey])
            return values.volumeIsReadOnly == true
        } catch {
            return false
        }
    }

    private func helperService() -> SMAppService {
        SMAppService.daemon(plistName: ProxyHelperConstants.daemonPlistName)
    }

    private func validateHelperSigningRequirements() throws {
        let appURL = Bundle.main.bundleURL
        let helperURL = appURL.appendingPathComponent(ProxyHelperConstants.helperBundleProgram, isDirectory: false)

        guard let appTeam = self.signingTeamIdentifier(at: appURL), !appTeam.isEmpty else {
            throw SystemProxyServiceError.helperInvalidSignature(
                "Main app is not signed with a valid TeamIdentifier. Use a signed .app/.dmg build.")
        }
        guard let helperTeam = self.signingTeamIdentifier(at: helperURL), !helperTeam.isEmpty else {
            throw SystemProxyServiceError.helperInvalidSignature(
                "Helper binary is not signed with a valid TeamIdentifier. Reinstall the signed app build.")
        }
        guard appTeam == helperTeam else {
            throw SystemProxyServiceError.helperInvalidSignature(
                "App and helper TeamIdentifier mismatch (\(appTeam) != \(helperTeam)).")
        }
    }

    private func signingTeamIdentifier(at url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }

        var info: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &info) == errSecSuccess,
            let dict = info as? [String: Any]
        else { return nil }

        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private func invokeMutationWithRecovery(
        _ invoke: @escaping (ProxyHelperProtocol, @escaping (Bool, String?) -> Void) -> Void) async throws
    {
        var attempt = 0
        var lastError: Error?

        while attempt < self.helperRecoveryMaxAttempts {
            do {
                try self.ensureHelperReadyForWrite()
                try await self.invokeMutation(invoke)
                return
            } catch {
                lastError = error
                let shouldRetry = self.shouldRetryAfterRecovery(error)
                if !shouldRetry || attempt == self.helperRecoveryMaxAttempts - 1 {
                    throw error
                }
                try await self.recoverHelperForRetry(error: error)
                attempt += 1
            }
        }

        throw lastError ?? SystemProxyServiceError.helperOperationFailed("Unknown helper mutation failure.")
    }

    private func invokeStateQueryWithRecovery() async throws -> Bool {
        try await self.invokeBooleanQueryWithRecovery { helper, completion in
            helper.getSystemProxyState(completion: completion)
        }
    }

    private func invokeStateQueryWithoutRecovery() async throws -> Bool {
        try await self.invokeBooleanQuery { helper, completion in
            helper.getSystemProxyState(completion: completion)
        }
    }

    private func invokeActiveTargetQueryWithRecovery() async throws -> (host: String, port: Int)? {
        var attempt = 0
        var lastError: Error?

        while attempt < self.helperRecoveryMaxAttempts {
            do {
                return try await self.invokeActiveTargetQuery()
            } catch {
                lastError = error
                guard self.shouldRetryAfterRecovery(error) else { throw error }
                guard attempt < self.helperRecoveryMaxAttempts - 1 else { throw error }
                try await self.recoverHelperForRetry(error: error)
                attempt += 1
            }
        }

        throw lastError ?? SystemProxyServiceError.helperOperationFailed("Unknown helper query failure.")
    }

    private func invokeBooleanQueryWithRecovery(
        _ invoke: @escaping (ProxyHelperProtocol, @escaping (Bool, Bool, String?) -> Void) -> Void) async throws -> Bool
    {
        var attempt = 0
        var lastError: Error?

        while attempt < self.helperRecoveryMaxAttempts {
            do {
                return try await self.invokeBooleanQuery(invoke)
            } catch {
                lastError = error
                guard self.shouldRetryAfterRecovery(error) else { throw error }
                guard attempt < self.helperRecoveryMaxAttempts - 1 else { throw error }
                try? await Task.sleep(nanoseconds: self.helperRecoveryDelayNanoseconds)
                attempt += 1
            }
        }

        throw lastError ?? SystemProxyServiceError.helperOperationFailed("Unknown helper query failure.")
    }

    private func shouldRetryAfterRecovery(_ error: Error) -> Bool {
        guard let serviceError = error as? SystemProxyServiceError else {
            return false
        }

        switch serviceError {
        case .helperConnectionFailed, .helperOperationFailed, .helperRegistrationFailed:
            return true
        case .helperNeedsApproval, .helperNotBundled, .helperRequiresInstallToApplications, .helperInvalidSignature,
             .invalidHost, .invalidPort, .helperRecoveryFailed:
            return false
        }
    }

    private func recoverHelperForRetry(error previousError: Error) async throws {
        let daemonService = self.helperService()
        if daemonService.status == .enabled {
            // Stale launchd registrations can point to outdated helper paths after upgrades.
            // Force a re-register before retrying to refresh launch metadata.
            try? await daemonService.unregister()
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        do {
            try daemonService.register()
        } catch {
            switch daemonService.status {
            case .enabled:
                // Helper 已注册且已批准，register() 抛出 "already registered" 属于正常情况，
                // 此时 daemon 可能正由 launchd 启动中，等待即可
                break
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
                throw SystemProxyServiceError.helperNeedsApproval
            default:
                throw SystemProxyServiceError.helperRecoveryFailed(
                    "\(previousError.localizedDescription) -> \(error.localizedDescription)")
            }
        }

        if daemonService.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            throw SystemProxyServiceError.helperNeedsApproval
        }

        try? await Task.sleep(nanoseconds: self.helperRecoveryDelayNanoseconds)
    }

    private func invokeMutation(
        _ invoke: @escaping (ProxyHelperProtocol, @escaping (Bool, String?) -> Void) -> Void) async throws
    {
        try await self.invokeHelper { helper, completion in
            invoke(helper) { success, message in
                if success {
                    completion(.success(()))
                    return
                }
                completion(.failure(SystemProxyServiceError.helperOperationFailed(message ?? "Unknown helper error.")))
            }
        }
    }

    private func invokeBooleanQuery(
        _ invoke: @escaping (ProxyHelperProtocol, @escaping (Bool, Bool, String?) -> Void) -> Void) async throws -> Bool
    {
        try await self.invokeHelper { helper, completion in
            invoke(helper) { success, boolValue, message in
                if success {
                    completion(.success(boolValue))
                    return
                }
                completion(.failure(SystemProxyServiceError.helperOperationFailed(message ?? "Unknown helper error.")))
            }
        }
    }

    private func invokeActiveTargetQuery() async throws -> (host: String, port: Int)? {
        try await self.invokeHelper { helper, completion in
            helper.getSystemProxyActiveTarget { success, host, port, message in
                if success {
                    guard let host, !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, port > 0 else {
                        completion(.success(nil))
                        return
                    }
                    completion(.success((host: host, port: port)))
                    return
                }
                completion(.failure(SystemProxyServiceError.helperOperationFailed(message ?? "Unknown helper error.")))
            }
        }
    }

    private func formatProxyDisplay(host: String, port: Int) -> String {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedHost.contains(":"), !trimmedHost.hasPrefix("[") {
            return "[\(trimmedHost)]:\(port)"
        }
        return "\(trimmedHost):\(port)"
    }

    private func helperFailureMessage(_ error: Error) -> String {
        if let serviceError = error as? SystemProxyServiceError {
            return serviceError.localizedDescription
        }
        return error.localizedDescription
    }

    private func fallbackDiagnosisMessage(_ error: Error) -> String {
        "\(self.fallbackReasonPrefix) \(self.helperFailureMessage(error))"
    }

    private func shouldUseFallbackMode(_ error: Error) -> Bool {
        guard let serviceError = error as? SystemProxyServiceError else {
            return false
        }

        switch serviceError {
        case .helperInvalidSignature, .helperRegistrationFailed, .helperRecoveryFailed, .helperConnectionFailed,
             .helperNeedsApproval, .helperNotBundled, .helperRequiresInstallToApplications, .helperOperationFailed:
            return true
        case .invalidHost, .invalidPort:
            return false
        }
    }

    private func applySystemProxyFallback(enabled: Bool, host: String, ports: SystemProxyPorts) throws {
        let resolvedPorts: (httpPort: Int, httpsPort: Int, socksPort: Int) = if enabled {
            try self.validateAndResolvePorts(ports, requiresEnabledPort: true)
        } else {
            (0, 0, 0)
        }
        let services = try self.listAllNetworkServices()
        guard !services.isEmpty else {
            throw SystemProxyServiceError.helperOperationFailed("No enabled network services found.")
        }

        var commands: [String] = []
        for service in services {
            let escapedService = self.shellQuoted(service)
            if enabled {
                commands += self.proxyCommands(
                    service: escapedService,
                    host: host,
                    httpPort: resolvedPorts.httpPort,
                    httpsPort: resolvedPorts.httpsPort,
                    socksPort: resolvedPorts.socksPort)
            } else {
                commands += self.clearProxyCommands(service: escapedService)
            }
        }

        let shellCommand = commands.joined(separator: " && ")
        let appleScript = "do shell script \"\(self.appleScriptEscaped(shellCommand))\" with administrator privileges"
        try self.runAppleScriptSynchronously(appleScript)
    }

    private func proxyCommands(
        service: String,
        host: String,
        httpPort: Int,
        httpsPort: Int,
        socksPort: Int) -> [String]
    {
        let escapedHost = self.shellQuoted(host)
        var commands: [String] = []

        if httpPort > 0 {
            commands.append("/usr/sbin/networksetup -setwebproxy \(service) \(escapedHost) \(httpPort)")
            commands.append("/usr/sbin/networksetup -setwebproxystate \(service) on")
        } else {
            commands.append("/usr/sbin/networksetup -setwebproxystate \(service) off")
        }

        if httpsPort > 0 {
            commands.append("/usr/sbin/networksetup -setsecurewebproxy \(service) \(escapedHost) \(httpsPort)")
            commands.append("/usr/sbin/networksetup -setsecurewebproxystate \(service) on")
        } else {
            commands.append("/usr/sbin/networksetup -setsecurewebproxystate \(service) off")
        }

        if socksPort > 0 {
            commands.append("/usr/sbin/networksetup -setsocksfirewallproxy \(service) \(escapedHost) \(socksPort)")
            commands.append("/usr/sbin/networksetup -setsocksfirewallproxystate \(service) on")
        } else {
            commands.append("/usr/sbin/networksetup -setsocksfirewallproxystate \(service) off")
        }

        return commands
    }

    private func clearProxyCommands(service: String) -> [String] {
        [
            "/usr/sbin/networksetup -setwebproxystate \(service) off",
            "/usr/sbin/networksetup -setsecurewebproxystate \(service) off",
            "/usr/sbin/networksetup -setsocksfirewallproxystate \(service) off",
        ]
    }

    private func listAllNetworkServices() throws -> [String] {
        let result = try self.runProcessSynchronously(
            executable: "/usr/sbin/networksetup",
            arguments: ["-listallnetworkservices"])
        guard result.exitCode == 0 else {
            throw SystemProxyServiceError.helperOperationFailed(result.combinedOutput)
        }

        return result.stdout
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { !$0.hasPrefix("An asterisk") }
            .filter { !$0.hasPrefix("*") }
    }

    private struct FallbackProxySnapshot {
        let httpEnabled: Bool
        let httpHost: String
        let httpPort: Int
        let httpsEnabled: Bool
        let httpsHost: String
        let httpsPort: Int
        let socksEnabled: Bool
        let socksHost: String
        let socksPort: Int

        var isEnabled: Bool {
            self.httpEnabled || self.httpsEnabled || self.socksEnabled
        }

        var activeTarget: (host: String, port: Int)? {
            if self.httpEnabled, self.httpPort > 0, !self.httpHost.isEmpty {
                return (self.httpHost, self.httpPort)
            }
            if self.httpsEnabled, self.httpsPort > 0, !self.httpsHost.isEmpty {
                return (self.httpsHost, self.httpsPort)
            }
            if self.socksEnabled, self.socksPort > 0, !self.socksHost.isEmpty {
                return (self.socksHost, self.socksPort)
            }
            return nil
        }

        func matches(expectedHost: String, httpPort: Int, httpsPort: Int, socksPort: Int) -> Bool {
            let normalizedExpectedHost = expectedHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return self.matchesEntry(
                enabled: self.httpEnabled,
                host: self.httpHost,
                port: self.httpPort,
                expectedHost: normalizedExpectedHost,
                expectedPort: httpPort)
                && self.matchesEntry(
                    enabled: self.httpsEnabled,
                    host: self.httpsHost,
                    port: self.httpsPort,
                    expectedHost: normalizedExpectedHost,
                    expectedPort: httpsPort)
                && self.matchesEntry(
                    enabled: self.socksEnabled,
                    host: self.socksHost,
                    port: self.socksPort,
                    expectedHost: normalizedExpectedHost,
                    expectedPort: socksPort)
        }

        private func matchesEntry(
            enabled: Bool,
            host: String,
            port: Int,
            expectedHost: String,
            expectedPort: Int) -> Bool
        {
            if expectedPort == 0 {
                return !enabled
            }
            guard enabled else { return false }
            return host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == expectedHost && port == expectedPort
        }
    }

    private func readFallbackProxySnapshot() throws -> FallbackProxySnapshot {
        let result = try self.runProcessSynchronously(
            executable: "/usr/sbin/scutil",
            arguments: ["--proxy"])
        guard result.exitCode == 0 else {
            throw SystemProxyServiceError.helperOperationFailed(result.combinedOutput)
        }

        let dict = self.parseScutilProxyOutput(result.stdout)
        return FallbackProxySnapshot(
            httpEnabled: self.boolValue(dict["HTTPEnable"]),
            httpHost: self.stringValue(dict["HTTPProxy"]),
            httpPort: self.intValue(dict["HTTPPort"]),
            httpsEnabled: self.boolValue(dict["HTTPSEnable"]),
            httpsHost: self.stringValue(dict["HTTPSProxy"]),
            httpsPort: self.intValue(dict["HTTPSPort"]),
            socksEnabled: self.boolValue(dict["SOCKSEnable"]),
            socksHost: self.stringValue(dict["SOCKSProxy"]),
            socksPort: self.intValue(dict["SOCKSPort"]))
    }

    private func parseScutilProxyOutput(_ text: String) -> [String: String] {
        var output: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                output[key] = value
            }
        }
        return output
    }

    private func boolValue(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return value == "1" || value == "true" || value == "yes"
    }

    private func intValue(_ value: String?) -> Int {
        Int(value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    }

    private func stringValue(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String

        var combinedOutput: String {
            [self.stderr, self.stdout]
                .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown command error."
        }
    }

    private func runProcessSynchronously(executable: String, arguments: [String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw SystemProxyServiceError.helperOperationFailed(error.localizedDescription)
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    private func runAppleScriptSynchronously(_ script: String) throws {
        let result = try self.runProcessSynchronously(executable: "/usr/bin/osascript", arguments: ["-e", script])
        guard result.exitCode == 0 else {
            let message = result.combinedOutput
            if message.lowercased().contains("user canceled") {
                throw SystemProxyServiceError.helperOperationFailed("Administrator authorization was cancelled.")
            }
            throw SystemProxyServiceError.helperOperationFailed(message)
        }
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func invokeHelper<Value: Sendable>(
        _ invoke: @escaping (ProxyHelperProtocol, @escaping (Result<Value, Error>) -> Void) -> Void) async throws
        -> Value
    {
        try await withCheckedThrowingContinuation { continuation in
            let connection = self.makeConnection()
            let box = ContinuationBox<Value>(continuation)
            let timeoutWorkItem = DispatchWorkItem {
                connection.invalidate()
                box.resume(
                    with: .failure(
                        SystemProxyServiceError.helperConnectionFailed("Helper response timed out.")))
            }
            let timeoutInterval = DispatchTimeInterval.nanoseconds(Int(self.helperResponseTimeoutNanoseconds))
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + timeoutInterval,
                execute: timeoutWorkItem)

            guard let helper = connection.remoteObjectProxyWithErrorHandler({ error in
                timeoutWorkItem.cancel()
                connection.invalidate()
                box.resume(with: .failure(SystemProxyServiceError.helperConnectionFailed(error.localizedDescription)))
            }) as? ProxyHelperProtocol else {
                timeoutWorkItem.cancel()
                connection.invalidate()
                box
                    .resume(with: .failure(SystemProxyServiceError
                            .helperConnectionFailed("Unable to create XPC proxy.")))
                return
            }

            invoke(helper) { result in
                timeoutWorkItem.cancel()
                defer { connection.invalidate() }
                box.resume(with: result)
            }
        }
    }

    func clearSystemProxyBlocking(timeout: TimeInterval = 2.0) {
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            let connection = NSXPCConnection(
                machServiceName: ProxyHelperConstants.machServiceName,
                options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: ProxyHelperProtocol.self)
            connection.activate()

            guard let helper = connection.remoteObjectProxyWithErrorHandler({ _ in
                semaphore.signal()
            }) as? ProxyHelperProtocol else {
                connection.invalidate()
                semaphore.signal()
                return
            }

            helper.clearSystemProxy { _, _ in
                connection.invalidate()
                semaphore.signal()
            }
        }

        _ = semaphore.wait(timeout: .now() + timeout)
    }

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(
            machServiceName: ProxyHelperConstants.machServiceName,
            options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: ProxyHelperProtocol.self)
        connection.activate()
        return connection
    }
}
