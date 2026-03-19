import Foundation

@MainActor
extension AppState {
    func switchToMachineTarget(_ target: MachineTarget) async {
        remoteMachineStore.selectTarget(target)

        cancelPolling()
        resetTrafficPresentation()
        proxyGroups = []
        ruleItems = []
        connectionsStore.connections = []
        connectionsStore.connectionsCount = 0

        switch target {
        case .local:
            appendLog(level: "info", message: tr("log.remote.switched_to_local"))
            if let configPath = await resolveSelectedConfigPath() {
                applyExternalControllerFromSelectedConfigFile(configPath: configPath)
            } else {
                let fallback = "127.0.0.1:9090"
                controller = fallback
                controllerSecret = nil
                externalControllerDisplay = fallback
                controllerUIURL = makeControllerUIURL(fallback)
                ensureAPIClient()
            }
            if let snapshot = loadPersistedEditableSettingsSnapshot() {
                applyEditableSettingsSnapshotToUI(snapshot)
                preserveLocalSettingsOnNextSync = true
                pendingAppLaunchOverlaySettings = snapshot
            }
            lastSyncedEditableSettings = nil

        case let .remote(machine):
            appendLog(level: "info", message: tr("log.remote.switched_to_remote", machine.name, machine.displayAddress))
            controller = machine.controllerAddress
            controllerSecret = machine.secret
            externalControllerDisplay = machine.displayAddress
            controllerUIURL = makeControllerUIURL(machine.controllerAddress)
            ensureAPIClient()
            lastSyncedEditableSettings = nil
            preserveLocalSettingsOnNextSync = false
            remoteMachineStore.checkConnectivity(for: machine)
        }

        await refreshFromAPI(includeSlowCalls: true)

        if case .local = target {
            await applyPendingAppLaunchSettingsOverlayIfNeeded()
        }

        if apiStatus == .healthy || apiStatus == .degraded {
            startPolling()
        }
    }
}
