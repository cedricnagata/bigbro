import SwiftUI

struct DeviceListView: View {
    @EnvironmentObject var pairingManager: PairingManager
    @Environment(\.openSettings) private var openSettings

    var body: some View {
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
