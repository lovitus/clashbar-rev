import Foundation

@MainActor
extension AppSession {
    private var configDirectoryMonitorIntervalNanoseconds: UInt64 {
        3_000_000_000
    }

    func startConfigDirectoryMonitoringIfNeeded() {
        guard self.configDirectoryMonitorTask == nil else { return }
        guard self.ensureConfigDirectoryAvailable() != nil else { return }

        _ = self.configRepository.reloadConfigs()
        self.selectedConfigMonitorSignature = self.currentSelectedConfigMonitorSignature()

        self.configDirectoryMonitorTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: self.configDirectoryMonitorIntervalNanoseconds)
                } catch {
                    return
                }
                await self.handleConfigDirectoryChangesIfNeeded()
            }
        }
    }

    func stopConfigDirectoryMonitoring() {
        self.configDirectoryMonitorTask?.cancel()
        self.configDirectoryMonitorTask = nil
        self.selectedConfigMonitorSignature = nil
        self.pendingConfigChangeRestart = false
    }

    private func handleConfigDirectoryChangesIfNeeded() async {
        guard !self.isRemoteTarget else { return }

        if self.pendingConfigChangeRestart,
           self.isRuntimeRunning,
           !self.isCoreActionProcessing
        {
            self.pendingConfigChangeRestart = false
            self.appendLog(level: "info", message: self.tr("log.config.changed_restart"))
            await self.restartCore(trigger: .configSwitch)
            return
        }

        guard self.ensureConfigDirectoryAvailable() != nil else { return }

        let previousSelectedPath = self.configRepository.selectedConfig?.path
        let previousSelectedSignature = self.selectedConfigMonitorSignature
        _ = self.configRepository.reloadConfigs()
        let nextSelectedPath = self.syncSelectedConfigStateForMonitoring()
        self.syncConfigDisplayState()
        let nextSelectedSignature = self.currentSelectedConfigMonitorSignature()
        self.selectedConfigMonitorSignature = nextSelectedSignature

        let didSelectedConfigChange = previousSelectedPath != nextSelectedPath
        let didSelectedConfigContentChange = previousSelectedSignature != nextSelectedSignature
        guard didSelectedConfigChange || didSelectedConfigContentChange else { return }
        guard self.isRuntimeRunning else { return }

        if self.isCoreActionProcessing {
            // Skip restart chaining for in-flight TUN operations; those already include a controlled restart.
            if !self.isTunSyncing {
                self.pendingConfigChangeRestart = true
            }
            return
        }

        self.appendLog(level: "info", message: self.tr("log.config.changed_restart"))
        await self.restartCore(trigger: .configSwitch)
    }

    func currentSelectedConfigMonitorSignature() -> String? {
        guard let selected = self.configRepository.selectedConfig else { return nil }
        return self.configMonitorSignature(for: selected)
    }

    private func configMonitorSignature(for fileURL: URL) -> String {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        let values = try? fileURL.resourceValues(forKeys: keys)
        let modifiedAt = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = values?.fileSize ?? -1
        return "\(modifiedAt)-\(size)"
    }

    private func configFileName(fromPath path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    @discardableResult
    private func syncSelectedConfigStateForMonitoring() -> String? {
        guard let selected = self.configRepository.selectedConfig else {
            self.selectedConfigName = "-"
            self.defaults.removeObject(forKey: self.selectedConfigKey)
            return nil
        }

        self.selectedConfigName = selected.lastPathComponent
        self.defaults.set(selected.lastPathComponent, forKey: self.selectedConfigKey)
        return selected.path
    }
}
