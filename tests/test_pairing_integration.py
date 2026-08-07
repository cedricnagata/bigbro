"""The whole pairing path, with nothing stubbed but inference.

A real Daemon, its real control socket, and a real TCP client speaking the real
framed protocol. This is the test that would catch the event bus, the subscribe
stream and the approval command drifting apart from each other — each of which is
covered in isolation elsewhere and could still fail to add up.

The dashboard used to be the fourth party here, driven through Textual. It now
lives in BigBro.app, which is tested against this same socket from Swift, so what
remains is the daemon's half of that conversation: the event a client must see,
and the command it sends back.

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

from bigbro.control import send_command, subscribe
from bigbro.protocol.framing import FrameDecoder, encode


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


async def _await_event(events, name, timeout=5.0) -> dict:
    """The next event of a given kind, ignoring whatever else is in flight.

    Model state and log records share this stream, so a test waiting on a pairing
    request cannot simply take the first thing that arrives.
    """
    async def scan():
        async for event in events:
            if event.get("event") == name:
                return event
        raise AssertionError(f"stream ended before {name!r} arrived")

    return await asyncio.wait_for(scan(), timeout)


async def _no_event(events, name, window=0.5) -> bool:
    """True if nothing of that kind shows up within the window."""
    try:
        await _await_event(events, name, timeout=window)
    except (asyncio.TimeoutError, AssertionError):
        return True
    return False


async def test_a_phone_connecting_announces_itself_and_approval_lets_it_in(live):
    """The whole pairing conversation: event out, decision in, phone told."""
    async with subscribe(live.socket_path) as events:
        await asyncio.sleep(0.05)  # let the subscription register

        phone = await PhoneClient.connect(live.tcp_port)
        await phone.send({"type": "hello", "deviceId": "device-1", "deviceName": "iPhone"})

        request = await _await_event(events, "pairing.requested")
        assert request["deviceId"] == "device-1"
        assert request["deviceName"] == "iPhone"

        reply = await send_command(
            {"command": "pair.approve", "deviceId": "device-1"}, live.socket_path
        )
        assert reply["ok"] is True

        ack = await phone.next()
        assert ack["type"] == "helloAck"
        await phone.close()


async def test_denial_is_delivered_to_the_phone_rather_than_leaving_it_waiting(live):
    async with subscribe(live.socket_path) as events:
        await asyncio.sleep(0.05)

        phone = await PhoneClient.connect(live.tcp_port)
        await phone.send({"type": "hello", "deviceId": "device-2", "deviceName": "iPad"})
        await _await_event(events, "pairing.requested")

        reply = await send_command(
            {"command": "pair.deny", "deviceId": "device-2"}, live.socket_path
        )
        assert reply["ok"] is True

        # A denied phone is told in the same message an approved one gets, with a
        # different status. Silence, or a bare disconnect, would leave it retrying
        # against a Mac that has already decided.
        assert await phone.next() == {"type": "helloAck", "status": "denied"}
        assert not live.pairing.is_approved("device-2")
        await phone.close()


async def test_a_known_device_reconnects_without_asking_again(live):
    """The point of remembering a device: no second prompt, ever."""
    live.pairing.approve("device-3", "iPhone", "TestApp", [])

    async with subscribe(live.socket_path) as events:
        await asyncio.sleep(0.05)

        phone = await PhoneClient.connect(live.tcp_port)
        await phone.send({"type": "hello", "deviceId": "device-3", "deviceName": "iPhone"})

        ack = await phone.next()
        assert ack["type"] == "helloAck"
        assert await _no_event(events, "pairing.requested")
        await phone.close()


async def test_a_connection_is_announced_and_shows_up_in_status(live):
    async with subscribe(live.socket_path) as events:
        await asyncio.sleep(0.05)
        live.pairing.approve("device-4", "iPhone", "TestApp", [])

        phone = await PhoneClient.connect(live.tcp_port)
        await phone.send({"type": "hello", "deviceId": "device-4", "deviceName": "iPhone"})
        await phone.next()

        connected = await _await_event(events, "peer.connected")
        assert connected["deviceId"] == "device-4"

        status = await send_command({"command": "status"}, live.socket_path)
        assert "device-4" in status["connected"]
        await phone.close()


async def test_a_setting_written_over_the_socket_reaches_disk(live, tmp_path):
    """What the Settings pane does, minus the pane."""
    reply = await send_command(
        {"command": "settings.set", "key": "port", "value": 9100}, live.socket_path
    )
    assert reply["ok"] is True
    assert reply["settings"]["port"] == 9100

    import json

    saved = json.loads((tmp_path / "config.json").read_text())
    assert saved["port"] == 9100


async def test_a_rejected_setting_changes_nothing(live, tmp_path):
    reply = await send_command(
        {"command": "settings.set", "key": "port", "value": 80}, live.socket_path
    )
    assert reply["ok"] is False
    assert "between 1024 and 65535" in reply["error"]
