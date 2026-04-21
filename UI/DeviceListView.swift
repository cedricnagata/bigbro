import SwiftUI

struct DeviceListView: View {
    @EnvironmentObject var pairingManager: PairingManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "brain")
                    .foregroundStyle(.blue)
                Text("BigBro")
                    .font(.headline)
                Spacer()
            }

            Divider()

            if pairingManager.approvedDevices.isEmpty {
                Text("No paired devices")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                ForEach(Array(pairingManager.approvedDevices.keys), id: \.self) { deviceId in
                    HStack(spacing: 8) {
                        Image(systemName: "iphone")
                            .foregroundStyle(.secondary)
                        Text(deviceId)
                            .font(.subheadline)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }

            Divider()

            SettingsLink {
                Text("Settings…")
                    .font(.subheadline)
            }

            Button("Quit BigBro") {
                NSApplication.shared.terminate(nil)
            }
            .font(.subheadline)
        }
        .padding(12)
        .frame(width: 260)
    }
}
