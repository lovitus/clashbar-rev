import Foundation

@MainActor
final class RemoteMachineStore: ObservableObject {
    private static let storageKey = "clashbar.remote.machines"
    private static let activeTargetKey = "clashbar.remote.active_target_id"

    private let defaults: UserDefaults

    @Published var machines: [RemoteMachine] = []
    @Published var activeTargetID: UUID?

    var activeTarget: MachineTarget {
        guard let id = activeTargetID,
              let machine = machines.first(where: { $0.id == id })
        else {
            return .local
        }
        return .remote(machine)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.machines = Self.loadMachines(from: defaults)
        self.activeTargetID = Self.loadActiveTargetID(from: defaults)
    }

    func addMachine(_ machine: RemoteMachine) {
        self.machines.append(machine)
        self.persist()
    }

    func updateMachine(_ machine: RemoteMachine) {
        guard let index = machines.firstIndex(where: { $0.id == machine.id }) else { return }
        self.machines[index] = machine
        self.persist()
    }

    func removeMachine(id: UUID) {
        self.machines.removeAll { $0.id == id }
        if self.activeTargetID == id {
            self.activeTargetID = nil
            self.persistActiveTarget()
        }
        self.persist()
    }

    func selectTarget(_ target: MachineTarget) {
        switch target {
        case .local:
            self.activeTargetID = nil
        case let .remote(machine):
            self.activeTargetID = machine.id
        }
        self.persistActiveTarget()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(machines) else { return }
        self.defaults.set(data, forKey: Self.storageKey)
    }

    private func persistActiveTarget() {
        if let id = activeTargetID {
            self.defaults.set(id.uuidString, forKey: Self.activeTargetKey)
        } else {
            self.defaults.removeObject(forKey: Self.activeTargetKey)
        }
    }

    private static func loadMachines(from defaults: UserDefaults) -> [RemoteMachine] {
        guard let data = defaults.data(forKey: storageKey),
              let machines = try? JSONDecoder().decode([RemoteMachine].self, from: data)
        else {
            return []
        }
        return machines
    }

    private static func loadActiveTargetID(from defaults: UserDefaults) -> UUID? {
        guard let string = defaults.string(forKey: activeTargetKey) else { return nil }
        return UUID(uuidString: string)
    }
}
