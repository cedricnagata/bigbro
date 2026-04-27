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

        if connected {
            (Text(Image(systemName: "circle.fill"))
                .foregroundColor(.green)
             + Text("  \(name)"))
                .font(.system(size: 13))
        } else {
            Text("      \(name)")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
    }
}
