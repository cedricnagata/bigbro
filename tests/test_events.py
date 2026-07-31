"""Event bus and the control socket's subscribe mode.

The dashboard's whole premise is that a pairing request appears without anyone
asking for it, so this is the plumbing that has to be right: fan-out that never
blocks the daemon, and a long-lived connection that notices when its client goes
away.
"""

from __future__ import annotations

import asyncio
import shutil
import tempfile
from pathlib import Path

import pytest

from bigbro.config import JSONStore, Settings
from bigbro.control import ControlServer, send_command, subscribe
from bigbro.events import QUEUE_SIZE, EventBus, LogEventHandler


@pytest.fixture
def socket_dir():
    directory = Path(tempfile.mkdtemp(dir="/tmp"))
    try:
        yield directory
    finally:
        shutil.rmtree(directory, ignore_errors=True)


# MARK: - EventBus


def test_publish_with_no_subscribers_is_a_noop():
    """Daemon code publishes unconditionally; it must not care whether a UI exists."""
    EventBus().publish("pairing.requested", deviceId="d1")


async def test_subscriber_receives_published_events():
    bus = EventBus()
    queue = bus.subscribe()
    bus.publish("peer.connected", deviceId="d1")

    assert await asyncio.wait_for(queue.get(), 1) == {
        "event": "peer.connected", "deviceId": "d1",
    }


async def test_every_subscriber_gets_its_own_copy():
    bus = EventBus()
    first, second = bus.subscribe(), bus.subscribe()
    bus.publish("model.state", model="qwen3-4b", state="running")

    assert (await first.get())["model"] == "qwen3-4b"
    assert (await second.get())["model"] == "qwen3-4b"


async def test_unsubscribe_stops_delivery():
    bus = EventBus()
    queue = bus.subscribe()
    bus.unsubscribe(queue)
    bus.publish("peer.connected", deviceId="d1")
    assert queue.empty()


async def test_a_stalled_subscriber_loses_history_not_the_latest():
    """Backpressure onto the daemon is never the right trade for a UI update."""
    bus = EventBus()
    queue = bus.subscribe()

    for index in range(QUEUE_SIZE + 50):
        bus.publish("download.progress", n=index)

    assert queue.qsize() == QUEUE_SIZE
    drained = [queue.get_nowait()["n"] for _ in range(QUEUE_SIZE)]
    # The newest event survived; the oldest were dropped.
    assert drained[-1] == QUEUE_SIZE + 49
    assert drained[0] == 50


async def test_a_stalled_subscriber_does_not_block_a_healthy_one():
    bus = EventBus()
    stalled, healthy = bus.subscribe(), bus.subscribe()
    for index in range(QUEUE_SIZE + 10):
        bus.publish("download.progress", n=index)

    assert healthy.qsize() == QUEUE_SIZE
    assert stalled.qsize() == QUEUE_SIZE


async def test_log_handler_mirrors_records_onto_the_bus():
    import logging

    bus = EventBus()
    queue = bus.subscribe()
    logger = logging.getLogger("bigbro.test-log-mirror")
    logger.addHandler(LogEventHandler(bus))
    logger.setLevel(logging.INFO)
    try:
        logger.warning("device %s wants to pair", "abc")
    finally:
        logger.handlers.clear()

    event = await asyncio.wait_for(queue.get(), 1)
    assert event["event"] == "log"
    assert event["level"] == "WARNING"
    assert event["message"] == "device abc wants to pair"


# MARK: - Control socket subscribe


async def test_subscribe_streams_events(socket_dir):
    bus = EventBus()

    async def handler(_request):
        return {"ok": True}

    server = ControlServer(handler, socket_dir / "c.sock", bus=bus)
    await server.start()
    try:
        async with subscribe(socket_dir / "c.sock") as events:
            await asyncio.sleep(0.05)  # let the subscription register
            bus.publish("pairing.requested", deviceId="d1", deviceName="iPhone")

            event = await asyncio.wait_for(events.__anext__(), 2)
            assert event["event"] == "pairing.requested"
            assert event["deviceName"] == "iPhone"
    finally:
        await server.stop()


async def test_commands_still_work_alongside_a_subscription(socket_dir):
    """A subscription must not monopolise the socket — the UI issues commands too."""
    bus = EventBus()

    async def handler(request):
        return {"ok": True, "echo": request.get("command")}

    server = ControlServer(handler, socket_dir / "c.sock", bus=bus)
    await server.start()
    try:
        async with subscribe(socket_dir / "c.sock"):
            reply = await send_command({"command": "status"}, socket_dir / "c.sock")
            assert reply == {"ok": True, "echo": "status"}
    finally:
        await server.stop()


async def test_subscriber_is_released_when_the_client_disconnects(socket_dir):
    """A detached UI must not leak a queue that the daemon keeps filling forever."""
    bus = EventBus()
    server = ControlServer(lambda _r: asyncio.sleep(0, {"ok": True}), socket_dir / "c.sock", bus=bus)
    await server.start()
    try:
        async with subscribe(socket_dir / "c.sock"):
            await asyncio.sleep(0.05)
            assert bus.subscriber_count == 1

        for _ in range(40):
            await asyncio.sleep(0.05)
            if bus.subscriber_count == 0:
                break
        assert bus.subscriber_count == 0
    finally:
        await server.stop()


async def test_subscribe_is_refused_when_the_daemon_publishes_nothing(socket_dir):
    from bigbro.control import ControlClientError

    server = ControlServer(lambda _r: asyncio.sleep(0, {"ok": True}), socket_dir / "c.sock")
    await server.start()
    try:
        with pytest.raises(ControlClientError, match="no events"):
            async with subscribe(socket_dir / "c.sock"):
                pass
    finally:
        await server.stop()


# MARK: - Settings


def test_settings_round_trip(tmp_path):
    store = JSONStore(tmp_path / "config.json")
    settings = Settings(port=9100, keep_awake=False, log_level="DEBUG")
    settings.save(store)

    reloaded = Settings.load(JSONStore(tmp_path / "config.json"))
    assert reloaded.to_wire() == {"port": 9100, "keep_awake": False, "log_level": "DEBUG"}


@pytest.mark.parametrize("key,value,ok", [
    ("port", 9000, True),
    ("port", "9000", True),
    ("port", 80, False),          # privileged
    ("port", 70000, False),       # out of range
    ("port", "abc", False),
    ("log_level", "debug", True),
    ("log_level", "chatty", False),
    ("keep_awake", False, True),
    ("nonsense", 1, False),
])
def test_settings_apply_validates(key, value, ok):
    changed, _message = Settings().apply(key, value)
    assert changed is ok


def test_settings_rejects_rather_than_clamping():
    """A port silently clamped is a daemon listening somewhere nobody asked for."""
    settings = Settings()
    changed, message = settings.apply("port", 80)
    assert not changed
    assert settings.port == 8765
    assert "between 1024 and 65535" in message


def test_unchanged_value_is_not_a_change():
    changed, message = Settings().apply("port", 8765)
    assert not changed and message == "unchanged"


def test_corrupt_config_falls_back_to_defaults(tmp_path):
    path = tmp_path / "config.json"
    path.write_text("{not json")
    assert Settings.load(JSONStore(path)).to_wire() == Settings().to_wire()


def test_out_of_range_values_in_the_file_fall_back(tmp_path):
    """A hand-edited config must not put the daemon somewhere unreachable."""
    store = JSONStore(tmp_path / "config.json")
    store.update({"port": 42, "log_level": "LOUD"})
    loaded = Settings.load(store)
    assert loaded.port == 8765
    assert loaded.log_level == "INFO"
