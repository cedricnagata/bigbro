import Foundation
import Combine
import AppKit

@MainActor
final class PairingManager: ObservableObject {
    @Published var approvedDevices: Set<String> = []
    @Published var deviceNames: [String: String] = [:]
    @Published var connectedDeviceIds: Set<String> = []

    weak var peerServer: PeerServer?

    private static let approvedDevicesKey = "bigbro.approvedDevices"
    private static let deviceNamesKey = "bigbro.deviceNames"

    init() {
        approvedDevices = Set(UserDefaults.standard.stringArray(forKey: Self.approvedDevicesKey) ?? [])
        deviceNames = (UserDefaults.standard.dictionary(forKey: Self.deviceNamesKey) as? [String: String]) ?? [:]
        print("[PairingManager] Loaded \(approvedDevices.count) approved device(s)")
    }

    func displayName(for deviceId: String) -> String {
        deviceNames[deviceId] ?? deviceId
    }

    func markConnected(_ deviceId: String) {
        connectedDeviceIds.insert(deviceId)
        print("[PairingManager] \(deviceId.prefix(8)) marked connected (total: \(connectedDeviceIds.count))")
    }

    func markDisconnected(_ deviceId: String) {
        connectedDeviceIds.remove(deviceId)
        print("[PairingManager] \(deviceId.prefix(8)) marked disconnected (total: \(connectedDeviceIds.count))")
    }

    /// Called by AppRouter on each hello message.
    /// Registers the connection (auto-approve known, show alert for new).
    /// Returns true if approved.
    func handleHello(deviceId: String, deviceName: String, connectionId: UUID, server: PeerServer) async {
        print("[PairingManager] handleHello: deviceId=\(deviceId.prefix(8)) name='\(deviceName)' connectionId=\(connectionId)")

        if approvedDevices.contains(deviceId) {
            print("[PairingManager] Device \(deviceId.prefix(8)) is already approved, auto-approving")
            if deviceNames[deviceId] != deviceName {
                deviceNames[deviceId] = deviceName
                persistNames()
            }
            markConnected(deviceId)
            await server.register(connectionId: connectionId, as: deviceId)
            await server.send(["type": "helloAck", "status": "approved"], to: deviceId)
            print("[PairingManager] helloAck(approved) sent to \(deviceId.prefix(8))")
            return
        }

        print("[PairingManager] New device '\(deviceName)' — showing approval alert")
        let approved = showApprovalAlert(deviceName: deviceName)
        print("[PairingManager] User responded: \(approved ? "approved" : "denied")")

        if approved {
            approvedDevices.insert(deviceId)
            deviceNames[deviceId] = deviceName
            persistApproved()
            persistNames()
            markConnected(deviceId)
            await server.register(connectionId: connectionId, as: deviceId)
            await server.send(["type": "helloAck", "status": "approved"], to: deviceId)
            print("[PairingManager] helloAck(approved) sent to \(deviceId.prefix(8))")
        } else {
            await server.send(["type": "helloAck", "status": "denied"], toPending: connectionId)
            await server.disconnectPending(connectionId: connectionId)
            print("[PairingManager] helloAck(denied) sent and connection closed")
        }
    }

    func remove(deviceId: String) {
        print("[PairingManager] Removing device \(deviceId.prefix(8))")
        Task { await peerServer?.disconnect(deviceId: deviceId) }
        approvedDevices.remove(deviceId)
        deviceNames.removeValue(forKey: deviceId)
        connectedDeviceIds.remove(deviceId)
        persistApproved()
        persistNames()
    }

    func removeAll() {
        print("[PairingManager] Removing all \(approvedDevices.count) devices")
        for deviceId in connectedDeviceIds {
            Task { await peerServer?.disconnect(deviceId: deviceId) }
        }
        approvedDevices.removeAll()
        deviceNames.removeAll()
        connectedDeviceIds.removeAll()
        persistApproved()
        persistNames()
    }

    func disconnect(deviceId: String) {
        print("[PairingManager] Disconnecting \(deviceId.prefix(8))")
        Task { await peerServer?.disconnect(deviceId: deviceId) }
        markDisconnected(deviceId)
    }

    func refreshAll() {
        print("[PairingManager] Refreshing \(connectedDeviceIds.count) connected device(s)")
        for deviceId in connectedDeviceIds {
            Task { await peerServer?.send(["type": "ping"], to: deviceId) }
        }
    }

    // MARK: - Private

    private func persistApproved() {
        UserDefaults.standard.set(Array(approvedDevices), forKey: Self.approvedDevicesKey)
    }

    private func persistNames() {
        UserDefaults.standard.set(deviceNames, forKey: Self.deviceNamesKey)
    }

    private func showApprovalAlert(deviceName: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "\(deviceName) wants to connect"
        alert.informativeText = "Allow this device to use BigBro for AI inference?"
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
