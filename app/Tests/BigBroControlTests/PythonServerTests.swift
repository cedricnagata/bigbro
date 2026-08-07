import Foundation
import XCTest

@testable import BigBroControl

/// The Swift client against the real Python server.
///
/// Every other test in this target is written against a stub that this repository
/// also wrote, which means it cannot catch the mistakes that come from misreading
/// the daemon: whoever writes the Swift stub writes it from the same reading that
/// produced the Swift decoder, so a misreading agrees with itself and both sides
/// go green. `keepAwake` versus `keep_awake` is exactly that kind of mistake.
///
/// So this drives `tests/serve_stub.py` — the real framing, the real
/// `ControlServer`, the real reply shapes — over a real Unix socket.
final class PythonServerTests: XCTestCase {
    private var server: PythonStubServer?

    override func setUp() async throws {
        try await super.setUp()
        guard let interpreter = PythonStubServer.findInterpreter() else {
            throw XCTSkip(
                "No Python with bigbro importable. Run `uv sync --extra dev` in the repo root."
            )
        }
        server = try PythonStubServer(interpreter: interpreter)
    }

    override func tearDown() async throws {
        server?.stop()
        server = nil
        try await super.tearDown()
    }

    private func client() throws -> ControlClient {
        ControlClient(socketPath: try XCTUnwrap(server).socketPath, timeout: 10)
    }

    // MARK: - Commands

    func testStatusDecodesFromTheRealServer() async throws {
        let status = try await client().send(.status, as: Status.self)

        XCTAssertEqual(status.name, "Test Mac")
        XCTAssertEqual(status.port, 8765)
        // The camel-cased one, read off a socket Python actually wrote.
        XCTAssertTrue(status.keepAwake)
    }

    /// The stub sends `speech` as bare strings, the way an older daemon does. This
    /// is the polymorphic decode exercised against real output rather than against
    /// a string we made up.
    func testSpeechAsBareStringsDecodes() async throws {
        let status = try await client().send(.status, as: Status.self)

        XCTAssertEqual(status.speech["tts"]?.state, "not downloaded")
        XCTAssertNil(status.speech["tts"]?.name)
    }

    /// The stub omits `memory` entirely — an older shape. Optional means optional.
    func testModelsListDecodesWithoutAMemoryField() async throws {
        let list = try await client().send(.modelsList, as: ModelsList.self)

        XCTAssertEqual(list.groups.map(\.family), ["language", "vision", "tts", "stt"])
        XCTAssertTrue(list.groups.flatMap(\.models).allSatisfy { $0.memory == nil })
    }

    func testSettingsGetUsesTheSnakeCasedNames() async throws {
        let reply = try await client().send(.settingsGet, as: SettingsReply.self)

        XCTAssertEqual(reply.settings.port, 8765)
        XCTAssertTrue(reply.settings.keepAwake)
        XCTAssertEqual(reply.settings.logLevel, "INFO")
        XCTAssertEqual(reply.editable, ["port", "keep_awake", "log_level"])
    }

    func testARefusalArrivesAsTheDaemonsOwnMessage() async throws {
        let client = try client()

        do {
            _ = try await client.send(.settingsSet(key: "port", value: .int(80)), as: SettingsReply.self)
            XCTFail("expected the daemon to refuse a privileged port")
        } catch let error as ControlError {
            XCTAssertEqual(error, .daemon("port must be between 1024 and 65535, got 80"))
        }
    }

    func testAnAcceptedSettingComesBackChanged() async throws {
        let reply = try await client().send(
            .settingsSet(key: "port", value: .int(9000)), as: SettingsReply.self
        )
        XCTAssertEqual(reply.settings.port, 9000)
    }

    func testApprovingSendsTheDeviceIDPythonExpects() async throws {
        let envelope = try await client().call(.pairApprove("device-abc123"))
        XCTAssertTrue(envelope.ok)
    }

    // MARK: - The event stream

    func testTheSubscribeStreamAttachesAndDelivers() async throws {
        let client = try client()
        let collected = EventCollector()

        let stream = client.events()
        let pump = Task { for await event in stream { await collected.add(event) } }
        defer { pump.cancel() }

        // Waiting for `.attached` rather than sleeping: it is yielded after the
        // server acknowledged the subscription, so publishing now cannot race it.
        let attached = await eventually { await collected.contains { $0 == .attached } }
        XCTAssertTrue(attached, "the stream never attached")

        _ = try await client.call(
            Command("test.publish", [
                "event": .string("pairing.requested"),
                "fields": .object([
                    "deviceId": .string("d1"),
                    "deviceName": .string("iPhone"),
                    "appName": .string("TestApp"),
                    "requiredModels": .array([.string("qwen3-4b")]),
                    "waitingSeconds": .int(3),
                ]),
            ])
        )

        let arrived = await eventually {
            await collected.contains {
                if case .pairingRequested(let request) = $0 { return request.deviceId == "d1" }
                return false
            }
        }
        let seen = await collected.all
        XCTAssertTrue(arrived, "the pairing request never arrived; saw \(seen)")
    }

