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

    var body: some View {
        Form {
            Section("Paired Devices") {
                if pairingManager.approvedDevices.isEmpty {
                    Text("No paired devices")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(pairingManager.approvedDevices.keys), id: \.self) { deviceId in
                        HStack {
                            Image(systemName: "iphone")
                                .foregroundStyle(.secondary)
                            Text(deviceId)
                                .lineLimit(1)
                            Spacer()
                            Button("Remove") {
                                pairingManager.remove(deviceId: deviceId)
                            }
                            .foregroundStyle(.red)
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
