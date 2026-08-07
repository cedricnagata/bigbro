import Foundation
import XCTest

@testable import BigBroControl

/// Decoding, against the real daemon's real replies.
final class WireDecodingTests: XCTestCase {
    func testStatusDecodesFromTheFixture() throws {
        let status = try Reply.decode(Status.self, from: try Fixtures.data("status"))

        XCTAssertEqual(status.port, 8765)
        XCTAssertEqual(status.paired, 0)
        XCTAssertEqual(Set(status.speech.keys), ["tts", "stt"])
    }

    /// The trap this whole file exists for.
    ///
    /// `status` sends `keepAwake` and `settings.get` sends `keep_awake`. A single
    /// `.convertFromSnakeCase` strategy would decode neither correctly, and the
    /// failure is silent: `keepAwake` would simply be absent and the status bar
    /// would report that the Mac is not being held awake. Pinned on the daemon side
    /// by `test_status_keeps_its_one_camel_cased_key`.
    func testTheTwoCasingsBothDecode() throws {
        let status = try Reply.decode(Status.self, from: try Fixtures.data("status"))
        let settings = try Reply.decode(SettingsReply.self, from: try Fixtures.data("settings_get"))

        // Both are real values read off the wire, not defaults standing in for a
        // key that never arrived.
        XCTAssertEqual(status.keepAwake, false)
        XCTAssertEqual(settings.settings.keepAwake, true)
        XCTAssertEqual(settings.settings.port, 8765)
        XCTAssertEqual(settings.settings.logLevel, "INFO")
        XCTAssertEqual(settings.editable, ["port", "keep_awake", "log_level"])
    }

    func testModelsListDecodesEveryGroup() throws {
        let list = try Reply.decode(ModelsList.self, from: try Fixtures.data("models_list"))

        XCTAssertEqual(list.groups.map(\.family), ["language", "vision", "tts", "stt"])
        XCTAssertFalse(list.groups.allSatisfy { $0.models.isEmpty })
    }

    /// Speech models are not in MLXEngine's bookkeeping, so they report no memory
    /// at all — which has to decode as absent, not as zero.
    func testSpeechEntriesCarryNoMemory() throws {
        let list = try Reply.decode(ModelsList.self, from: try Fixtures.data("models_list"))
        let speech = list.groups.filter { ["tts", "stt"].contains($0.family) }.flatMap(\.models)

        XCTAssertFalse(speech.isEmpty)
        XCTAssertTrue(speech.allSatisfy { $0.memory == nil })
    }

    /// `speech` arrives as an object from a current daemon and as a bare string
    /// from an older one — `__main__.py` still handles both, and the dashboard's
    /// own stub sends the string form. A synthesised `Codable` would throw on the
    /// string and take the entire `status` decode down with it.
    func testSpeechDecodesFromEitherShape() throws {
        let structured = #"{"name": "Kokoro 82M", "model": "kokoro", "state": "running"}"#
        let bare = #""not downloaded""#

        let fromObject = try JSONDecoder().decode(SpeechInfo.self, from: Data(structured.utf8))
        XCTAssertEqual(fromObject.state, "running")
        XCTAssertEqual(fromObject.name, "Kokoro 82M")

        let fromString = try JSONDecoder().decode(SpeechInfo.self, from: Data(bare.utf8))
        XCTAssertEqual(fromString.state, "not downloaded")
        XCTAssertNil(fromString.name)
    }

    func testAMemoryReportOfNullsIsStillAReport() throws {
        let status = try Reply.decode(Status.self, from: try Fixtures.data("status"))

        // Off a Mac — or before anything loads — every figure is genuinely unknown.
        XCTAssertNil(status.memory.headline)
        XCTAssertTrue(status.memory.mlx.isEmpty)
        XCTAssertEqual(status.memory.summary, "?")
    }

    /// A daemon that predates the memory probe sends no `memory` key at all, and
    /// an absent report says exactly what a present one full of nulls says.
    ///
    /// Found by `PythonServerTests` rather than by anything here: `memory` was
    /// required, and the stub server — standing in for that older daemon — omits
    /// it, so the whole `status` decode threw. A stub written on this side would
    /// have been written to match the decoder and never caught it.
    func testAStatusWithoutMemoryStillDecodes() throws {
        let reply = """
            {"ok": true, "name": "Test Mac", "port": 8765, "keepAwake": true, "paired": 1,
             "connected": ["d1"], "pending": [], "running": [], "downloaded": [],
             "speech": {"tts": "not downloaded", "stt": "not downloaded"}}
            """

        let status = try Reply.decode(Status.self, from: Data(reply.utf8))

        XCTAssertEqual(status.name, "Test Mac")
        XCTAssertNil(status.memory.headline)
        XCTAssertEqual(status.memory.summary, "?")
    }

    /// The other side of that trade: a core key going missing is still loud.
    func testAStatusMissingACoreKeyFailsRatherThanDefaulting() {
        let reply = """
            {"ok": true, "name": "Test Mac", "paired": 0, "keepAwake": true,
             "connected": [], "pending": [], "running": [], "downloaded": [], "speech": {}}
            """

        // No `port`. Defaulting it to 0 would leave the UI quietly claiming the
        // daemon listens somewhere it does not.
        XCTAssertThrowsError(try Reply.decode(Status.self, from: Data(reply.utf8)))
    }

