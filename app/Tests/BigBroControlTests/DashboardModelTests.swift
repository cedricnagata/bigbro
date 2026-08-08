import Foundation
import XCTest

@testable import BigBroControl

/// The rules the Textual dashboard established, carried over one for one.
///
/// The names mirror `tests/test_tui.py` deliberately: that file is the only
/// executable spec of how this UI is supposed to behave, and keeping the
/// correspondence legible is what lets it be deleted without losing the argument
/// for why each rule is there.
@MainActor
final class DashboardModelTests: XCTestCase {
    private func model(_ transport: StubTransport) -> DashboardModel {
        DashboardModel(transport: transport)
    }

    // MARK: - Pairing

    func testPairingRequestRaisesAPromptOnItsOwn() async throws {
        let transport = try StubTransport()
        let dashboard = model(transport)

        await dashboard.handle(.pairingRequested(PendingRequest(deviceId: "d1", deviceName: "iPhone")))

        XCTAssertEqual(dashboard.prompt?.deviceId, "d1")
    }

    func testEnterApprovesThePendingDevice() async throws {
        let transport = try StubTransport()
        let dashboard = model(transport)
        await dashboard.handle(.pairingRequested(PendingRequest(deviceId: "d1")))
        transport.forgetTraffic()

        await dashboard.resolvePrompt(approved: true)

        XCTAssertTrue(transport.commands.contains("pair.approve"))
        XCTAssertFalse(transport.commands.contains("pair.deny"))
        XCTAssertNil(dashboard.prompt)
    }

    func testDismissingDeniesRatherThanStrandingThePhone() async throws {
        let transport = try StubTransport()
        let dashboard = model(transport)
        await dashboard.handle(.pairingRequested(PendingRequest(deviceId: "d1")))
        transport.forgetTraffic()

        await dashboard.resolvePrompt(approved: false)

        XCTAssertTrue(transport.commands.contains("pair.deny"))
    }

    /// The daemon re-announces a parked request when the phone retries; a sheet per
    /// retry would bury the Approve button under copies of itself.
    func testARetriedRequestDoesNotStackPrompts() async throws {
        let transport = try StubTransport()
        let dashboard = model(transport)
        let request = PendingRequest(deviceId: "d1", deviceName: "iPhone")

        await dashboard.handle(.pairingRequested(request))
        await dashboard.handle(.pairingRequested(request))
        await dashboard.handle(.pairingRequested(request))

        XCTAssertEqual(dashboard.prompt?.deviceId, "d1")

        // And once answered, exactly one decision goes out.
        transport.forgetTraffic()
        await dashboard.resolvePrompt(approved: true)
        XCTAssertEqual(transport.count(of: "pair.approve"), 1)
        XCTAssertNil(dashboard.prompt)
    }

    /// A request parked before this client attached produced no event we saw, so
    /// the only way to notice it is to look at `pair.list`. Without this, a phone
    /// that asked while the app was closed waits out its timeout unasked.
    func testARequestThatArrivedBeforeWeAttachedIsStillPrompted() async throws {
        let transport = try StubTransport()
        transport.reply(to: "pair.list", with: StubTransport.pairList(pending: ["d-early"]))
        let dashboard = model(transport)

        await dashboard.refresh()

        XCTAssertEqual(dashboard.prompt?.deviceId, "d-early")
        XCTAssertEqual(dashboard.pending.count, 1)
    }

    func testAResolvedDeviceCanAskAgainLater() async throws {
        let transport = try StubTransport()
        let dashboard = model(transport)

        await dashboard.handle(.pairingRequested(PendingRequest(deviceId: "d1")))
        await dashboard.resolvePrompt(approved: false)
        XCTAssertNil(dashboard.prompt)

        // Denial is not a permanent verdict — the same phone may try again.
        await dashboard.handle(.pairingRequested(PendingRequest(deviceId: "d1")))
        XCTAssertEqual(dashboard.prompt?.deviceId, "d1")
    }

    // MARK: - Model rows

    private func downloading(_ fraction: Double) -> DaemonEvent {
        .downloadProgress(
            DownloadProgress(
                model: "m1", status: "downloading", state: "downloading",
                completed: Int(fraction * 100), total: 100, fraction: fraction, done: false
            )
        )
    }

    private func loadedDashboard(
        _ transport: StubTransport, states: [(id: String, state: String)]
    ) async -> DashboardModel {
        transport.reply(to: "models.list", with: StubTransport.modelsList(states))
        let dashboard = model(transport)
        await dashboard.refresh()
        transport.forgetTraffic()
        return dashboard
    }

