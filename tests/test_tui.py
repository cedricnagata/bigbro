"""Dashboard tests, driven against a stub daemon over a real control socket.

The behaviour that matters most is the one that motivated the TUI: a pairing
request has to appear on its own, and Enter has to approve it. That is tested end
to end here — event pushed by the daemon, modal raised by the app, keypress turned
back into a `pair.approve` command on the socket.
"""

from __future__ import annotations

import asyncio
import shutil
import tempfile
from pathlib import Path

import pytest

from bigbro.control import ControlServer
from bigbro.events import EventBus
from bigbro.tui import BigBroApp, PairingPrompt


class StubDaemon:
    """Answers the control commands the dashboard issues, and records them."""

    def __init__(self) -> None:
        self.bus = EventBus()
        self.calls: list[dict] = []
        self.pending: list[dict] = []
        self.devices: list[dict] = [
            {"deviceId": "device-abc123", "name": "iPhone", "appName": "TestApp",
             "connected": True, "requiredModels": ["qwen3-4b"]},
        ]
        self.models: list[dict] = [
            {"id": "qwen3-4b", "name": "Qwen3 4B", "family": "language", "state": "not downloaded",
             "sizeGB": 2.4, "tools": True, "images": False, "reasoning": "think_tags_togglable"},
            {"id": "gpt-oss-20b", "name": "gpt-oss 20B", "family": "language", "state": "running",
             "sizeGB": 12.0, "tools": True, "images": False, "reasoning": "harmony"},
        ]
        self.settings = {"port": 8765, "keep_awake": True, "log_level": "INFO"}

    async def handle(self, request: dict) -> dict:
        self.calls.append(request)
        command = request.get("command")

        if command == "status":
            return {
                "ok": True, "name": "Test Mac", "port": 8765, "keepAwake": True,
                "paired": len(self.devices),
                "connected": [d["deviceId"] for d in self.devices if d["connected"]],
                "pending": self.pending, "running": ["gpt-oss-20b"], "downloaded": ["gpt-oss-20b"],
                "speech": {"tts": "not downloaded", "stt": "not downloaded"},
            }
        if command == "pair.list":
            return {"ok": True, "pending": self.pending, "devices": self.devices}
        if command in ("pair.approve", "pair.deny"):
            device_id = request.get("deviceId")
            self.pending = [p for p in self.pending if p["deviceId"] != device_id]
            return {"ok": True, "deviceId": device_id, "deviceName": "iPhone",
                    "approved": command == "pair.approve"}
        if command == "pair.remove":
            self.devices = [d for d in self.devices if d["deviceId"] != request.get("deviceId")]
            return {"ok": True, "deviceId": request.get("deviceId"), "name": "iPhone"}
        if command == "models.list":
            return {"ok": True, "models": self.models,
                    "speech": [{"id": "tts", "name": "Kokoro", "state": "not downloaded"}]}
        if command in ("models.start", "models.stop", "models.download", "models.delete"):
            return {"ok": True, "model": request.get("model")}
        if command == "settings.get":
            return {"ok": True, "settings": self.settings,
                    "editable": ["port", "keep_awake", "log_level"]}
        if command == "settings.set":
            key, value = request.get("key"), request.get("value")
            if key == "port" and str(value) == "80":
                return {"ok": False, "error": "port must be between 1024 and 65535, got 80"}
            self.settings[key] = value
            return {"ok": True, "message": "saved", "settings": self.settings}
        return {"ok": False, "error": f"unknown command '{command}'"}

    def commands(self) -> list[str]:
        return [c.get("command") for c in self.calls]


@pytest.fixture
async def daemon():
    directory = Path(tempfile.mkdtemp(dir="/tmp"))
    stub = StubDaemon()
    server = ControlServer(stub.handle, directory / "c.sock", bus=stub.bus)
    await server.start()
    stub.socket_path = directory / "c.sock"
    try:
        yield stub
    finally:
        await server.stop()
        shutil.rmtree(directory, ignore_errors=True)


async def _settled(pilot, predicate, timeout=3.0):
    """Waits for an async condition rather than guessing at a sleep duration."""
    deadline = asyncio.get_running_loop().time() + timeout
    while asyncio.get_running_loop().time() < deadline:
        await pilot.pause()
        if predicate():
            return True
        await asyncio.sleep(0.05)
    return False


