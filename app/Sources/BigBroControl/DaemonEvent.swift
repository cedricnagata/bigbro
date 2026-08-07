import Foundation

/// Something the daemon announced without being asked.
///
/// `unknown` is not defensive padding. The daemon and the app ship separately —
/// one is `uv tool install`ed, the other is dragged out of a DMG — so a newer
/// daemon publishing an event this build has never heard of is an ordinary
/// Tuesday, and it must be ignorable rather than fatal.
///
/// `attached` and `detached` are not daemon events at all. They are the stream's
/// own state, folded into the same sequence so a consumer has one thing to watch
/// instead of two.
public enum DaemonEvent: Sendable, Equatable {
    case log(level: String, logger: String, message: String)
    case pairingRequested(PendingRequest)
    case pairingResolved(deviceId: String, approved: Bool, timedOut: Bool)
    case peerConnected(deviceId: String, connected: [String])
    case peerDisconnected(deviceId: String, connected: [String])
    case modelState(model: String, state: String)
    case downloadProgress(DownloadProgress)
    case settingsChanged(SettingsValues)
    case unknown(name: String)

    case attached
    case detached(reason: String)

    public init(from data: Data) throws {
        let raw = try JSONDecoder().decode(RawEvent.self, from: data)
        self = raw.event
    }
}

public struct DownloadProgress: Sendable, Equatable {
    public let model: String
    public let status: String?
    public let state: String?
    public let completed: Int?
    public let total: Int?
    public let fraction: Double?
    public let done: Bool
    public let error: String?

    public init(
        model: String, status: String? = nil, state: String? = nil,
        completed: Int? = nil, total: Int? = nil, fraction: Double? = nil,
        done: Bool = false, error: String? = nil
    ) {
        self.model = model
        self.status = status
        self.state = state
        self.completed = completed
        self.total = total
        self.fraction = fraction
        self.done = done
        self.error = error
    }

    /// What the row should read while this is in flight.
    ///
    /// The daemon's `state` for an in-flight download is the coarse one; the
    /// percentage is assembled here from `fraction`, the same way `tui.py` does
    /// it, so that a tick changes only the digits and not the leading word. That
    /// is what keeps twice-a-second progress from re-sorting the table.
    public var displayState: String? {
        if !done, let total, total > 0 {
            let percent = ((fraction ?? 0) * 100).rounded(.toNearestOrEven)
            return "downloading \(Int(percent))%"
        }
        return state
    }

    /// "3.1 GB of 12.0 GB", or nil when the daemon has not sized the repo yet.
    public var byteProgress: String? {
        guard let total, total > 0 else { return nil }
        return "\(Formatting.human(completed ?? 0)) of \(Formatting.human(total))"
    }
}

/// Flat mirror of every field any event carries, mapped to the enum on the way out.
///
/// One permissive struct rather than a custom `Decoder` per case: the events share
/// most of their keys, and the daemon publishes them as `**kwargs` so the union is
/// genuinely flat.
struct RawEvent: Decodable {
    let event: DaemonEvent

    private enum CodingKeys: String, CodingKey {
        case event, level, logger, message
        case deviceId, deviceName, appName, requiredModels, waitingSeconds
        case approved, timedOut, connected
        case model, state, status, completed, total, fraction, done, error
        case settings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .event)

        func string(_ key: CodingKeys) throws -> String? {
            try container.decodeIfPresent(String.self, forKey: key)
        }

        switch name {
        case "log":
            event = .log(
                level: try string(.level) ?? "INFO",
                logger: try string(.logger) ?? "",
                message: try string(.message) ?? ""
            )

        case "pairing.requested":
            event = .pairingRequested(
                PendingRequest(
                    deviceId: try container.decode(String.self, forKey: .deviceId),
                    deviceName: try string(.deviceName),
                    appName: try string(.appName),
                    requiredModels: try container.decodeIfPresent(
                        [String].self, forKey: .requiredModels
                    ) ?? [],
                    waitingSeconds: try container.decodeIfPresent(
                        Int.self, forKey: .waitingSeconds
                    )
                )
            )

        case "pairing.resolved":
            event = .pairingResolved(
                deviceId: try container.decode(String.self, forKey: .deviceId),
                approved: try container.decodeIfPresent(Bool.self, forKey: .approved) ?? false,
                timedOut: try container.decodeIfPresent(Bool.self, forKey: .timedOut) ?? false
            )

        case "peer.connected", "peer.disconnected":
            let deviceId = try container.decode(String.self, forKey: .deviceId)
            let connected = try container.decodeIfPresent([String].self, forKey: .connected) ?? []
            event = name == "peer.connected"
                ? .peerConnected(deviceId: deviceId, connected: connected)
                : .peerDisconnected(deviceId: deviceId, connected: connected)

        case "model.state":
            event = .modelState(
                model: try container.decode(String.self, forKey: .model),
                state: try string(.state) ?? ""
            )

        case "download.progress":
            event = .downloadProgress(
                DownloadProgress(
                    model: try container.decode(String.self, forKey: .model),
                    status: try string(.status),
                    state: try string(.state),
                    completed: try container.decodeIfPresent(Int.self, forKey: .completed),
                    total: try container.decodeIfPresent(Int.self, forKey: .total),
                    fraction: try container.decodeIfPresent(Double.self, forKey: .fraction),
                    done: try container.decodeIfPresent(Bool.self, forKey: .done) ?? false,
                    error: try string(.error)
                )
            )

        case "settings.changed":
            event = .settingsChanged(
                try container.decode(SettingsValues.self, forKey: .settings)
            )

        default:
            event = .unknown(name: name)
        }
    }
}
