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

        case let .remote(machine):
            appendLog(level: "info", message: tr("log.remote.switched_to_remote", machine.name, machine.displayAddress))
            let addr = machine.controllerAddress
            controller = addr
            controllerSecret = machine.secret
            externalControllerDisplay = machine.displayAddress
            controllerUIURL = makeControllerUIURL(addr)
            ensureAPIClient()
        }

        await refreshFromAPI(includeSlowCalls: true)

        if apiStatus == .healthy || apiStatus == .degraded {
            startPolling()
        }
    }
}
