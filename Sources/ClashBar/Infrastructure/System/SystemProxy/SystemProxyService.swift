import Foundation
import ProxyHelperShared
import Security
import ServiceManagement

enum SystemProxyServiceError: LocalizedError {
    case invalidHost
    case invalidPort
    case helperNotBundled
    case helperNotInstalled
    case helperRequiresInstallToApplications
    case helperNeedsApproval
    case helperBlockedBySystemPolicy(String)
    case helperInvalidSignature(String)
    case helperRegistrationFailed(String)
    case helperConnectionFailed(String)
    case helperOperationFailed(String)
    case missingSigningIdentity

    var errorDescription: String? {
        switch self {
        case .invalidHost:
            "Invalid proxy host."
        case .invalidPort:
            "Invalid proxy port."
        case .helperNotBundled:
            "Privileged helper not found in app bundle. Please rebuild and run the packaged app."
        case .helperNotInstalled:
            "Privileged helper is not installed. Use Install or Reinstall helper."
        case .helperRequiresInstallToApplications:
            "Privileged helper can only be installed from /Applications. " +
                "Move ClashBar.app to /Applications and reopen it."
        case .helperNeedsApproval:
            "Privileged helper requires approval in System Settings > Login Items."
        case let .helperBlockedBySystemPolicy(message):
            "Privileged helper was blocked by system policy: \(message)"
        case let .helperInvalidSignature(message):
            "Privileged helper signature invalid: \(message)"
        case let .helperRegistrationFailed(message):
            "Failed to register privileged helper: \(message)"
        case let .helperConnectionFailed(message):
            "Failed to connect privileged helper: \(message)"
        case let .helperOperationFailed(message):
            "Privileged helper operation failed: \(message)"
        case .missingSigningIdentity:
            "No valid local code signing identity found. Install an Apple Development/Developer ID certificate, then use resign and reinstall."
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
    private let managedSigningIdentityCommonName = "ClashBar Local Code Signing"

    private let helperResponseTimeoutNanoseconds: UInt64 = 4_000_000_000
    private enum HelperRegistrationResult {
        case ready
        case needsApproval
        case blocked(String)
        case failed(String)
    }

    private struct SigningIdentity {
        let name: String
        let keychainPath: String?
        let keychainPassword: String?
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
        _ = try? await self.invokeStateQuery()
    }

    func applySystemProxy(enabled: Bool, host: String, ports: SystemProxyPorts) async throws {
        try self.validateHost(host)

        if enabled {
            let resolvedPorts = try validateAndResolvePorts(ports, requiresEnabledPort: true)
            try await invokeMutation { helper, completion in
                helper.setSystemProxy(
                    host: host,
                    httpPort: resolvedPorts.httpPort,
                    httpsPort: resolvedPorts.httpsPort,
                    socksPort: resolvedPorts.socksPort,
                    completion: completion)
            }
        } else {
            try await self.invokeMutation { helper, completion in
                helper.clearSystemProxy(completion: completion)
            }
        }
    }

    func isSystemProxyEnabled() async throws -> Bool {
        try self.ensureHelperReadyForRead()
        return try await self.invokeStateQuery()
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
            _ = try await self.invokeStateQuery()
            return .healthy
        } catch {
            return .failed(message: self.helperFailureMessage(error))
        }
    }

    func diagnoseAndRepairHelper() async -> SystemProxyHelperDiagnosis {
        // Keep this path non-privileged. Real repair is user-triggered via install/reinstall.
        await self.diagnoseCurrentHelper()
    }

    func installHelperManually() async -> SystemProxyHelperDiagnosis {
        await self.manualInstallHelper(forceReinstall: false)
    }

    func reinstallHelperManually() async -> SystemProxyHelperDiagnosis {
        await self.manualInstallHelper(forceReinstall: true)
    }

    func resignAndReinstallHelperManually() async -> SystemProxyHelperDiagnosis {
        await self.manualRepairHelperWithResign(forceReinstall: true)
    }

    private func manualInstallHelper(forceReinstall: Bool) async -> SystemProxyHelperDiagnosis {
        if !self.isHelperBundledInMainApp() {
            return .failed(message: SystemProxyServiceError.helperNotBundled.localizedDescription)
        }
        if self.isRunningFromReadOnlyVolume() {
            return .failed(message: SystemProxyServiceError.helperRequiresInstallToApplications.localizedDescription)
        }

        do {
            try await self.installOrReinstallHelper(forceReinstall: forceReinstall)
            _ = try await self.invokeStateQuery()
            return .healthy
        } catch {
            return .failed(message: self.helperFailureMessage(error))
        }
    }

    private func manualRepairHelperWithResign(forceReinstall: Bool) async -> SystemProxyHelperDiagnosis {
        if !self.isHelperBundledInMainApp() {
            return .failed(message: SystemProxyServiceError.helperNotBundled.localizedDescription)
        }
        if self.isRunningFromReadOnlyVolume() {
            return .failed(message: SystemProxyServiceError.helperRequiresInstallToApplications.localizedDescription)
        }

        do {
            let identity = try self.findLocalCodeSigningIdentity()
            try await self.repairHelperWithIdentity(identity, forceReinstall: forceReinstall)
            _ = try await self.invokeStateQuery()
            return .healthy
        } catch {
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

    private func ensureHelperReadyForWrite() async throws {
        guard self.isHelperBundledInMainApp() else {
            throw SystemProxyServiceError.helperNotBundled
        }
        guard !self.isRunningFromReadOnlyVolume() else {
            throw SystemProxyServiceError.helperRequiresInstallToApplications
        }
        try self.validateHelperSigningRequirements()

        let daemonService = self.helperService()
        if daemonService.status == .enabled {
            return
        }
        if daemonService.status == .requiresApproval {
            throw SystemProxyServiceError.helperNeedsApproval
        }

        switch self.attemptHelperRegistration() {
        case .ready:
            return
        case .needsApproval:
            throw SystemProxyServiceError.helperNeedsApproval
        case let .blocked(message):
            throw SystemProxyServiceError.helperBlockedBySystemPolicy(message)
        case let .failed(message):
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
        try self.validateHelperSigningRequirements()

        let daemonService = self.helperService()
        switch daemonService.status {
        case .enabled:
            return
        case .requiresApproval:
            throw SystemProxyServiceError.helperNeedsApproval
        case .notRegistered, .notFound:
            if self.isHelperInstalledInSystem() {
                throw SystemProxyServiceError.helperRegistrationFailed(
                    "Helper is installed but not enabled. Use Reinstall helper.")
            }
            throw SystemProxyServiceError.helperNotInstalled
        @unknown default:
            throw SystemProxyServiceError.helperRegistrationFailed(
                "Helper service not enabled. status=\(daemonService.status.rawValue)")
        }
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

    private func isHelperInstalledInSystem() -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: self.helperPlistInstallPath)
            && fileManager.fileExists(atPath: self.helperToolInstallPath)
    }

    private func helperService() -> SMAppService {
        SMAppService.daemon(plistName: ProxyHelperConstants.daemonPlistName)
    }

    private var workingDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/clashbar", isDirectory: true)
    }

    private var managedSigningDirectoryURL: URL {
        self.workingDirectoryURL.appendingPathComponent("security", isDirectory: true)
    }

    private var managedSigningKeychainURL: URL {
        self.managedSigningDirectoryURL.appendingPathComponent("clashbar-signing.keychain-db", isDirectory: false)
    }

    private var managedSigningPasswordURL: URL {
        self.managedSigningDirectoryURL.appendingPathComponent("clashbar-signing.pass", isDirectory: false)
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

    private func invokeStateQuery() async throws -> Bool {
        try await self.invokeBooleanQuery { helper, completion in
            helper.getSystemProxyState(completion: completion)
        }
    }

    private func isLikelyBlockedBySystemPolicy(_ error: Error) -> Bool {
        let normalized = error.localizedDescription.lowercased()
        return normalized.contains("operation not permitted")
            || normalized.contains("disallowed")
            || normalized.contains("denied")
            || normalized.contains("launch constraint")
            || normalized.contains("background item")
    }

    private func attemptHelperRegistration() -> HelperRegistrationResult {
        let daemonService = self.helperService()
        if daemonService.status == .enabled {
            return .ready
        }

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
            return .needsApproval
        }
        return .failed("Service remains unavailable after register call. status=\(daemonService.status.rawValue)")
    }

    private func installOrReinstallHelper(forceReinstall: Bool) async throws {
        let daemonService = self.helperService()
        if forceReinstall || daemonService.status == .enabled {
            try? await daemonService.unregister()
        }

        let escapedPlist = self.shellQuoted(self.helperPlistInstallPath)
        let escapedTool = self.shellQuoted(self.helperToolInstallPath)

        var commands: [String] = []
        commands.append("/bin/launchctl bootout system/\(ProxyHelperConstants.machServiceName) >/dev/null 2>&1 || true")
        if forceReinstall {
            commands.append("/bin/launchctl bootout system \(escapedPlist) >/dev/null 2>&1 || true")
            commands.append("/bin/launchctl disable system/\(ProxyHelperConstants.machServiceName) >/dev/null 2>&1 || true")
            commands.append("/bin/launchctl remove \(ProxyHelperConstants.machServiceName) >/dev/null 2>&1 || true")
            commands.append("/usr/bin/pkill -9 -x com.clashbar.helper >/dev/null 2>&1 || true")
            commands.append("/bin/rm -f \(escapedPlist)")
            commands.append("/bin/rm -f \(escapedTool)")
        }
        if !commands.isEmpty {
            let shellCommand = commands.joined(separator: " && ")
            let appleScript = "do shell script \"\(self.appleScriptEscaped(shellCommand))\" with administrator privileges"
            try self.runAppleScriptSynchronously(appleScript)
        }

        switch self.attemptHelperRegistration() {
        case .ready:
            return
        case .needsApproval:
            throw SystemProxyServiceError.helperNeedsApproval
        case let .blocked(message):
            throw SystemProxyServiceError.helperBlockedBySystemPolicy(message)
        case let .failed(message):
            throw SystemProxyServiceError.helperRegistrationFailed(message)
        }
    }

    private func repairHelperWithIdentity(_ identity: SigningIdentity, forceReinstall: Bool) async throws {
        let daemonService = self.helperService()
        if daemonService.status == .enabled {
            try? await daemonService.unregister()
        }

        let appPath = Bundle.main.bundleURL.path
        let helperPath = Bundle.main.bundleURL
            .appendingPathComponent(ProxyHelperConstants.helperBundleProgram, isDirectory: false)
            .path
        let escapedApp = self.shellQuoted(appPath)
        let escapedHelper = self.shellQuoted(helperPath)
        let escapedIdentity = self.shellQuoted(identity.name)
        let escapedPlist = self.shellQuoted(self.helperPlistInstallPath)
        let escapedTool = self.shellQuoted(self.helperToolInstallPath)

        var commands: [String] = []
        commands.append("/bin/launchctl bootout system/\(ProxyHelperConstants.machServiceName) >/dev/null 2>&1 || true")
        if forceReinstall {
            commands.append("/bin/rm -f \(escapedPlist)")
            commands.append("/bin/rm -f \(escapedTool)")
        }
        if let keychainPath = identity.keychainPath {
            let escapedKeychainPath = self.shellQuoted(keychainPath)
            if let keychainPassword = identity.keychainPassword {
                commands.append(
                    "/usr/bin/security unlock-keychain -p \(self.shellQuoted(keychainPassword)) \(escapedKeychainPath)")
            }
            commands.append("/usr/bin/security list-keychains -d user -s \(escapedKeychainPath)")
            commands.append(
                "/usr/bin/codesign --force --keychain \(escapedKeychainPath) --sign \(escapedIdentity) --timestamp=none --preserve-metadata=identifier,entitlements,requirements,flags \(escapedHelper)")
            commands.append(
                "/usr/bin/codesign --force --keychain \(escapedKeychainPath) --sign \(escapedIdentity) --timestamp=none --deep --preserve-metadata=identifier,entitlements,requirements,flags \(escapedApp)")
        } else {
            commands.append(
                "/usr/bin/codesign --force --sign \(escapedIdentity) --timestamp=none --preserve-metadata=identifier,entitlements,requirements,flags \(escapedHelper)")
            commands.append(
                "/usr/bin/codesign --force --sign \(escapedIdentity) --timestamp=none --deep --preserve-metadata=identifier,entitlements,requirements,flags \(escapedApp)")
        }
        commands.append("/usr/bin/codesign --verify --deep --strict --verbose=2 \(escapedApp)")

        let shellCommand = commands.joined(separator: " && ")
        let appleScript = "do shell script \"\(self.appleScriptEscaped(shellCommand))\" with administrator privileges"
        try self.runAppleScriptSynchronously(appleScript)

        switch self.attemptHelperRegistration() {
        case .ready:
            return
        case .needsApproval:
            throw SystemProxyServiceError.helperNeedsApproval
        case let .blocked(message):
            throw SystemProxyServiceError.helperBlockedBySystemPolicy(message)
        case let .failed(message):
            throw SystemProxyServiceError.helperRegistrationFailed(message)
        }
    }

    private func findLocalCodeSigningIdentity() throws -> SigningIdentity {
        if let identity = try self.firstCodeSigningIdentity() {
            return SigningIdentity(name: identity, keychainPath: nil, keychainPassword: nil)
        }
        return try self.ensureManagedCodeSigningIdentity()
    }

    private func firstCodeSigningIdentity(in keychainPath: String? = nil) throws -> String? {
        var arguments = ["find-identity", "-v", "-p", "codesigning"]
        if let keychainPath {
            arguments.append(keychainPath)
        }
        let result = try self.runProcessSynchronously(
            executable: "/usr/bin/security",
            arguments: arguments)
        guard result.exitCode == 0 else {
            throw SystemProxyServiceError.helperOperationFailed(result.combinedOutput)
        }

        let lines = result.stdout.split(whereSeparator: \.isNewline)
        for line in lines {
            let text = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.lowercased().contains("valid identities found") { continue }
            if text.contains("REVOKED") { continue }
            let parts = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 2 else { continue }
            let candidate = parts[1]
            if candidate.count == 40,
               candidate.allSatisfy({ $0.isHexDigit })
            {
                if let quotedNameStart = text.firstIndex(of: "\""),
                   let quotedNameEnd = text.lastIndex(of: "\""),
                   quotedNameStart < quotedNameEnd
                {
                    return String(text[text.index(after: quotedNameStart)..<quotedNameEnd])
                }
                return candidate
            }
        }
        return nil
    }

    private func ensureManagedCodeSigningIdentity() throws -> SigningIdentity {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: self.managedSigningDirectoryURL, withIntermediateDirectories: true)

        let keychainPath = self.managedSigningKeychainURL.path
        let keychainPassword = try self.loadOrCreateManagedSigningPassword()

        if let identity = try self.firstCodeSigningIdentity(in: keychainPath) {
            return SigningIdentity(name: identity, keychainPath: keychainPath, keychainPassword: keychainPassword)
        }

        let tempDirectoryURL = self.managedSigningDirectoryURL
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectoryURL) }

