import Foundation
import Combine

/// Reachability of an upstream backend BigBro proxies to.
///
/// `.disabled` is only ever produced by optional backends the user has not switched on — an
/// unconfigured backend should read as *off*, not as broken. The chat backend is required
/// and never reports it.
enum BackendStatus {
    case disabled
    case unknown
    case running
    case unreachable
}

/// A backend's reachability, for anything that wants to report it (currently just the
/// `.status == .unreachable` banner in `DeviceListView`).
@MainActor
protocol BackendStatusReporting: ObservableObject {
    var status: BackendStatus { get }

    /// Shown beside the indicator while running, e.g. "Running (4 models)".
    var runningSummary: String { get }

    /// Rows revealed when the running summary is expanded. Empty means not expandable.
    var detailItems: [String] { get }

    /// Copy shown when unreachable — should name the thing the user needs to start.
    var unreachableHint: String { get }
}