    /// Progress arrives twice a second. Re-fetching on each tick would fight the
    /// selection and flicker for no new information.
    func testAProgressTickDoesNotRefetchTheModelList() async throws {
        let transport = try StubTransport()
        let dashboard = await loadedDashboard(transport, states: [("m1", "downloading 10%")])

        await dashboard.handle(downloading(0.2))

        XCTAssertEqual(transport.count(of: "models.list"), 0)
        XCTAssertEqual(dashboard.groups[0].models[0].state, "downloading 20%")
    }

    /// Rows are ranked by how far along a model is, so a real stage change has to
    /// re-sort — and the ranking is the daemon's, so it is asked rather than
    /// reproduced here.
    func testAStageChangeRefetchesSoTheDaemonCanReorder() async throws {
        let transport = try StubTransport()
        let dashboard = await loadedDashboard(transport, states: [("m1", "downloading 90%")])

        await dashboard.handle(.modelState(model: "m1", state: "downloaded"))

        XCTAssertEqual(transport.count(of: "models.list"), 1)
    }

    func testAFinishedDownloadIsAStageChange() async throws {
        let transport = try StubTransport()
        let dashboard = await loadedDashboard(transport, states: [("m1", "downloading 99%")])

        await dashboard.handle(
            .downloadProgress(
                DownloadProgress(
                    model: "m1", state: "downloaded", completed: 100, total: 100,
                    fraction: 1.0, done: true
                )
            )
        )

        XCTAssertEqual(transport.count(of: "models.list"), 1)
    }

    func testStateForAnUnknownModelIsIgnored() async throws {
        let transport = try StubTransport()
        let dashboard = await loadedDashboard(transport, states: [("m1", "downloaded")])

        await dashboard.handle(.modelState(model: "not-in-the-catalog", state: "running"))

        XCTAssertEqual(transport.count(of: "models.list"), 0)
        XCTAssertEqual(dashboard.groups[0].models[0].state, "downloaded")
    }

    func testStartingAModelDoesNotWaitForItToLoad() async throws {
        let transport = try StubTransport()
        let dashboard = await loadedDashboard(transport, states: [("m1", "downloaded")])

        // A 12 GB load would hold the reply long enough to look like a freeze, so
        // the daemon answers immediately and reports progress as events. Re-reading
        // here would just show the same "downloaded" back.
        await dashboard.start("m1")

        XCTAssertEqual(transport.commands, ["models.start"])
    }

    // MARK: - Settings

    func testARejectedSettingIsReportedAndTheOldValueKept() async throws {
        let transport = try StubTransport()
        transport.reply(
            to: "settings.set",
            with: #"{"ok": false, "error": "port must be between 1024 and 65535, got 80"}"#
        )
        let dashboard = model(transport)
        await dashboard.refresh()

        let accepted = await dashboard.set("port", to: .int(80))

        XCTAssertFalse(accepted)
        XCTAssertEqual(dashboard.lastMessage, "port must be between 1024 and 65535, got 80")
        // Still 8765 — the field has something true to reset to.
        XCTAssertEqual(dashboard.settings?.port, 8765)
    }

    func testAnAcceptedSettingCarriesTheDaemonsMessage() async throws {
        let transport = try StubTransport()
        transport.reply(to: "settings.set", with: """
            {"ok": true, "message": "restart the daemon for it to take effect",
             "settings": {"port": 9000, "keep_awake": true, "log_level": "INFO"}}
            """)
        let dashboard = model(transport)

        let accepted = await dashboard.set("port", to: .int(9000))

        XCTAssertTrue(accepted)
        XCTAssertEqual(dashboard.settings?.port, 9000)
        XCTAssertEqual(dashboard.lastMessage, "restart the daemon for it to take effect")
    }