# MARK: - Startup


async def test_dashboard_loads_daemon_state(daemon):
    app = BigBroApp(socket_path=daemon.socket_path)
    async with app.run_test() as pilot:
        assert await _settled(pilot, lambda: "status" in daemon.commands())
        assert await _settled(pilot, lambda: "models.list" in daemon.commands())
        assert "pair.list" in daemon.commands()
        assert "settings.get" in daemon.commands()


async def test_status_bar_reflects_the_daemon(daemon):
    from textual.widgets import Static

    app = BigBroApp(socket_path=daemon.socket_path)
    async with app.run_test() as pilot:
        await _settled(pilot, lambda: "status" in daemon.commands())
        bar = str(app.query_one("#status-bar", Static).content)
        assert "Test Mac" in bar
        assert "8765" in bar
        assert "awake" in bar


async def test_models_table_lists_the_catalog(daemon):
    from textual.widgets import DataTable

    app = BigBroApp(socket_path=daemon.socket_path)
    async with app.run_test() as pilot:
        table = app.query_one("#models-table", DataTable)
        assert await _settled(pilot, lambda: table.row_count >= 3)  # 2 models + speech


# MARK: - The pairing prompt


async def test_pairing_request_raises_a_prompt_on_its_own(daemon):
    """Nobody asked for this — it has to appear when the phone connects."""
    app = BigBroApp(socket_path=daemon.socket_path)
    async with app.run_test() as pilot:
        await _settled(pilot, lambda: daemon.bus.subscriber_count == 1)

        daemon.bus.publish(
            "pairing.requested", deviceId="new-device-1", deviceName="Cedric's iPhone",
            appName="MyApp", requiredModels=["qwen3-4b"], waitingSeconds=0,
        )

        assert await _settled(pilot, lambda: isinstance(app.screen, PairingPrompt))


async def test_enter_approves_the_pending_device(daemon):
    app = BigBroApp(socket_path=daemon.socket_path)
    async with app.run_test() as pilot:
        await _settled(pilot, lambda: daemon.bus.subscriber_count == 1)
        daemon.bus.publish(
            "pairing.requested", deviceId="new-device-1", deviceName="iPhone",
            appName="MyApp", requiredModels=[], waitingSeconds=0,
        )
        await _settled(pilot, lambda: isinstance(app.screen, PairingPrompt))

        await pilot.press("enter")

        assert await _settled(
            pilot, lambda: any(c.get("command") == "pair.approve" for c in daemon.calls)
        )
        approve = next(c for c in daemon.calls if c.get("command") == "pair.approve")
        assert approve["deviceId"] == "new-device-1"


async def test_escape_denies(daemon):
    app = BigBroApp(socket_path=daemon.socket_path)
    async with app.run_test() as pilot:
        await _settled(pilot, lambda: daemon.bus.subscriber_count == 1)
        daemon.bus.publish(
            "pairing.requested", deviceId="new-device-2", deviceName="iPhone",
            appName="MyApp", requiredModels=[], waitingSeconds=0,
        )
        await _settled(pilot, lambda: isinstance(app.screen, PairingPrompt))

        await pilot.press("escape")

        assert await _settled(
            pilot, lambda: any(c.get("command") == "pair.deny" for c in daemon.calls)
        )


async def test_a_retried_request_does_not_stack_prompts(daemon):
    """The daemon re-announces on retry; one device is one question."""
    app = BigBroApp(socket_path=daemon.socket_path)
    async with app.run_test() as pilot:
        await _settled(pilot, lambda: daemon.bus.subscriber_count == 1)
        for _ in range(3):
            daemon.bus.publish(
                "pairing.requested", deviceId="same-device", deviceName="iPhone",
                appName="MyApp", requiredModels=[], waitingSeconds=0,
            )
        await _settled(pilot, lambda: isinstance(app.screen, PairingPrompt))

        await pilot.press("enter")
        assert await _settled(
            pilot, lambda: any(c.get("command") == "pair.approve" for c in daemon.calls)
        )
        # Exactly one prompt was raised, so exactly one decision was sent.
        assert len([c for c in daemon.calls if c.get("command") == "pair.approve"]) == 1
        assert not isinstance(app.screen, PairingPrompt)


