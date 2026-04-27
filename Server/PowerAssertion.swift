import Foundation
import IOKit.pwr_mgt

/// Holds a system power assertion that keeps the Mac awake while peers are
/// connected. Uses `PreventSystemSleep` (same as `caffeinate -s`) so the Mac
/// stays running even with the lid closed *while on AC power*. On battery,
/// macOS still enforces clamshell sleep and this assertion is overridden.
/// Display sleep is still allowed. Idempotent.
final class PowerAssertion {
    private var assertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var hasAssertion = false
    private var activityToken: NSObjectProtocol?

    func acquire(reason: String) {
        guard !hasAssertion else { return }
        let cfReason = reason as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            cfReason,
            &assertionID
        )
        if result == kIOReturnSuccess {
            hasAssertion = true
            print("[PowerAssertion] Acquired (\(reason))")
        } else {
            print("[PowerAssertion] Failed to acquire: \(result)")
        }

        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: reason
        )
    }

    func release() {
        if hasAssertion {
            IOPMAssertionRelease(assertionID)
            assertionID = IOPMAssertionID(0)
            hasAssertion = false
            print("[PowerAssertion] Released")
        }
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }

    deinit {
        if hasAssertion {
            IOPMAssertionRelease(assertionID)
        }
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
        }
    }
}
