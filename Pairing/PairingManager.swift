import Foundation
import Combine
import AppKit

@MainActor
final class PairingManager: ObservableObject {
    @Published var approvedDevices: [String: String] = [:]  // deviceId → token
    @Published var deviceNames: [String: String] = [:]      // deviceId → display name
    @Published var connectedDeviceIds: Set<String> = []
    private var deniedDevices: Set<String> = []
    private var pendingRequests: [PairingRequest] = []

    private static let deviceNamesKey = "bigbro.deviceNames"

    init() {
        approvedDevices = TokenStore.shared.loadAll()
        deviceNames = (UserDefaults.standard.dictionary(forKey: Self.deviceNamesKey) as? [String: String]) ?? [:]
    }

    func displayName(for deviceId: String) -> String {
        deviceNames[deviceId] ?? deviceId
    }

    private func persistNames() {
        UserDefaults.standard.set(deviceNames, forKey: Self.deviceNamesKey)
    }

    func deviceId(forToken token: String) -> String? {
        approvedDevices.first(where: { $0.value == token })?.key
    }

    func markConnected(_ deviceId: String) {
        connectedDeviceIds.insert(deviceId)
    }

    func markDisconnected(_ deviceId: String) {
        connectedDeviceIds.remove(deviceId)
    }

    private var presenceCancels: [String: @Sendable () -> Void] = [:]
    private var presencePokes: [String: @Sendable () -> Void] = [:]

    func registerPresence(deviceId: String,
                          cancel: @escaping @Sendable () -> Void,
                          poke: @escaping @Sendable () -> Void) {
        presenceCancels[deviceId] = cancel
        presencePokes[deviceId] = poke
    }

    func unregisterPresence(_ deviceId: String) {
        presenceCancels.removeValue(forKey: deviceId)
        presencePokes.removeValue(forKey: deviceId)
    }

    /// Close the presence stream. The device stays remembered, so a future
    /// connect attempt from the same iOS device is auto-approved silently.
    func disconnect(deviceId: String) {
        presenceCancels[deviceId]?()
    }

    /// Poke every active stream with an immediate ping. Live connections stay
    /// up; dead ones fail the TCP write and close, flipping the UI to
    /// disconnected. Does not tear down healthy connections.
    func refreshAll() {
        print("[PairingManager] Refresh: poking \(presencePokes.count) presence stream(s)")
        for poke in presencePokes.values { poke() }
    }

    func removeAll() {
        for cancel in presenceCancels.values { cancel() }
        presencePokes.removeAll()
        for id in approvedDevices.keys { TokenStore.shared.delete(deviceId: id) }
        approvedDevices.removeAll()
        deviceNames.removeAll()
        connectedDeviceIds.removeAll()
        persistNames()
    }

    func enqueue(_ request: PairingRequest) {
        // Previously-approved device reconnecting: silently refresh its name
        // and short-circuit — no alert, status poll will immediately return
        // approved with the stored token.
        if approvedDevices.keys.contains(request.id) {
            if deviceNames[request.id] != request.deviceName {
                deviceNames[request.id] = request.deviceName
                persistNames()
            }
            return
        }
        guard !deniedDevices.contains(request.id),
              !pendingRequests.contains(where: { $0.id == request.id }) else { return }
        pendingRequests.append(request)
        Task { showAlert(for: request) }
    }

    @discardableResult
    func approve(_ request: PairingRequest) -> String {
        let token = UUID().uuidString
        approvedDevices[request.id] = token
        deviceNames[request.id] = request.deviceName
        pendingRequests.removeAll { $0.id == request.id }
        TokenStore.shared.save(deviceId: request.id, token: token)
        persistNames()
        return token
    }

    func deny(_ request: PairingRequest) {
        deniedDevices.insert(request.id)
        pendingRequests.removeAll { $0.id == request.id }
    }

    func status(for deviceId: String) -> PairingStatus {
        if let token = approvedDevices[deviceId] { return .approved(token: token) }
        if deniedDevices.contains(deviceId) { return .denied }
        return .pending
    }

    func validate(token: String) -> Bool {
        approvedDevices.values.contains(token)
    }

    func remove(deviceId: String) {
        presenceCancels[deviceId]?()
        approvedDevices.removeValue(forKey: deviceId)
        deviceNames.removeValue(forKey: deviceId)
        connectedDeviceIds.remove(deviceId)
        TokenStore.shared.delete(deviceId: deviceId)
        persistNames()
    }

    private func showAlert(for request: PairingRequest) {
        let alert = NSAlert()
        alert.messageText = "\(request.deviceName) wants to connect"
        alert.informativeText = "Allow this device to use BigBro for AI inference?"
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        alert.alertStyle = .informational

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            approve(request)
        } else {
            deny(request)
        }
    }
}
