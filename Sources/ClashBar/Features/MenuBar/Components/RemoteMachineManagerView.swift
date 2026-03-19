import SwiftUI

struct RemoteMachineManagerView: View {
    @ObservedObject var store: RemoteMachineStore
    @State private var editingMachine: RemoteMachine?
    @State private var isAddingNew = false
    @Environment(\.dismiss) private var dismiss

    private var language: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: "clashbar.ui.language") ?? "") ?? .zhHans
    }

    private func tr(_ key: String) -> String {
        L10n.t(key, language: language)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            machineList
            Divider()
            bottomBar
        }
    }

    private var headerBar: some View {
        HStack {
            Text(tr("ui.machine.manage"))
                .font(.headline)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var machineList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if store.machines.isEmpty {
                    Text(tr("ui.machine.empty"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 100)
                } else {
                    ForEach(store.machines) { machine in
                        machineRow(machine)
                        Divider().padding(.horizontal, 16)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func machineRow(_ machine: RemoteMachine) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(machine.name)
                    .font(.system(size: 13, weight: .medium))
                Text(machine.displayAddress)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if store.activeTargetID == machine.id {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 14))
            }

            Button {
                editingMachine = machine
            } label: {
                Image(systemName: "pencil.circle")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)

            Button {
                store.removeMachine(id: machine.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var bottomBar: some View {
        HStack {
            Button {
                isAddingNew = true
            } label: {
                Label(tr("ui.machine.add"), systemImage: "plus.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .sheet(isPresented: $isAddingNew) {
            RemoteMachineEditView(store: store, machine: nil) {
                isAddingNew = false
            }
        }
        .sheet(item: $editingMachine) { machine in
            RemoteMachineEditView(store: store, machine: machine) {
                editingMachine = nil
            }
        }
    }
}

struct RemoteMachineEditView: View {
    @ObservedObject var store: RemoteMachineStore
    let machine: RemoteMachine?
    let onDismiss: () -> Void

    @State private var name: String = ""
    @State private var host: String = ""
    @State private var port: String = "9090"
    @State private var secret: String = ""
    @State private var useHTTPS: Bool = false

    private var language: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: "clashbar.ui.language") ?? "") ?? .zhHans
    }

    private func tr(_ key: String) -> String {
        L10n.t(key, language: language)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
            !host.trimmingCharacters(in: .whitespaces).isEmpty &&
            (Int(port) ?? 0) > 0 && (Int(port) ?? 0) <= 65535
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(machine == nil ? tr("ui.machine.add") : tr("ui.machine.edit"))
                .font(.headline)

            Form {
                TextField(tr("ui.machine.field.name"), text: $name)
                TextField(tr("ui.machine.field.host"), text: $host)
                TextField(tr("ui.machine.field.port"), text: $port)
                SecureField(tr("ui.machine.field.secret"), text: $secret)
                Toggle("HTTPS", isOn: $useHTTPS)
            }

            HStack {
                Button(tr("ui.action.cancel")) {
                    onDismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Spacer()

                Button(tr("ui.machine.save")) {
                    let trimmedName = name.trimmingCharacters(in: .whitespaces)
                    let trimmedHost = host.trimmingCharacters(in: .whitespaces)
                    let portValue = Int(port) ?? 9090
                    let trimmedSecret = secret.trimmingCharacters(in: .whitespaces)

                    if let existing = machine {
                        var updated = existing
                        updated.name = trimmedName
                        updated.host = trimmedHost
                        updated.port = portValue
                        updated.secret = trimmedSecret.isEmpty ? nil : trimmedSecret
                        updated.useHTTPS = useHTTPS
                        store.updateMachine(updated)
                    } else {
                        let newMachine = RemoteMachine(
                            name: trimmedName,
                            host: trimmedHost,
                            port: portValue,
                            secret: trimmedSecret.isEmpty ? nil : trimmedSecret,
                            useHTTPS: useHTTPS)
                        store.addMachine(newMachine)
                    }
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear {
            if let machine {
                name = machine.name
                host = machine.host
                port = "\(machine.port)"
                secret = machine.secret ?? ""
                useHTTPS = machine.useHTTPS
            }
        }
    }
}