async def test_a_request_that_arrived_before_the_ui_attached_is_still_prompted(daemon):
    """Otherwise a device that knocked while nothing was watching waits out its timeout."""
    daemon.pending = [{
        "deviceId": "waiting-device", "deviceName": "iPad", "appName": "MyApp",
        "requiredModels": [], "waitingSeconds": 12,
    }]

    app = BigBroApp(socket_path=daemon.socket_path)
    async with app.run_test() as pilot:
        assert await _settled(pilot, lambda: isinstance(app.screen, PairingPrompt))


# MARK: - Model actions


async def test_stop_key_stops_the_selected_model(daemon):
    from textual.widgets import DataTable

    app = BigBroApp(socket_path=daemon.socket_path)
    async with app.run_test() as pilot:
        table = app.query_one("#models-table", DataTable)
        await _settled(pilot, lambda: table.row_count >= 2)

        app.query_one("TabbedContent").active = "models"
        await pilot.pause()
        table.move_cursor(row=1)  # gpt-oss-20b, state "running"
        await pilot.press("x")

        assert await _settled(
            pilot, lambda: any(c.get("command") == "models.stop" for c in daemon.calls)
        )
        assert next(c for c in daemon.calls if c.get("command") == "models.stop")["model"] == "gpt-oss-20b"


async def test_download_key_downloads_the_selected_model(daemon):
    from textual.widgets import DataTable

    app = BigBroApp(socket_path=daemon.socket_path)
    async with app.run_test() as pilot:
        table = app.query_one("#models-table", DataTable)
        await _settled(pilot, lambda: table.row_count >= 2)

        app.query_one("TabbedContent").active = "models"
        await pilot.pause()
        table.move_cursor(row=0)  # qwen3-4b, "not downloaded"
        await pilot.press("d")

        assert await _settled(
            pilot, lambda: any(c.get("command") == "models.download" for c in daemon.calls)
        )


async def test_download_progress_updates_state_without_a_full_reload(daemon):
    app = BigBroApp(socket_path=daemon.socket_path)
    async with app.run_test() as pilot:
        await _settled(pilot, lambda: daemon.bus.subscriber_count == 1)
        await _settled(pilot, lambda: bool(app._models))

        before = len(daemon.calls)
        daemon.bus.publish(
            "download.progress", model="qwen3-4b", status="downloading",
            completed=500, total=1000, fraction=0.5, done=False, error=None,
            state="downloading 50%",
        )

        assert await _settled(
            pilot,
            lambda: any(
                m["id"] == "qwen3-4b" and "50%" in str(m.get("state")) for m in app._models
            ),
        )
        # A progress tick must not trigger a full refresh — they arrive twice a second.
        assert not any(c.get("command") == "models.list" for c in daemon.calls[before:])


# MARK: - Settings


async def test_settings_are_populated_from_the_daemon(daemon):
    from textual.widgets import Input

    app = BigBroApp(socket_path=daemon.socket_path)
    async with app.run_test() as pilot:
        assert await _settled(
            pilot, lambda: app.query_one("#set-port", Input).value == "8765"
        )
        assert app.query_one("#set-keep-awake", Input).value == "true"


async def test_editing_a_setting_sends_it(daemon):
    from textual.widgets import Input

    app = BigBroApp(socket_path=daemon.socket_path)
    async with app.run_test() as pilot:
        await _settled(pilot, lambda: app.query_one("#set-port", Input).value == "8765")

        app.query_one("TabbedContent").active = "settings"
        await pilot.pause()
        port = app.query_one("#set-port", Input)
        port.focus()
        port.value = "9100"
        await pilot.press("enter")

        assert await _settled(
            pilot, lambda: any(c.get("command") == "settings.set" for c in daemon.calls)
        )
        sent = next(c for c in daemon.calls if c.get("command") == "settings.set")
        assert sent["key"] == "port" and sent["value"] == "9100"