    func testSettingsChangedFromAnotherClientIsPickedUp() async throws {
        let transport = try StubTransport()
        let dashboard = model(transport)
        await dashboard.refresh()

        // Someone ran `bigbro` in a terminal. The pane has to follow.
        await dashboard.handle(
            .settingsChanged(
                try JSONDecoder().decode(
                    SettingsValues.self,
                    from: Data(#"{"port": 9100, "keep_awake": false, "log_level": "DEBUG"}"#.utf8)
                )
            )
        )

        XCTAssertEqual(dashboard.settings?.port, 9100)
        XCTAssertEqual(dashboard.settings?.keepAwake, false)
    }

    // MARK: - Stream state and the log

    func testAttachingReadsEverything() async throws {
        let transport = try StubTransport()
        let dashboard = model(transport)

        await dashboard.handle(.attached)

        XCTAssertTrue(dashboard.isAttached)
        XCTAssertEqual(
            Set(transport.commands), ["status", "pair.list", "settings.get", "models.list"]
        )
        XCTAssertNotNil(dashboard.status)
    }

    func testDetachingSaysWhy() async throws {
        let transport = try StubTransport()
        let dashboard = model(transport)

        await dashboard.handle(.detached(reason: "No running daemon found at /tmp/c.sock."))

        XCTAssertFalse(dashboard.isAttached)
        XCTAssertEqual(dashboard.lastMessage, "No running daemon found at /tmp/c.sock.")
    }

    func testLogLinesAccumulateAndAreCapped() async throws {
        let transport = try StubTransport()
        let dashboard = model(transport)

        for index in 0..<(DashboardModel.logCapacity + 25) {
            await dashboard.handle(.log(level: "INFO", logger: "bigbro", message: "line \(index)"))
        }

        XCTAssertEqual(dashboard.logLines.count, DashboardModel.logCapacity)
        // The newest survived; the oldest were dropped.
        XCTAssertEqual(dashboard.logLines.last?.message, "line \(DashboardModel.logCapacity + 24)")
        XCTAssertEqual(dashboard.logLines.first?.message, "line 25")
    }

    func testAnUnknownEventChangesNothing() async throws {
        let transport = try StubTransport()
        let dashboard = model(transport)
        await dashboard.refresh()
        transport.forgetTraffic()

        await dashboard.handle(.unknown(name: "bonjour.failed"))

        XCTAssertEqual(transport.commands, [])
        XCTAssertNil(dashboard.lastMessage)
    }

    func testAPeerChangeRereadsTheDeviceList() async throws {
        let transport = try StubTransport()
        let dashboard = model(transport)
        transport.forgetTraffic()

        await dashboard.handle(.peerConnected(deviceId: "d1", connected: ["d1"]))

        XCTAssertTrue(transport.commands.contains("pair.list"))
    }

    func testLeadingWordIsWhatDecidesAMove() {
        XCTAssertEqual(DashboardModel.leadingWord("downloading 12%"), "downloading")
        XCTAssertEqual(DashboardModel.leadingWord("downloaded"), "downloaded")
        XCTAssertEqual(DashboardModel.leadingWord(""), "")
        XCTAssertEqual(DashboardModel.leadingWord(nil), "")
        XCTAssertEqual(DashboardModel.leadingWord("error: no space left"), "error:")
    }
}

// MARK: - Work someone else started

@MainActor
final class RemoteWorkTests: XCTestCase {
    private func loaded(
        _ transport: StubTransport, _ states: [(id: String, state: String)]
    ) async -> DashboardModel {
        transport.reply(to: "models.list", with: StubTransport.modelsList(states))
        let dashboard = DashboardModel(transport: transport)
        await dashboard.refresh()
        transport.forgetTraffic()
        return dashboard
    }

    /// The bug this covers: a model started from an iPhone showed no spinner.
    ///
    /// The spinner was driven entirely by a flag this app set when it sent a
    /// command, so it was really reporting "I asked for this" rather than "this
    /// is loading". A phone's `run` sets no such flag, which is why the gap only
    /// appeared remotely — and why it looked fine every time it was tested by
    /// pressing the button.
    func testAModelStartedElsewhereShowsAsBusy() async throws {
        let transport = try StubTransport()
        let dashboard = await loaded(transport, [("m1", "downloaded")])
        XCTAssertFalse(dashboard.isBusy("m1"))

        // A stage change re-reads the list, so the stub has to answer the way the
        // daemon would once the load has begun — otherwise the refetch puts
        // "downloaded" straight back and the test measures the stub, not the app.
        transport.reply(to: "models.list", with: StubTransport.modelsList([("m1", "starting")]))
        await dashboard.handle(.modelState(model: "m1", state: "starting"))

        XCTAssertTrue(dashboard.isBusy("m1"), "a load someone else began still shows no spinner")
    }

    func testItStopsBeingBusyOnceItIsRunning() async throws {
        let transport = try StubTransport()
        let dashboard = await loaded(transport, [("m1", "starting")])
        XCTAssertTrue(dashboard.isBusy("m1"))

        transport.reply(to: "models.list", with: StubTransport.modelsList([("m1", "running")]))
        await dashboard.handle(.modelState(model: "m1", state: "running"))

        XCTAssertFalse(dashboard.isBusy("m1"))
    }

    /// A download draws a determinate bar with a percentage on it; a spinner
    /// beside it would be two answers to one question.
    func testADownloadIsNotSpunOver() async throws {
        let transport = try StubTransport()
        let dashboard = await loaded(transport, [("m1", "downloading 42%")])
        XCTAssertFalse(dashboard.isBusy("m1"))
    }

    func testAFailedLoadClearsTheSpinner() async throws {
        let transport = try StubTransport()
        let dashboard = await loaded(transport, [("m1", "starting")])
        XCTAssertTrue(dashboard.isBusy("m1"))

        transport.reply(
            to: "models.list", with: StubTransport.modelsList([("m1", "error: no space left")])
        )
        await dashboard.handle(.modelState(model: "m1", state: "error: no space left"))

        // Otherwise the row spins forever over something already given up on.
        XCTAssertFalse(dashboard.isBusy("m1"))
    }
}
