import Foundation
import Combine
import AppKit

@MainActor
final class PairingManager: ObservableObject {
    @Published var approvedDevices: Set<String> = []
    @Published var deviceNames: [String: String] = [:]
    @Published var deviceAppNames: [String: String] = [:]
    @Published var connectedDeviceIds: Set<String> = []

    weak var peerServer: PeerServer?
    weak var ollamaMonitor: OllamaMonitor?

    @Published var deviceRequiredModels: [String: [String]] = [:]

    private static let approvedDevicesKey = "bigbro.approvedDevices"
    private static let deviceNamesKey = "bigbro.deviceNames"
    private static let deviceAppNamesKey = "bigbro.deviceAppNames"

    init() {
        approvedDevices = Set(UserDefaults.standard.stringArray(forKey: Self.approvedDevicesKey) ?? [])
        deviceNames = (UserDefaults.standard.dictionary(forKey: Self.deviceNamesKey) as? [String: String]) ?? [:]
        deviceAppNames = (UserDefaults.standard.dictionary(forKey: Self.deviceAppNamesKey) as? [String: String]) ?? [:]
        print("[PairingManager] Loaded \(approvedDevices.count) approved device(s)")
    }

    func displayName(for deviceId: String) -> String {
        let device = deviceNames[deviceId] ?? deviceId
        if let app = deviceAppNames[deviceId] {
            return "\(device) • \(app)"
        }
        return device
    }

    func markConnected(_ deviceId: String) {
        connectedDeviceIds.insert(deviceId)
        print("[PairingManager] \(deviceId.prefix(8)) marked connected (total: \(connectedDeviceIds.count))")
    }

    func markDisconnected(_ deviceId: String) {
        connectedDeviceIds.remove(deviceId)
        deviceRequiredModels.removeValue(forKey: deviceId)
        print("[PairingManager] \(deviceId.prefix(8)) marked disconnected (total: \(connectedDeviceIds.count))")
    }

    /// Called by AppRouter on each hello message.
    /// Registers the connection (auto-approve known, show alert for new).
    /// Returns true if approved.
    func handleHello(deviceId: String, deviceName: String, appName: String, requiredModels: [String], connectionId: UUID, server: PeerServer) async {
        print("[PairingManager] handleHello: deviceId=\(deviceId.prefix(8)) name='\(deviceName)' app='\(appName)' connectionId=\(connectionId)")

        if approvedDevices.contains(deviceId) {
            print("[PairingManager] Device \(deviceId.prefix(8)) is already approved, auto-approving")
            if deviceNames[deviceId] != deviceName {
                deviceNames[deviceId] = deviceName
                persistNames()
            }
            if deviceAppNames[deviceId] != appName {
                deviceAppNames[deviceId] = appName
                persistAppNames()
            }
            deviceRequiredModels[deviceId] = requiredModels
            markConnected(deviceId)
            await server.register(connectionId: connectionId, as: deviceId)
            let missing = missingModels(requiredModels: requiredModels)
            var ack: [String: Any] = ["type": "helloAck", "status": "approved"]
            if !missing.isEmpty { ack["missingModels"] = missing }
            await server.send(ack, to: deviceId)
            print("[PairingManager] helloAck(approved) sent to \(deviceId.prefix(8)), missing=\(missing)")
            promptModelDownloadIfNeeded(deviceName: deviceName, missing: missing)
            return
        }

        print("[PairingManager] New device '\(deviceName)' — showing approval alert")
        let approved = showApprovalAlert(deviceName: deviceName)
        print("[PairingManager] User responded: \(approved ? "approved" : "denied")")

        if approved {
            approvedDevices.insert(deviceId)
            deviceNames[deviceId] = deviceName
            deviceAppNames[deviceId] = appName
            deviceRequiredModels[deviceId] = requiredModels
            persistApproved()
            persistNames()
            persistAppNames()
            markConnected(deviceId)
            await server.register(connectionId: connectionId, as: deviceId)
            let missing = missingModels(requiredModels: requiredModels)
            var ack: [String: Any] = ["type": "helloAck", "status": "approved"]
            if !missing.isEmpty { ack["missingModels"] = missing }
            await server.send(ack, to: deviceId)
            print("[PairingManager] helloAck(approved) sent to \(deviceId.prefix(8)), missing=\(missing)")
            promptModelDownloadIfNeeded(deviceName: deviceName, missing: missing)
        } else {
            await server.send(["type": "helloAck", "status": "denied"], toPending: connectionId)
            await server.disconnectPending(connectionId: connectionId)
            print("[PairingManager] helloAck(denied) sent and connection closed")
        }
    }

    private func missingModels(requiredModels: [String]) -> [String] {
        guard let monitor = ollamaMonitor, monitor.status == .running else { return [] }
        return monitor.missingModels(from: requiredModels)
    }

    private func promptModelDownloadIfNeeded(deviceName: String, missing: [String]) {
        guard !missing.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Missing Models"
        alert.informativeText = "\(deviceName) requires the following model\(missing.count == 1 ? "" : "s") that aren't downloaded in Ollama:\n\n\(missing.joined(separator: "\n"))\n\nOpen Ollama to download them."
        alert.addButton(withTitle: "OK")
        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func remove(deviceId: String) {
        print("[PairingManager] Removing device \(deviceId.prefix(8))")
        Task { await peerServer?.disconnect(deviceId: deviceId) }
        approvedDevices.remove(deviceId)
        deviceNames.removeValue(forKey: deviceId)
        deviceAppNames.removeValue(forKey: deviceId)
        connectedDeviceIds.remove(deviceId)
        persistApproved()
        persistNames()
        persistAppNames()
    }

    func removeAll() {
        print("[PairingManager] Removing all \(approvedDevices.count) devices")
        for deviceId in connectedDeviceIds {
            Task { await peerServer?.disconnect(deviceId: deviceId) }
        }
        approvedDevices.removeAll()
        deviceNames.removeAll()
        deviceAppNames.removeAll()
        connectedDeviceIds.removeAll()
        persistApproved()
        persistNames()
        persistAppNames()
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

    /// Called when Ollama's installed model list changes. Pushes updated missing-model
    /// lists to all connected devices that declared required models.
    func pushModelsUpdate() {
        guard let server = peerServer else { return }
        for deviceId in connectedDeviceIds {
            guard let required = deviceRequiredModels[deviceId], !required.isEmpty else { continue }
            let missing = missingModels(requiredModels: required)
            let msg: [String: Any] = ["type": "modelsUpdate", "missingModels": missing]
            Task { await server.send(msg, to: deviceId) }
            print("[PairingManager] modelsUpdate → \(deviceId.prefix(8)): missing=\(missing)")
        }
    }

    // MARK: - Private

    private func persistApproved() {
        UserDefaults.standard.set(Array(approvedDevices), forKey: Self.approvedDevicesKey)
    }

    private func persistNames() {
        UserDefaults.standard.set(deviceNames, forKey: Self.deviceNamesKey)
    }

    private func persistAppNames() {
        UserDefaults.standard.set(deviceAppNames, forKey: Self.deviceAppNamesKey)
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
