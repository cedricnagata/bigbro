import SwiftUI

struct DeviceListView: View {
    @EnvironmentObject var pairingManager: PairingManager
    @EnvironmentObject var mlxEngine: MLXEngine
    @EnvironmentObject var speechEngine: SpeechEngine
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // Gated on .unreachable, which SpeechEngine only reports when speech is enabled and
        // failed to load — users who never turn it on never see this. MLXEngine has no
        // equivalent banner: it runs in-process, so there is no "not running" state, only
        // "not downloaded yet" (surfaced in Settings instead).
        if speechEngine.status == .unreachable {
            Label("Speech models failed to load", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .font(.caption)
        }

        if pairingManager.approvedDevices.isEmpty {
            Text("No paired devices")
        } else {
            ForEach(pairingManager.approvedDevices.sorted(), id: \.self) { deviceId in
                DeviceMenuRow(deviceId: deviceId)
                    .environmentObject(pairingManager)
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