async def test_a_rejected_setting_is_reported(daemon):
    from textual.widgets import Input, Static

    app = BigBroApp(socket_path=daemon.socket_path)
    async with app.run_test() as pilot:
        await _settled(pilot, lambda: app.query_one("#set-port", Input).value == "8765")

        app.query_one("TabbedContent").active = "settings"
        await pilot.pause()
        port = app.query_one("#set-port", Input)
        port.focus()
        port.value = "80"
        await pilot.press("enter")

        assert await _settled(
            pilot,
            lambda: "1024" in str(app.query_one("#settings-message", Static).content),
        )
        # The field is put back to what the daemon actually has.
        assert await _settled(pilot, lambda: app.query_one("#set-port", Input).value == "8765")


# MARK: - Keyboard navigation


async def test_the_table_takes_focus_so_arrow_keys_reach_it(daemon):
    """Activating a tab leaves focus on the tab bar, which freezes the selection."""
    from textual.widgets import DataTable

    app = BigBroApp(socket_path=daemon.socket_path)
    async with app.run_test() as pilot:
        table = app.query_one("#models-table", DataTable)
        await _settled(pilot, lambda: table.row_count >= 2)

        await pilot.press("2")  # Models
        assert await _settled(pilot, lambda: table.has_focus)

        await pilot.press("down")
        assert await _settled(pilot, lambda: table.cursor_row == 1)
        await pilot.press("down")
        assert await _settled(pilot, lambda: table.cursor_row == 2)
        await pilot.press("up")
        assert await _settled(pilot, lambda: table.cursor_row == 1)


async def test_devices_table_is_focused_on_startup(daemon):
    from textual.widgets import DataTable

    app = BigBroApp(socket_path=daemon.socket_path)
    async with app.run_test() as pilot:
        await _settled(pilot, lambda: "status" in daemon.commands())
        assert await _settled(pilot, lambda: app.query_one("#devices-table", DataTable).has_focus)


@pytest.mark.parametrize("key,pane", [("1", "devices"), ("2", "models"), ("3", "settings"), ("4", "log")])
async def test_number_keys_switch_panes(daemon, key, pane):
    from textual.widgets import TabbedContent

    app = BigBroApp(socket_path=daemon.socket_path)
    async with app.run_test() as pilot:
        await _settled(pilot, lambda: "status" in daemon.commands())
        await pilot.press(key)
        assert await _settled(pilot, lambda: app.query_one(TabbedContent).active == pane)


async def test_a_refresh_does_not_move_the_cursor_or_steal_focus(daemon):
    """Refreshes land every 5s; one that resets the selection makes the list unusable."""
    from textual.widgets import DataTable

    app = BigBroApp(socket_path=daemon.socket_path)
    async with app.run_test() as pilot:
        table = app.query_one("#models-table", DataTable)
        await _settled(pilot, lambda: table.row_count >= 2)
        await pilot.press("2")
        await _settled(pilot, lambda: table.has_focus)
        await pilot.press("down")
        await _settled(pilot, lambda: table.cursor_row == 1)

        await app.action_refresh()
        await pilot.pause()

        assert table.cursor_row == 1
        assert table.has_focus


async def test_verb_keys_type_into_a_settings_field_rather_than_firing(daemon):
    """`d`/`s`/`x` are model verbs, but in a text field they are just characters."""
    from textual.widgets import Input

    app = BigBroApp(socket_path=daemon.socket_path)
    async with app.run_test() as pilot:
        await _settled(pilot, lambda: app.query_one("#set-port", Input).value == "8765")
        await pilot.press("3")      # Settings — focuses the pane, not a field
        await pilot.press("tab")    # ...so tab into the field
        assert await _settled(pilot, lambda: app.query_one("#set-port", Input).has_focus)

        before = len(daemon.calls)
        await pilot.press("d", "s", "x")
        await pilot.pause()

        fired = [c for c in daemon.calls[before:] if str(c.get("command", "")).startswith("models.")]
        assert fired == []


async def test_clicking_a_tab_focuses_its_table(daemon):
    """The mouse path: a click activates the tab and could leave focus on the bar."""
    from textual.widgets import DataTable, Tab, TabbedContent

    app = BigBroApp(socket_path=daemon.socket_path)
    async with app.run_test() as pilot:
        table = app.query_one("#models-table", DataTable)
        await _settled(pilot, lambda: table.row_count >= 2)

        await pilot.click(app.query(Tab)[1])  # Models
        assert await _settled(pilot, lambda: app.query_one(TabbedContent).active == "models")
        assert await _settled(pilot, lambda: table.has_focus)

        await pilot.press("down")
        assert await _settled(pilot, lambda: table.cursor_row == 1)


