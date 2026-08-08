import Foundation

// Every reply the control socket sends, as a type.
//
// Note what is deliberately absent: a `keyDecodingStrategy`. `status` sends
// `keepAwake` and `settings.get` sends `keep_awake`, so no single strategy can
// serve both — `.convertFromSnakeCase` would silently drop `keepAwake` and leave
// the status bar reporting that the Mac is not being held awake. The one type that
// needs renaming spells its keys out; everything else matches the wire exactly.
// `tests/test_control_contract.py` pins this split on the daemon side.

/// The `{"ok": …, "error": …}` envelope every reply carries.
public struct Envelope: Decodable, Sendable, Equatable {
    public let ok: Bool
    public let error: String?
}

public enum Reply {
    /// Checks the envelope, then decodes the body from the same bytes.
    ///
    /// Two passes rather than one because a failure is a different shape from a
    /// success, and decoding a success type against a failure reply produces a
    /// key-not-found error instead of the message the daemon took the trouble to
    /// write.
    public static func decode<R: Decodable>(_ type: R.Type, from data: Data) throws -> R {
        try check(data)
        return try JSONDecoder().decode(type, from: data)
    }

    @discardableResult
    public static func check(_ data: Data) throws -> Envelope {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.ok else {
            throw ControlError.daemon(envelope.error ?? "the daemon refused, without saying why")
        }
        return envelope
    }
}

// MARK: - status

public struct Status: Decodable, Sendable, Equatable {
    public let name: String
    public let port: Int
    public let keepAwake: Bool
    public let paired: Int
    public let connected: [String]
    public let pending: [PendingRequest]
    public let running: [String]
    public let downloaded: [String]
    public let speech: [String: SpeechInfo]
    public let memory: MemoryReport

    private enum CodingKeys: String, CodingKey {
        case name, port, keepAwake, paired, connected, pending, running, downloaded, speech, memory
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        port = try container.decode(Int.self, forKey: .port)
        keepAwake = try container.decode(Bool.self, forKey: .keepAwake)
        paired = try container.decode(Int.self, forKey: .paired)
        connected = try container.decode([String].self, forKey: .connected)
        pending = try container.decode([PendingRequest].self, forKey: .pending)
        running = try container.decode([String].self, forKey: .running)
        downloaded = try container.decode([String].self, forKey: .downloaded)
        speech = try container.decode([String: SpeechInfo].self, forKey: .speech)

        // The one tolerated absence. A daemon that predates the memory probe sends
        // no `memory` at all, and an absent report says exactly what a present one
        // full of nulls says — every figure is unknown. Everything above stays
        // required on purpose: those are core, the daemon always sends them, and a
        // silent default would turn a rename into an empty pane rather than a loud
        // failure. `tests/test_control_contract.py` is what guards the renames.
        memory = try container.decodeIfPresent(MemoryReport.self, forKey: .memory) ?? MemoryReport()
    }
}

/// What a speech role is doing.
///
/// Decodes from either `{"name": …, "model": …, "state": …}` or a bare state
/// string. The bare form is not hypothetical: `__main__.py` still handles it for
/// older daemons, and the stub used by the dashboard tests sends it. A plain
/// synthesised `Codable` would throw on the string and take the whole `status`
/// decode down with it.
public struct SpeechInfo: Decodable, Sendable, Equatable {
    public let name: String?
    public let model: String?
    public let state: String

    private enum CodingKeys: String, CodingKey {
        case name, model, state
    }

    public init(name: String?, model: String?, state: String) {
        self.name = name
        self.model = model
        self.state = state
    }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let bare = try? single.decode(String.self) {
            self.init(name: nil, model: nil, state: bare)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decodeIfPresent(String.self, forKey: .name),
            model: try container.decodeIfPresent(String.self, forKey: .model),
            state: try container.decode(String.self, forKey: .state)
        )
    }
}

/// Every field is optional because every one of them is `None` wherever the mach
/// calls behind it do not resolve. `to_wire` emits all nine unconditionally.
public struct MemoryReport: Decodable, Sendable, Equatable {
    public let resident: Int?
    public let peak: Int?
    public let footprint: Int?
    public let total: Int?
    public let pressure: String?
    public let mlx: [String: Int]
    public let models: [String: Int]
    public let headline: Int?
    public let weights: Int?

    private enum CodingKeys: String, CodingKey {
        case resident, peak, footprint, total, pressure, mlx, models, headline, weights
    }

    /// An entirely unknown report — what a daemon with no memory probe amounts to.
    public init(
        resident: Int? = nil, peak: Int? = nil, footprint: Int? = nil, total: Int? = nil,
        pressure: String? = nil, mlx: [String: Int] = [:], models: [String: Int] = [:],
        headline: Int? = nil, weights: Int? = nil
    ) {
        self.resident = resident
        self.peak = peak
        self.footprint = footprint
        self.total = total
        self.pressure = pressure
        self.mlx = mlx
        self.models = models
        self.headline = headline
        self.weights = weights
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resident = try container.decodeIfPresent(Int.self, forKey: .resident)
        peak = try container.decodeIfPresent(Int.self, forKey: .peak)
        footprint = try container.decodeIfPresent(Int.self, forKey: .footprint)
        total = try container.decodeIfPresent(Int.self, forKey: .total)
        pressure = try container.decodeIfPresent(String.self, forKey: .pressure)
        mlx = try container.decodeIfPresent([String: Int].self, forKey: .mlx) ?? [:]
        models = try container.decodeIfPresent([String: Int].self, forKey: .models) ?? [:]
        headline = try container.decodeIfPresent(Int.self, forKey: .headline)
        weights = try container.decodeIfPresent(Int.self, forKey: .weights)
    }

