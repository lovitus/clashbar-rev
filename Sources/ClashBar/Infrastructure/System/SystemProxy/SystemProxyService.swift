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
    private let helperToolInstallPath = "/Library/PrivilegedHelperTools/com.clashbar.helper"
    private let helperPlistInstallPath = "/Library/LaunchDaemons/com.clashbar.helper.plist"

    private let helperRecoveryMaxAttempts = 3
    private let helperRecoveryDelayNanoseconds: UInt64 = 1_500_000_000
    private let helperResponseTimeoutNanoseconds: UInt64 = 4_000_000_000

    private enum HelperRegistrationResult {
        case ready
        case needsApproval
        case blocked(String)
        case failed(String)
    }

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
    }

    func isSystemProxyEnabled() async throws -> Bool {
        try self.ensureHelperReadyForRead()
        return try await self.invokeStateQueryWithoutRecovery()
    }

    func readSystemProxyActiveDisplay() async throws -> String? {
        try self.ensureHelperReadyForRead()
        guard let target = try await self.invokeActiveTargetQuery() else {
            return nil
        }
        return self.formatProxyDisplay(host: target.host, port: target.port)
    }

    func isSystemProxyConfigured(host: String, ports: SystemProxyPorts) async throws -> Bool {
        try self.validateHost(host)
        let resolvedPorts = try validateAndResolvePorts(ports, requiresEnabledPort: true)
        try self.ensureHelperReadyForRead()
        return try await self.invokeBooleanQuery { helper, completion in
            helper.isSystemProxyConfigured(
                host: host,
                httpPort: resolvedPorts.httpPort,
                httpsPort: resolvedPorts.httpsPort,
                socksPort: resolvedPorts.socksPort,
                completion: completion)
        }
    }

    func diagnoseCurrentHelper() async -> SystemProxyHelperDiagnosis {
        if !self.isHelperBundledInMainApp() {
            return .failed(message: self.helperFailureMessage(SystemProxyServiceError.helperNotBundled))
        }
        if self.isRunningFromReadOnlyVolume() {
            return .failed(message: self.helperFailureMessage(SystemProxyServiceError.helperRequiresInstallToApplications))
        }

        do {
            try self.ensureHelperReadyForRead()
            _ = try await self.invokeStateQueryWithoutRecovery()
            return .healthy
        } catch {
            return .failed(message: self.helperFailureMessage(error))
        }
    }

    func diagnoseAndRepairHelper() async -> SystemProxyHelperDiagnosis {
        if !self.isHelperBundledInMainApp() {
            return .failed(message: self.helperFailureMessage(SystemProxyServiceError.helperNotBundled))
        }
        if self.isRunningFromReadOnlyVolume() {
            return .failed(message: self.helperFailureMessage(SystemProxyServiceError.helperRequiresInstallToApplications))
        }

        for attempt in 0..<self.helperRecoveryMaxAttempts {
            do {
                try self.ensureHelperReadyForWrite()
                _ = try await self.invokeStateQueryWithoutRecovery()
                return .healthy
            } catch {
                let shouldRecoverNow = self.shouldRetryAfterRecovery(error) || self.shouldAttemptHelperMigration(error)
                if shouldRecoverNow, attempt < self.helperRecoveryMaxAttempts - 1 {
                    do {
                        try await self.recoverHelperForRetry(error: error)
                        continue
                    } catch {
                        return .failed(message: self.helperFailureMessage(error))
                    }
                }
                if attempt == self.helperRecoveryMaxAttempts - 1 || !shouldRecoverNow {
                    return .failed(message: self.helperFailureMessage(error))
                }
            }
        }

        return .failed(message: "Unknown helper failure.")
    }

    func installHelperManually() async -> SystemProxyHelperDiagnosis {
        await self.manualRepairHelper(forceReinstall: false)
    }

    func reinstallHelperManually() async -> SystemProxyHelperDiagnosis {
        await self.manualRepairHelper(forceReinstall: true)
    }

    private func manualRepairHelper(forceReinstall: Bool) async -> SystemProxyHelperDiagnosis {
        if !self.isHelperBundledInMainApp() {
            return .failed(message: SystemProxyServiceError.helperNotBundled.localizedDescription)
        }
        if self.isRunningFromReadOnlyVolume() {
            return .failed(message: SystemProxyServiceError.helperRequiresInstallToApplications.localizedDescription)
        }

        do {
            if forceReinstall {
                try await self.forceReinstallInstalledHelper()
            }
            try self.ensureHelperReadyForWrite()
            _ = try await self.invokeStateQueryWithoutRecovery()
            return .healthy
        } catch {
            if !forceReinstall, self.shouldAttemptHelperMigration(error) {
                do {
                    try await self.forceReinstallInstalledHelper()
                    try self.ensureHelperReadyForWrite()
                    _ = try await self.invokeStateQueryWithoutRecovery()
                    return .healthy
                } catch {
                    return .failed(message: self.helperFailureMessage(error))
                }
            }
            return .failed(message: self.helperFailureMessage(error))
        }
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

        let firstAttempt = self.attemptHelperRegistration(openSettingsOnApproval: false)
        switch firstAttempt {
        case .ready:
            return
        case .needsApproval, .blocked, .failed:
            break
        }

        // Always try one privileged cleanup+reinstall path before giving up. This handles
        // stale/disallowed helper state across build signature changes.
        do {
            try self.forceCleanupInstalledHelperWithPrivileges()
            Thread.sleep(forTimeInterval: 0.3)
        } catch {
            throw SystemProxyServiceError.helperRegistrationFailed(error.localizedDescription)
        }

        let secondAttempt = self.attemptHelperRegistration(openSettingsOnApproval: true)
        switch secondAttempt {
        case .ready:
            return
        case .needsApproval:
            throw SystemProxyServiceError.helperNeedsApproval
        case let .blocked(message), let .failed(message):
            throw SystemProxyServiceError.helperRegistrationFailed(message)
        }
    }

    private func ensureHelperReadyForRead() throws {
        guard self.isHelperBundledInMainApp() else {
            throw SystemProxyServiceError.helperNotBundled
        }
        guard !self.isRunningFromReadOnlyVolume() else {
            throw SystemProxyServiceError.helperRequiresInstallToApplications
        }

        let daemonService = self.helperService()
        if daemonService.status == .enabled {
            return
        }
        if daemonService.status == .requiresApproval {
            throw SystemProxyServiceError.helperNeedsApproval
        }
        throw SystemProxyServiceError.helperRegistrationFailed(
            "Helper service not enabled. status=\(daemonService.status.rawValue)")
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

        let appTeam = self.signingTeamIdentifier(at: appURL)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let helperTeam = self.signingTeamIdentifier(at: helperURL)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let appHasTeam = !appTeam.isEmpty
        let helperHasTeam = !helperTeam.isEmpty

        // Allow ad-hoc/local builds where both app and helper have no TeamIdentifier.
        if !appHasTeam, !helperHasTeam {
            return
        }

        guard appHasTeam == helperHasTeam else {
            throw SystemProxyServiceError.helperInvalidSignature(
                "App/helper signing mode mismatch (one has TeamIdentifier, the other does not).")
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
                try await self.recoverHelperForRetry(error: error)
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
        do {
            try self.ensureHelperReadyForWrite()
        } catch {
            throw SystemProxyServiceError.helperRecoveryFailed(
                "\(previousError.localizedDescription) -> \(error.localizedDescription)")
        }

        try? await Task.sleep(nanoseconds: self.helperRecoveryDelayNanoseconds)
    }

    private func isLikelyBlockedBySystemPolicy(_ error: Error) -> Bool {
        let normalized = error.localizedDescription.lowercased()
        return normalized.contains("operation not permitted")
            || normalized.contains("disallowed")
            || normalized.contains("denied")
            || normalized.contains("launch constraint")
            || normalized.contains("background item")
    }

    private func shouldAttemptHelperMigration(_ error: Error) -> Bool {
        guard let serviceError = error as? SystemProxyServiceError else {
            return false
        }

        switch serviceError {
        case .helperConnectionFailed, .helperRecoveryFailed, .helperRegistrationFailed:
            return true
        case let .helperOperationFailed(message):
            let normalized = message.lowercased()
            return normalized.contains("operation not permitted")
                || normalized.contains("launch constraint")
                || normalized.contains("codesigning")
                || normalized.contains("code signing")
        case .helperNeedsApproval:
            return true
        case .helperNotBundled, .helperRequiresInstallToApplications, .helperInvalidSignature,
             .invalidHost, .invalidPort:
            return false
        }
    }

    private func attemptHelperRegistration(openSettingsOnApproval: Bool) -> HelperRegistrationResult {
        let daemonService = self.helperService()
        do {
            try daemonService.register()
        } catch {
            if daemonService.status == .enabled {
                return .ready
            }
            if daemonService.status == .requiresApproval {
                if self.isLikelyBlockedBySystemPolicy(error) {
                    return .blocked(error.localizedDescription)
                }
                if openSettingsOnApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
                return .needsApproval
            }
            if self.isLikelyBlockedBySystemPolicy(error) {
                return .blocked(error.localizedDescription)
            }
            return .failed(error.localizedDescription)
        }

        if daemonService.status == .enabled {
            return .ready
        }
        if daemonService.status == .requiresApproval {
            if openSettingsOnApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
            return .needsApproval
        }
        return .failed("Service remains unavailable after register call. status=\(daemonService.status.rawValue)")
    }

    private func forceCleanupInstalledHelperWithPrivileges() throws {
        let escapedPlist = self.shellQuoted(self.helperPlistInstallPath)
        let escapedTool = self.shellQuoted(self.helperToolInstallPath)
        let shellCommand =
            "/bin/launchctl bootout system/\(ProxyHelperConstants.machServiceName) >/dev/null 2>&1 || true" +
            " && /bin/rm -f \(escapedPlist)" +
            " && /bin/rm -f \(escapedTool)"
        let appleScript = "do shell script \"\(self.appleScriptEscaped(shellCommand))\" with administrator privileges"
        try self.runAppleScriptSynchronously(appleScript)
    }

    private func forceReinstallInstalledHelper() async throws {
        let daemonService = self.helperService()
        try? await daemonService.unregister()
        try? await Task.sleep(nanoseconds: 300_000_000)
        try self.forceCleanupInstalledHelperWithPrivileges()
        try? await Task.sleep(nanoseconds: 300_000_000)
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