        let opensslPath = fileManager.fileExists(atPath: "/opt/homebrew/bin/openssl")
            ? "/opt/homebrew/bin/openssl"
            : "/usr/bin/openssl"
        let escapedTempDirectory = self.shellQuoted(tempDirectoryURL.path)
        let escapedKeychainPath = self.shellQuoted(keychainPath)
        let escapedKeychainPassword = self.shellQuoted(keychainPassword)

        let existingKeychainsResult = try self.runProcessSynchronously(
            executable: "/usr/bin/security",
            arguments: ["list-keychains", "-d", "user"])
        let existingKeychains = existingKeychainsResult.stdout
            .split(whereSeparator: \.isNewline)
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            .filter { !$0.isEmpty }
        var mergedKeychains = [keychainPath]
        for item in existingKeychains where item != keychainPath {
            mergedKeychains.append(item)
        }
        let escapedKeychainList = mergedKeychains.map(self.shellQuoted).joined(separator: " ")

        var commands: [String] = []
        commands.append("cd \(escapedTempDirectory)")
        commands.append("cat > openssl.cnf <<'EOF'\n[ req ]\ndistinguished_name = dn\nx509_extensions = v3_req\nprompt = no\n[ dn ]\nCN = \(self.managedSigningIdentityCommonName)\nO = ClashBar Local\n[ v3_req ]\nkeyUsage = critical,digitalSignature\nextendedKeyUsage = codeSigning\nbasicConstraints = critical,CA:false\nsubjectKeyIdentifier = hash\nauthorityKeyIdentifier = keyid,issuer\nEOF")
        commands.append(
            "\(self.shellQuoted(opensslPath)) req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes -config openssl.cnf >/dev/null 2>&1")
        commands.append(
            "\(self.shellQuoted(opensslPath)) pkcs12 -export -inkey key.pem -in cert.pem -out identity.p12 -passout pass:clashbar-local >/dev/null 2>&1")
        commands.append("if [ ! -f \(escapedKeychainPath) ]; then /usr/bin/security create-keychain -p \(escapedKeychainPassword) \(escapedKeychainPath) >/dev/null; fi")
        commands.append("/usr/bin/security unlock-keychain -p \(escapedKeychainPassword) \(escapedKeychainPath)")
        commands.append("/usr/bin/security set-keychain-settings -lut 21600 \(escapedKeychainPath)")
        commands.append("/usr/bin/security import identity.p12 -k \(escapedKeychainPath) -f pkcs12 -P clashbar-local -A -T /usr/bin/codesign >/dev/null")
        commands.append("/usr/bin/security add-trusted-cert -d -r trustRoot -k \(escapedKeychainPath) cert.pem >/dev/null")
        commands.append(
            "/usr/bin/security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k \(escapedKeychainPassword) \(escapedKeychainPath) >/dev/null")
        commands.append("/usr/bin/security list-keychains -d user -s \(escapedKeychainList)")

        let shellCommand = commands.joined(separator: " && ")
        let result = try self.runProcessSynchronously(executable: "/bin/zsh", arguments: ["-lc", shellCommand])
        guard result.exitCode == 0 else {
            throw SystemProxyServiceError.helperOperationFailed(result.combinedOutput)
        }

        if let identity = try self.firstCodeSigningIdentity(in: keychainPath) {
            return SigningIdentity(name: identity, keychainPath: keychainPath, keychainPassword: keychainPassword)
        }
        throw SystemProxyServiceError.missingSigningIdentity
    }

    private func loadOrCreateManagedSigningPassword() throws -> String {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: self.managedSigningPasswordURL.path) {
            let existing = try String(contentsOf: self.managedSigningPasswordURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !existing.isEmpty {
                return existing
            }
        }

        let password = UUID().uuidString + UUID().uuidString
        try password.write(to: self.managedSigningPasswordURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.managedSigningPasswordURL.path)
        return password
    }

    private func invokeMutation(
        _ invoke: @escaping (ProxyHelperProtocol, @escaping (Bool, String?) -> Void) -> Void) async throws
    {
        try await self.ensureHelperReadyForWrite()
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
