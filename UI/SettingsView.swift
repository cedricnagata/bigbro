import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            DevicesSettingsTab()
                .tabItem { Label("Devices", systemImage: "iphone") }
        }
        .frame(width: 480)
        .padding()
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Server URL") {
                    TextField("http://localhost:11434", text: $settings.baseURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                }

                LabeledContent("Default Model") {
                    TextField("e.g. gpt-oss-20b", text: $settings.defaultModel)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                }
            } header: {
                Text("Inference Backend")
            } footer: {
                Label("Default model is used when the iOS app doesn't specify one.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Devices

private struct DevicesSettingsTab: View {
    @EnvironmentObject var pairingManager: PairingManager
    @State private var confirmRemoveAll = false

    var body: some View {
        Form {
            Section("Paired Devices") {
                if pairingManager.approvedDevices.isEmpty {
                    Text("No paired devices")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(pairingManager.approvedDevices.keys).sorted(), id: \.self) { deviceId in
                        DeviceRow(deviceId: deviceId)
                    }
                }
            }

            if !pairingManager.approvedDevices.isEmpty {
                Section {
                    HStack {
                        Button("Refresh") {
                            pairingManager.refreshAll()
                        }
                        Spacer()
                        Button("Remove All", role: .destructive) {
                            confirmRemoveAll = true
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Remove all paired devices?",
            isPresented: $confirmRemoveAll,
            titleVisibility: .visible
        ) {
            Button("Remove All", role: .destructive) {
                pairingManager.removeAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All paired devices will need to pair again to use BigBro.")
        }
    }
}

private struct DeviceRow: View {
    @EnvironmentObject var pairingManager: PairingManager
    let deviceId: String

    var body: some View {
        let connected = pairingManager.connectedDeviceIds.contains(deviceId)
        HStack(spacing: 10) {
            Circle()
                .fill(connected ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 10, height: 10)
            Image(systemName: "iphone")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(pairingManager.displayName(for: deviceId))
                    .lineLimit(1)
                Text(connected ? "Connected" : "Disconnected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if connected {
                Button("Disconnect") {
                    pairingManager.disconnect(deviceId: deviceId)
                }
                .buttonStyle(.plain)
            }
            Button("Remove") {
                pairingManager.remove(deviceId: deviceId)
            }
            .foregroundStyle(.red)
            .buttonStyle(.plain)
        }
    }
}
