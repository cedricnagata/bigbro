import SwiftUI

struct DeviceListView: View {
    @EnvironmentObject var pairingManager: PairingManager
    @EnvironmentObject var ollamaMonitor: OllamaMonitor
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if ollamaMonitor.status == .unreachable {
            Label("Ollama not running", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .font(.caption)
        }

        if pairingManager.approvedDevices.isEmpty {
            Text("No paired devices")
        } else {
            ForEach(pairingManager.approvedDevices.sorted(), id: \.self) { deviceId in
                DeviceMenuRow(deviceId: deviceId)
                    .environmentObject(pairingManager)
                    .environmentObject(ollamaMonitor)
            }
        }

        Divider()

        Button("Settings…") {
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        Button("Quit BigBro") {
            NSApplication.shared.terminate(nil)
        }
    }
}

private struct DeviceMenuRow: View {
    @EnvironmentObject var pairingManager: PairingManager
    @EnvironmentObject var ollamaMonitor: OllamaMonitor
    let deviceId: String

    var body: some View {
        let connected = pairingManager.connectedDeviceIds.contains(deviceId)
        let name = pairingManager.displayName(for: deviceId)
        let requiredModels = pairingManager.deviceRequiredModels[deviceId] ?? []

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle()
                    .fill(connected ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
                Text(name)
                    .font(.system(size: 13))
            }
            if connected && !requiredModels.isEmpty {
                ForEach(requiredModels, id: \.self) { model in
                    let installed = ollamaMonitor.isInstalled(model)
                    HStack(spacing: 4) {
                        Image(systemName: installed ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(installed ? .green : .red)
                            .font(.system(size: 10))
                        Text(model)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 12)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
