import Foundation

/// One control-socket command: `{"command": name, ...arguments}`.
///
/// Kept open-ended rather than modelled as an enum with a case per verb, because
/// the daemon's dispatch table is a dictionary of names and this is a faithful
/// mirror of it. The static factories below are the supported surface; the raw
/// initialiser is what lets a test drive the stub server's `test.publish`.
public struct Command: Encodable, Sendable, Equatable {
    public let name: String
    public let arguments: [String: JSONValue]

    public init(_ name: String, _ arguments: [String: JSONValue] = [:]) {
        self.name = name
        self.arguments = arguments
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ stringValue: String) { self.stringValue = stringValue }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { return nil }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(name, forKey: Key("command"))
        for (key, value) in arguments {
            try container.encode(value, forKey: Key(key))
        }
    }
}

public extension Command {
    static let status = Command("status")
    static let pairList = Command("pair.list")
    static let modelsList = Command("models.list")
    static let settingsGet = Command("settings.get")
    static let pairRemoveAll = Command("pair.remove-all")

    static func pairApprove(_ deviceId: String) -> Command {
        Command("pair.approve", ["deviceId": .string(deviceId)])
    }
    static func pairDeny(_ deviceId: String) -> Command {
        Command("pair.deny", ["deviceId": .string(deviceId)])
    }
    static func pairRemove(_ deviceId: String) -> Command {
        Command("pair.remove", ["deviceId": .string(deviceId)])
    }
    static func pairDisconnect(_ deviceId: String) -> Command {
        Command("pair.disconnect", ["deviceId": .string(deviceId)])
    }

    static func modelsDownload(_ model: String) -> Command {
        Command("models.download", ["model": .string(model)])
    }
    static func modelsStart(_ model: String) -> Command {
        Command("models.start", ["model": .string(model)])
    }
    static func modelsStop(_ model: String) -> Command {
        Command("models.stop", ["model": .string(model)])
    }
    static func modelsDelete(_ model: String) -> Command {
        Command("models.delete", ["model": .string(model)])
    }

    static func settingsSet(key: String, value: JSONValue) -> Command {
        Command("settings.set", ["key": .string(key), "value": value])
    }

    /// The one command that turns a connection into a long-lived event stream.
    static let subscribe = Command("subscribe")
}
