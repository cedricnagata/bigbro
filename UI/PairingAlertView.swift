import SwiftUI

struct PairingAlertView: View {
    let request: PairingRequest
    @EnvironmentObject var pairingManager: PairingManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "iphone.badge.play")
                .font(.system(size: 44))
                .foregroundStyle(.blue)

            VStack(spacing: 6) {
                Text("\(request.deviceName)")
                    .font(.title3.bold())
                Text("wants to connect to BigBro")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                Button("Deny") {
                    pairingManager.deny(request)
                    dismiss()
                }
                .keyboardShortcut(.escape)

                Button("Allow") {
                    pairingManager.approve(request)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
            }
        }
        .padding(32)
        .frame(minWidth: 300)
    }
}