    /// The daemon's own one-liner, rebuilt. Uses `Formatting.human` so the app and
    /// `bigbro status` never disagree about what 12 GB is.
    public var summary: String {
        var text = Formatting.human(headline)
        if let headline, let total, headline > 0, total > 0 {
            let share = Double(headline) / Double(total) * 100
            text += " of \(Formatting.human(total)) (\(String(format: "%.0f", share))%)"
        }
        if let pressure, pressure != "normal" {
            text += " · pressure \(pressure)"
        }
        return text
    }
}

// MARK: - pairing

public struct PendingRequest: Decodable, Sendable, Equatable, Identifiable {
    public let deviceId: String
    public let deviceName: String?
    public let appName: String?
    public let requiredModels: [String]
    public let waitingSeconds: Int?

    public var id: String { deviceId }

    private enum CodingKeys: String, CodingKey {
        case deviceId, deviceName, appName, requiredModels, waitingSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try container.decode(String.self, forKey: .deviceId)
        deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName)
        appName = try container.decodeIfPresent(String.self, forKey: .appName)
        requiredModels = try container.decodeIfPresent([String].self, forKey: .requiredModels) ?? []
        waitingSeconds = try container.decodeIfPresent(Int.self, forKey: .waitingSeconds)
    }

    public init(
        deviceId: String, deviceName: String? = nil, appName: String? = nil,
        requiredModels: [String] = [], waitingSeconds: Int? = nil
    ) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.appName = appName
        self.requiredModels = requiredModels
        self.waitingSeconds = waitingSeconds
    }

    /// What to call it in a prompt, falling back the way the dashboard does.
    public var displayName: String {
        deviceName ?? String(deviceId.prefix(8))
    }
}

public struct Device: Decodable, Sendable, Equatable, Identifiable {
    public let deviceId: String
    public let name: String
    public let appName: String
    public let connected: Bool
    public let requiredModels: [String]

    public var id: String { deviceId }
}

public struct PairList: Decodable, Sendable, Equatable {
    public let pending: [PendingRequest]
    public let devices: [Device]
}

// MARK: - models

public struct ModelEntry: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let family: String
    /// `var` because a progress tick rewrites exactly this and nothing else.
    public var state: String
    public let sizeGB: Double
    public let tools: Bool
    public let images: Bool
    public let reasoning: String
    /// Null for speech models, which are not in MLXEngine's bookkeeping, and
    /// absent entirely from older stubs.
    public let memory: Int?

    private enum CodingKeys: String, CodingKey {
        case id, name, family, state, sizeGB, tools, images, reasoning, memory
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        family = try container.decode(String.self, forKey: .family)
        state = try container.decode(String.self, forKey: .state)
        sizeGB = try container.decodeIfPresent(Double.self, forKey: .sizeGB) ?? 0
        tools = try container.decodeIfPresent(Bool.self, forKey: .tools) ?? false
        images = try container.decodeIfPresent(Bool.self, forKey: .images) ?? false
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning) ?? "none"
        memory = try container.decodeIfPresent(Int.self, forKey: .memory)
    }
}

/// What the two buttons on a model row should say, and whether they can be used.
///
/// The daemon reports state as prose — "running", "downloading 47%", "not
/// downloaded", "error: no space left" — and the four verbs sit on two
/// independent axes: download/delete is about disk, start/stop is about memory.
/// Reading that prose lives here rather than in the view so it can be tested,
/// and so both axes agree about what a state means.
public extension ModelEntry {
    var isRunning: Bool { state.hasPrefix("running") }
    var isStarting: Bool { state.hasPrefix("starting") }
    var isDownloading: Bool { state.hasPrefix("downloading") }

    /// Whether the weights are on disk. `error` counts as absent so the button
    /// offers a retry rather than a delete for something that may not be there.
    var hasWeights: Bool { isRunning || isStarting || state.hasPrefix("downloaded") }

    /// Stop what is running, start what is merely downloaded.
    var runActionIsStop: Bool { isRunning }

    /// Nothing to start without weights, and `starting` is already in flight.
    var canRunAction: Bool { hasWeights && !isStarting }

    /// Delete once the weights exist, download when they do not.
    var weightsActionIsDelete: Bool { hasWeights }

    /// Deleting under a loaded model would pull the file out from beneath it, and
    /// a download already running has nothing to offer.
    var canWeightsAction: Bool { !isDownloading && !isRunning && !isStarting }
}

public struct ModelGroup: Decodable, Sendable, Equatable, Identifiable {
    public let family: String
    public let label: String
    public var models: [ModelEntry]

    public var id: String { family }
}

public struct ModelsList: Decodable, Sendable, Equatable {
    public let groups: [ModelGroup]
}

// MARK: - settings

/// The one type that renames keys. See the note at the top of this file.
public struct SettingsValues: Decodable, Sendable, Equatable {
    public let port: Int
    public let keepAwake: Bool
    public let logLevel: String

    private enum CodingKeys: String, CodingKey {
        case port
        case keepAwake = "keep_awake"
        case logLevel = "log_level"
    }
}

public struct SettingsReply: Decodable, Sendable, Equatable {
    public let settings: SettingsValues
    /// Present on `settings.get`.
    public let editable: [String]?
    /// Present on `settings.set` — sometimes says a restart is needed.
    public let message: String?
}
