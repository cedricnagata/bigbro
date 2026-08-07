import Foundation
import XCTest

@testable import BigBroControl

/// The daemon replies frozen under `app/Tests/Fixtures`, captured from a real
/// `Daemon` by `tests/test_control_contract.py` and kept honest by it.
///
/// Located from `#filePath` rather than through `Bundle.module`, so the package
/// needs no resource declaration and the same JSON files stay readable from
/// Python — they are shared with it, not copied for us.
enum Fixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // BigBroControlTests
        .deletingLastPathComponent()   // Tests
        .appendingPathComponent("Fixtures")

    /// The repository root, for finding the Python interpreter and the stub server.
    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // BigBroControlTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // app
        .deletingLastPathComponent()   // repo root

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent("\(name).json"))
    }
}

/// Canned replies plus a record of what was asked for.
///
/// The direct analogue of `StubDaemon.calls` in the Python tests: the questions
/// that matter here are as much about which commands were sent as about what came
/// back — "did a progress tick re-fetch the model list" is only answerable by
/// looking at the traffic.
final class StubTransport: ControlTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [String: Data] = [:]
    private var recorded: [Command] = []

    /// Seeded from the fixtures, so the default stub answers exactly what a real
    /// daemon answers.
    init(useFixtures: Bool = true) throws {
        guard useFixtures else { return }
        replies["status"] = try Fixtures.data("status")
        replies["models.list"] = try Fixtures.data("models_list")
        replies["settings.get"] = try Fixtures.data("settings_get")
        replies["pair.list"] = try Fixtures.data("pair_list")
    }

    func reply(to command: String, with json: String) {
        lock.lock()
        replies[command] = Data(json.utf8)
        lock.unlock()
    }

    var commands: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded.map(\.name)
    }

    var sent: [Command] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func count(of command: String) -> Int {
        commands.filter { $0 == command }.count
    }

    func forgetTraffic() {
        lock.lock()
        recorded.removeAll()
        lock.unlock()
    }

    func send(_ command: Command) async throws -> Data {
        lock.lock()
        recorded.append(command)
        let canned = replies[command.name]
        lock.unlock()
        return canned ?? Data(#"{"ok":true}"#.utf8)
    }
}

extension StubTransport {
    /// A `models.list` reply with the given entries, all in one Text group.
    ///
    /// Order is preserved exactly as written: the daemon ranks these rows, so a
    /// test that wants a particular order states it rather than relying on a sort
    /// this side does not do.
    static func modelsList(_ entries: [(id: String, state: String)]) -> String {
        let models = entries.map { entry in
            """
            {"id": "\(entry.id)", "name": "\(entry.id)", "family": "language",
             "state": "\(entry.state)", "sizeGB": 1.0, "tools": true, "images": false,
             "reasoning": "none", "memory": null}
            """
        }.joined(separator: ",")
        return """
            {"ok": true, "groups": [
              {"family": "language", "label": "Text", "models": [\(models)]}
            ]}
            """
    }

    static func pairList(pending: [String]) -> String {
        let requests = pending.map { id in
            """
            {"deviceId": "\(id)", "deviceName": "iPhone", "appName": "TestApp",
             "requiredModels": [], "waitingSeconds": 3}
            """
        }.joined(separator: ",")
        return #"{"ok": true, "pending": [\#(requests)], "devices": []}"#
    }
}

/// Repeatedly checks a condition, so a test can wait on something asynchronous
/// without sleeping for a fixed guess at how long it takes.
func eventually(
    timeout: TimeInterval = 5,
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 25_000_000)
    }
    return await condition()
}