    func testAFailedReplyThrowsTheDaemonsOwnWords() {
        let refusal = #"{"ok": false, "error": "port must be between 1024 and 65535, got 80"}"#

        XCTAssertThrowsError(try Reply.decode(Status.self, from: Data(refusal.utf8))) { error in
            XCTAssertEqual(
                error as? ControlError,
                .daemon("port must be between 1024 and 65535, got 80")
            )
        }
    }

    func testACommandEncodesItsArgumentsAlongsideItsName() throws {
        let encoded = try JSONEncoder().encode(Command.pairApprove("device-abc123"))
        let decoded = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]

        XCTAssertEqual(decoded?["command"] as? String, "pair.approve")
        XCTAssertEqual(decoded?["deviceId"] as? String, "device-abc123")
    }

    func testSettingsSetKeepsAPortAnInteger() throws {
        // Decoded as a Double it would go out as 9000.0 and be rejected.
        let encoded = try JSONEncoder().encode(Command.settingsSet(key: "port", value: .int(9000)))
        XCTAssertEqual(String(data: encoded, encoding: .utf8)?.contains("9000.0"), false)
    }
}

final class DaemonEventDecodingTests: XCTestCase {
    private func event(_ json: String) throws -> DaemonEvent {
        try DaemonEvent(from: Data(json.utf8))
    }

    func testLogDecodes() throws {
        let decoded = try event(
            #"{"event": "log", "level": "WARNING", "logger": "bigbro", "message": "port in use"}"#
        )
        XCTAssertEqual(decoded, .log(level: "WARNING", logger: "bigbro", message: "port in use"))
    }

    func testPairingRequestedCarriesTheWholeRequest() throws {
        let decoded = try event("""
            {"event": "pairing.requested", "deviceId": "d1", "deviceName": "iPhone",
             "appName": "TestApp", "requiredModels": ["qwen3-4b"], "waitingSeconds": 3}
            """)
        guard case .pairingRequested(let request) = decoded else {
            return XCTFail("expected pairingRequested, got \(decoded)")
        }
        XCTAssertEqual(request.deviceId, "d1")
        XCTAssertEqual(request.displayName, "iPhone")
        XCTAssertEqual(request.requiredModels, ["qwen3-4b"])
    }

    func testAnUnnamedDeviceFallsBackToATruncatedID() throws {
        let request = PendingRequest(deviceId: "device-abc123456789")
        XCTAssertEqual(request.displayName, "device-a")
    }

    func testPeerEventsAreDistinguished() throws {
        let up = try event(#"{"event": "peer.connected", "deviceId": "d1", "connected": ["d1"]}"#)
        let down = try event(#"{"event": "peer.disconnected", "deviceId": "d1", "connected": []}"#)

        XCTAssertEqual(up, .peerConnected(deviceId: "d1", connected: ["d1"]))
        XCTAssertEqual(down, .peerDisconnected(deviceId: "d1", connected: []))
    }

    func testDownloadProgressBuildsItsOwnPercentage() throws {
        let decoded = try event("""
            {"event": "download.progress", "model": "gpt-oss-20b", "status": "downloading",
             "completed": 6000000000, "total": 12000000000, "fraction": 0.5,
             "done": false, "error": null, "state": "downloading"}
            """)
        guard case .downloadProgress(let progress) = decoded else {
            return XCTFail("expected downloadProgress, got \(decoded)")
        }
        XCTAssertEqual(progress.displayState, "downloading 50%")
        XCTAssertEqual(progress.byteProgress, "5.6 GB of 11.2 GB")
    }

    func testAFinishedDownloadReportsTheSettledStateNotAPercentage() throws {
        let decoded = try event("""
            {"event": "download.progress", "model": "gpt-oss-20b", "status": "complete",
             "completed": 12, "total": 12, "fraction": 1.0, "done": true, "state": "downloaded"}
            """)
        guard case .downloadProgress(let progress) = decoded else {
            return XCTFail("expected downloadProgress, got \(decoded)")
        }
        XCTAssertEqual(progress.displayState, "downloaded")
    }

    func testSettingsChangedCarriesTheNewSettings() throws {
        let decoded = try event("""
            {"event": "settings.changed",
             "settings": {"port": 9000, "keep_awake": false, "log_level": "DEBUG"}}
            """)
        guard case .settingsChanged(let settings) = decoded else {
            return XCTFail("expected settingsChanged, got \(decoded)")
        }
        XCTAssertEqual(settings.port, 9000)
        XCTAssertEqual(settings.keepAwake, false)
    }

    /// The daemon and the app ship separately, so a newer daemon publishing
    /// something this build predates has to be ignorable rather than fatal.
    func testAnUnrecognisedEventIsCarriedNotThrown() throws {
        let decoded = try event(#"{"event": "bonjour.failed", "reason": "denied"}"#)
        XCTAssertEqual(decoded, .unknown(name: "bonjour.failed"))
    }
}