async def test_arrowing_along_the_tab_bar_focuses_the_new_table(daemon):
    """The keyboard path through the tab strip itself, not the number shortcuts."""
    from textual.widgets import DataTable, TabbedContent

    app = BigBroApp(socket_path=daemon.socket_path)
    async with app.run_test() as pilot:
        table = app.query_one("#models-table", DataTable)
        await _settled(pilot, lambda: table.row_count >= 2)

        await pilot.press("1")
        await _settled(pilot, lambda: app.query_one("#devices-table", DataTable).has_focus)
        await pilot.press("shift+tab")   # up to the tab bar
        await pilot.press("right")       # across to Models

        assert await _settled(pilot, lambda: app.query_one(TabbedContent).active == "models")
        assert await _settled(pilot, lambda: table.has_focus)

        await pilot.press("down")
        assert await _settled(pilot, lambda: table.cursor_row == 1)


# MARK: - Pane navigation with the arrow keys


async def test_left_and_right_cycle_the_panes(daemon):
    """The tables and log bind left/right themselves; they have to give them back."""
    from textual.widgets import TabbedContent

    app = BigBroApp(socket_path=daemon.socket_path)
    async with app.run_test() as pilot:
        tabs = app.query_one(TabbedContent)
        await _settled(pilot, lambda: "status" in daemon.commands())

        for expected in ("models", "settings", "log", "devices"):
            await pilot.press("right")
            assert await _settled(pilot, lambda e=expected: tabs.active == e), expected

        for expected in ("log", "settings", "models", "devices"):
            await pilot.press("left")
            assert await _settled(pilot, lambda e=expected: tabs.active == e), expected


async def test_up_down_still_move_the_row_cursor(daemon):
    """Reclaiming left/right must not cost the vertical navigation."""
    from textual.widgets import DataTable

    app = BigBroApp(socket_path=daemon.socket_path)
    async with app.run_test() as pilot:
        table = app.query_one("#models-table", DataTable)
        await _settled(pilot, lambda: table.row_count >= 2)
        await pilot.press("2")
        await _settled(pilot, lambda: table.has_focus)

        await pilot.press("down")
        assert await _settled(pilot, lambda: table.cursor_row == 1)


async def test_settings_focuses_the_pane_not_a_field(daemon):
    """Landing in an Input traps the keyboard: left/right edit, 1-4 type digits."""
    from textual.containers import VerticalScroll
    from textual.widgets import TabbedContent

    app = BigBroApp(socket_path=daemon.socket_path)
    async with app.run_test() as pilot:
        tabs = app.query_one(TabbedContent)
        await _settled(pilot, lambda: "status" in daemon.commands())

        await pilot.press("3")
        assert await _settled(pilot, lambda: tabs.active == "settings")
        assert await _settled(pilot, lambda: isinstance(app.focused, VerticalScroll))

        # ...so arrowing onward still works rather than stranding you here.
        await pilot.press("right")
        assert await _settled(pilot, lambda: tabs.active == "log")


async def test_tab_reaches_the_settings_field_and_escape_leaves_it(daemon):
    from textual.containers import VerticalScroll
    from textual.widgets import Input, TabbedContent

    app = BigBroApp(socket_path=daemon.socket_path)
    async with app.run_test() as pilot:
        tabs = app.query_one(TabbedContent)
        await _settled(pilot, lambda: app.query_one("#set-port", Input).value == "8765")
        await pilot.press("3")
        await _settled(pilot, lambda: tabs.active == "settings")

        await pilot.press("tab")
        assert await _settled(pilot, lambda: app.query_one("#set-port", Input).has_focus)

        # In a field, left/right edit text rather than changing pane.
        port = app.query_one("#set-port", Input)
        port.value, port.cursor_position = "8765", 4
        await pilot.press("left")
        await pilot.pause()
        assert tabs.active == "settings"
        assert port.cursor_position == 3

        await pilot.press("escape")
        assert await _settled(pilot, lambda: isinstance(app.focused, VerticalScroll))
