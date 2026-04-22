import SwiftUI

struct DeviceListView: View {
    @EnvironmentObject var pairingManager: PairingManager
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if pairingManager.approvedDevices.isEmpty {
            Text("No paired devices")
        } else {
            ForEach(Array(pairingManager.approvedDevices.keys), id: \.self) { deviceId in
                Label(deviceId, systemImage: "iphone")
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
