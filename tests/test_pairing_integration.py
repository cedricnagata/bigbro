"""The whole pairing path, with nothing stubbed but inference.

A real Daemon, its real control socket, a real TCP client speaking the real framed
protocol, and the real dashboard attached. This is the test that would catch the
event bus, the subscribe stream, the modal and the approval command drifting apart
from each other — each of which is covered in isolation elsewhere and could still
fail to add up.

Bonjour and the power assertion are deliberately not started: they are global
side effects (a service published on the LAN, the Mac held awake) that a test run
should not have, and both are verified against the system directly instead.
"""

from __future__ import annotations

import asyncio
import shutil
import tempfile
from pathlib import Path

import pytest

from bigbro.protocol.framing import FrameDecoder, encode
from bigbro.tui import BigBroApp, PairingPrompt


@pytest.fixture
async def live(tmp_path, monkeypatch, unused_tcp_port):
    """A running daemon: peer listener + control socket, no Bonjour, no wake lock."""
    monkeypatch.setenv("BIGBRO_HOME", str(tmp_path))

    # The control socket must live somewhere short — pytest's tmp_path overruns
    # the 104-byte sun_path limit on macOS.
    socket_dir = Path(tempfile.mkdtemp(dir="/tmp"))
    socket_path = socket_dir / "c.sock"

    from bigbro.control import ControlServer
    from bigbro.daemon import Daemon

    daemon = Daemon(port=unused_tcp_port)
    daemon.control = ControlServer(daemon.handle_control, socket_path, bus=daemon.events)

    await daemon.server.start(unused_tcp_port, host="127.0.0.1")
    await daemon.control.start()

    daemon.socket_path = socket_path
    daemon.tcp_port = unused_tcp_port
    try:
        yield daemon
    finally:
        await daemon.control.stop()
        await daemon.server.stop()
        shutil.rmtree(socket_dir, ignore_errors=True)


class PhoneClient:
    """A BigBroKit stand-in speaking the real wire protocol."""

    def __init__(self, reader, writer):
        self.reader, self.writer = reader, writer
        self.decoder = FrameDecoder()
        self.inbox: list[dict] = []

    @classmethod
    async def connect(cls, port: int) -> "PhoneClient":
        reader, writer = await asyncio.open_connection("127.0.0.1", port)
        return cls(reader, writer)

    async def send(self, message: dict) -> None:
        self.writer.write(encode(message))
        await self.writer.drain()

    async def next(self, timeout=5.0) -> dict:
        while not self.inbox:
            chunk = await asyncio.wait_for(self.reader.read(65536), timeout)
            if not chunk:
                raise ConnectionError("daemon closed the connection")
            self.inbox.extend(self.decoder.feed(chunk))
        return self.inbox.pop(0)

    async def close(self) -> None:
        self.writer.close()


async def _settled(pilot, predicate, timeout=5.0) -> bool:
    deadline = asyncio.get_running_loop().time() + timeout
    while asyncio.get_running_loop().time() < deadline:
        await pilot.pause()
        if predicate():
            return True
        await asyncio.sleep(0.05)
    return False


async def test_phone_connects_prompt_appears_enter_approves(live):
    """The entire feature, in the order a person experiences it."""
    app = BigBroApp(socket_path=live.socket_path)
    async with app.run_test() as pilot:
        assert await _settled(pilot, lambda: live.events.subscriber_count == 1)

        phone = await PhoneClient.connect(live.tcp_port)
        await phone.send({
            "type": "hello", "deviceId": "iphone-1", "deviceName": "Cedric's iPhone",
            "appName": "MyApp", "requiredModels": [],
        })

        # The prompt appears without anyone asking for it.
        assert await _settled(pilot, lambda: isinstance(app.screen, PairingPrompt))

        await pilot.press("enter")

        ack = await asyncio.wait_for(phone.next(), 5)
        assert ack == {"type": "helloAck", "status": "approved"}
        assert live.pairing.is_approved("iphone-1")
        await phone.close()


async def test_escape_denies_and_the_phone_is_told(live):
    app = BigBroApp(socket_path=live.socket_path)
    async with app.run_test() as pilot:
        await _settled(pilot, lambda: live.events.subscriber_count == 1)

        phone = await PhoneClient.connect(live.tcp_port)
        await phone.send({
            "type": "hello", "deviceId": "iphone-2", "deviceName": "iPhone",
            "appName": "MyApp", "requiredModels": [],
        })
        assert await _settled(pilot, lambda: isinstance(app.screen, PairingPrompt))

        await pilot.press("escape")

        ack = await asyncio.wait_for(phone.next(), 5)
        assert ack == {"type": "helloAck", "status": "denied"}
        assert not live.pairing.is_approved("iphone-2")
        await phone.close()


async def test_a_known_device_reconnects_with_no_prompt(live):
    """Approval is once per device — a reconnect must not interrupt anyone."""
    live.pairing.approve("known-phone", "iPhone", "MyApp", [])

    app = BigBroApp(socket_path=live.socket_path)
    async with app.run_test() as pilot:
        await _settled(pilot, lambda: live.events.subscriber_count == 1)

        phone = await PhoneClient.connect(live.tcp_port)
        await phone.send({
            "type": "hello", "deviceId": "known-phone", "deviceName": "iPhone",
            "appName": "MyApp", "requiredModels": [],
        })

        ack = await asyncio.wait_for(phone.next(), 5)
        assert ack["status"] == "approved"
        assert not isinstance(app.screen, PairingPrompt)
        await phone.close()


async def test_the_devices_pane_follows_a_connection(live):
    from textual.widgets import DataTable

    app = BigBroApp(socket_path=live.socket_path)
    async with app.run_test() as pilot:
        await _settled(pilot, lambda: live.events.subscriber_count == 1)

        phone = await PhoneClient.connect(live.tcp_port)
        await phone.send({
            "type": "hello", "deviceId": "iphone-3", "deviceName": "iPhone",
            "appName": "MyApp", "requiredModels": [],
        })
        await _settled(pilot, lambda: isinstance(app.screen, PairingPrompt))
        await pilot.press("enter")
        await asyncio.wait_for(phone.next(), 5)

        table = app.query_one("#devices-table", DataTable)
        assert await _settled(pilot, lambda: table.row_count == 1)
        assert await _settled(pilot, lambda: len(live.server.connected_device_ids) == 1)

        await phone.close()
        assert await _settled(pilot, lambda: len(live.server.connected_device_ids) == 0)


async def test_settings_written_from_the_dashboard_persist(live, tmp_path):
    from bigbro.config import JSONStore, Settings
    from textual.widgets import Input

    app = BigBroApp(socket_path=live.socket_path)
    async with app.run_test() as pilot:
        assert await _settled(
            pilot, lambda: app.query_one("#set-log-level", Input).value == "INFO"
        )

        app.query_one("TabbedContent").active = "settings"
        await pilot.pause()
        field = app.query_one("#set-log-level", Input)
        field.focus()
        field.value = "DEBUG"
        await pilot.press("enter")

        assert await _settled(pilot, lambda: live.settings.log_level == "DEBUG")

    # And it survives a restart, which is the point of a config file.
    assert Settings.load(JSONStore(tmp_path / "config.json")).log_level == "DEBUG"