    func testAModelStateEventDecodesEndToEnd() async throws {
        let client = try client()
        let collected = EventCollector()

        let stream = client.events()
        let pump = Task { for await event in stream { await collected.add(event) } }
        defer { pump.cancel() }

        let attached = await eventually { await collected.contains { $0 == .attached } }
        XCTAssertTrue(attached, "the stream never attached")

        _ = try await client.call(
            Command("test.publish", [
                "event": .string("model.state"),
                "fields": .object(["model": .string("gpt-oss-20b"), "state": .string("running")]),
            ])
        )

        let arrived = await eventually {
            await collected.contains { $0 == .modelState(model: "gpt-oss-20b", state: "running") }
        }
        XCTAssertTrue(arrived)
    }

    /// Commands must keep working while a subscription is open — the dashboard
    /// issues both, and `control.py` keeps them on separate connections for
    /// exactly this reason.
    func testCommandsStillWorkAlongsideASubscription() async throws {
        let client = try client()
        let collected = EventCollector()

        let stream = client.events()
        let pump = Task { for await event in stream { await collected.add(event) } }
        defer { pump.cancel() }

        let attached = await eventually { await collected.contains { $0 == .attached } }
        XCTAssertTrue(attached, "the stream never attached")

        let status = try await client.send(.status, as: Status.self)
        XCTAssertEqual(status.port, 8765)
    }

    // MARK: - Failure modes

    func testAMissingSocketIsAnActionableMessage() async throws {
        let client = ControlClient(socketPath: "/tmp/bigbro-does-not-exist-\(UUID().uuidString).sock")

        do {
            _ = try await client.send(.status, as: Status.self)
            XCTFail("expected a refusal")
        } catch let error as ControlError {
            guard case .noDaemon = error else { return XCTFail("expected noDaemon, got \(error)") }
            XCTAssertTrue(error.description.contains("bigbro serve"))
        }
    }

    /// `sun_path` is 104 bytes, and macOS reports the overflow as a bare "AF_UNIX
    /// path too long" — which says nothing about which path, or why.
    func testAnOverlongPathSaysWhatToDoAboutIt() async throws {
        let client = ControlClient(socketPath: "/tmp/" + String(repeating: "x", count: 120))

        do {
            _ = try await client.send(.status, as: Status.self)
            XCTFail("expected a refusal")
        } catch let error as ControlError {
            guard case .pathTooLong = error else {
                return XCTFail("expected pathTooLong, got \(error)")
            }
            XCTAssertTrue(error.description.contains("BIGBRO_HOME"))
        }
    }
}

// MARK: - Harness

actor EventCollector {
    private(set) var all: [DaemonEvent] = []
    func add(_ event: DaemonEvent) { all.append(event) }
    func contains(_ predicate: (DaemonEvent) -> Bool) -> Bool { all.contains(where: predicate) }
}

/// Runs `tests/serve_stub.py` on a short socket path and waits for it to say `ready`.
final class PythonStubServer {
    let socketPath: String
    private let directory: URL
    private let process: Process

    /// The interpreter that can import `bigbro`, or nil if there isn't one.
    ///
    /// Prefers the project venv, since that is what `uv sync` builds and what CI
    /// has. Falls back to a system Python with `PYTHONPATH` pointed at `src`.
    static func findInterpreter() -> String? {
        let candidates = [
            Fixtures.repositoryRoot.appendingPathComponent(".venv/bin/python3").path,
            Fixtures.repositoryRoot.appendingPathComponent(".venv/bin/python").path,
            "/usr/bin/python3",
            "/usr/local/bin/python3",
            "/opt/homebrew/bin/python3",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    init(interpreter: String) throws {
        // Short on purpose: pytest's tmp paths overrun the 104-byte sun_path limit,
        // and so would anything under NSTemporaryDirectory().
        directory = URL(fileURLWithPath: "/tmp/bb-\(UUID().uuidString.prefix(8))")
        socketPath = directory.appendingPathComponent("c.sock").path

        let root = Fixtures.repositoryRoot
        process = Process()
        process.executableURL = URL(fileURLWithPath: interpreter)
        process.arguments = [root.appendingPathComponent("tests/serve_stub.py").path, socketPath]
        process.currentDirectoryURL = root

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONPATH"] = root.appendingPathComponent("src").path
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()

        // Blocking on the handshake rather than polling for the socket file, which
        // would race: the path exists between bind and listen.
        let handle = output.fileHandleForReading
        var buffer = Data()
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            if String(data: buffer, encoding: .utf8)?.contains("ready") == true { return }
        }

        process.terminate()
        throw XCTSkip("tests/serve_stub.py never reported ready")
    }

    func stop() {
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: directory)
    }
}
