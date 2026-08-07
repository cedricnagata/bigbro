import AppKit
import BigBroControl
import SwiftUI
import UserNotifications

/// Puts a pairing request in front of someone who is not looking at BigBro.
///
/// This is the thing a terminal dashboard could never do. The Textual prompt was
/// only actionable if that terminal happened to be frontmost; in practice the
/// daemon runs in a window behind everything else, and a phone waits out its
/// five-minute timeout because nobody saw the request. A notification with
/// Approve and Deny on it is answerable from anywhere.
///
/// Notifications require a signed, bundled app with a stable bundle identifier.
/// Under `swift run` there is no bundle, `UNUserNotificationCenter` is unusable,
/// and every method here turns into a no-op — the in-app sheet and the menu bar
/// item still work, so nothing is lost but the convenience.
@MainActor
final class PairingNotifier: NSObject, UNUserNotificationCenterDelegate {
    private static let category = "pairing"
    private static let approve = "pairing.approve"
    private static let deny = "pairing.deny"
    private static let deviceKey = "deviceId"

    private weak var dashboard: DashboardModel?
    private var available = false

    func start(dashboard: DashboardModel) {
        self.dashboard = dashboard

        // No bundle identifier means no notification centre, and asking for one
        // anyway raises rather than returning nil.
        guard Bundle.main.bundleIdentifier != nil else { return }
        available = true

        let centre = UNUserNotificationCenter.current()
        centre.delegate = self
        centre.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.category,
                actions: [
                    UNNotificationAction(
                        identifier: Self.approve, title: "Approve", options: [.authenticationRequired]
                    ),
                    UNNotificationAction(
                        identifier: Self.deny, title: "Deny", options: [.destructive]
                    ),
                ],
                intentIdentifiers: [],
                options: []
            )
        ])
        centre.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notify(about request: PendingRequest) {
        guard available else { return }

        let content = UNMutableNotificationContent()
        content.title = "\(request.displayName) wants to pair"
        content.body = request.appName.map { "from \($0)" } ?? "Approve to let it use this Mac."
        content.categoryIdentifier = Self.category
        content.userInfo = [Self.deviceKey: request.deviceId]

        // Keyed by device so a phone that retries replaces its own notification
        // rather than stacking a second one — the same reason DashboardModel
        // keeps a set of who it has already asked about.
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: request.deviceId, content: content, trigger: nil)
        )
    }

    /// Withdraws a request that was answered somewhere else — in the window, from
    /// the menu bar, or by `bigbro pair approve` in a terminal.
    func withdraw(deviceId: String) {
        guard available else { return }
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [deviceId])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let deviceId = userInfo[Self.deviceKey] as? String
        let action = response.actionIdentifier

        Task { @MainActor in
            defer { completionHandler() }
            guard let deviceId, let dashboard else { return }

            switch action {
            case Self.approve:
                await dashboard.resolve(deviceId: deviceId, approved: true)
            case Self.deny:
                await dashboard.resolve(deviceId: deviceId, approved: false)
            default:
                // Tapping the body rather than a button: bring the window forward
                // and let them decide there, rather than guessing.
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }
    }

    /// Show it even when BigBro is frontmost — the window may be on another Space,
    /// or behind whatever they are actually doing.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
