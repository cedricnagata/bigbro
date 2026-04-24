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
                let connected = pairingManager.connectedDeviceIds.contains(deviceId)
                let name = pairingManager.displayName(for: deviceId)
                Text("\(connected ? "● " : "○ ")\(name)\(connected ? "" : " (disconnected)")")
                    .disabled(true)
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
