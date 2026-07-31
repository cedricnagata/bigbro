"""Daemon startup and shutdown, actually running `run()`.

This file exists because of a bug that reached the user: `self._stopping` was
left stranded after a `return`, so `run()` raised AttributeError the instant it
finished starting. Every other test built a Daemon and drove its pieces directly
— the one path nobody exercised was the one every real invocation takes.

Bonjour and the power assertion are patched out: publishing a service on the LAN
and pinning the Mac awake are not side effects a test run should have.
"""

from __future__ import annotations

import asyncio
import shutil
import tempfile
from pathlib import Path

import pytest

from bigbro.daemon import Daemon


@pytest.fixture
def quiet_daemon(tmp_path, monkeypatch, unused_tcp_port):
    """A Daemon whose global side effects are stubbed, ready to `run()`."""
    monkeypatch.setenv("BIGBRO_HOME", str(tmp_path))

    socket_dir = Path(tempfile.mkdtemp(dir="/tmp"))
    monkeypatch.setattr(
        "bigbro.control.control_socket_path", lambda: socket_dir / "c.sock"
    )

    from bigbro.macos.bonjour import BonjourAdvertiser
    from bigbro.macos.power import PowerAssertion

    monkeypatch.setattr(BonjourAdvertiser, "start", lambda self, port, name=None: None)
    monkeypatch.setattr(BonjourAdvertiser, "stop", lambda self: None)

    acquired: list[str] = []
    monkeypatch.setattr(PowerAssertion, "acquire", lambda self, reason: acquired.append(reason))
    monkeypatch.setattr(PowerAssertion, "release", lambda self: acquired.clear())

    daemon = Daemon(port=unused_tcp_port)
    daemon.acquired = acquired
    daemon.socket_dir = socket_dir
    try:
        yield daemon
    finally:
        shutil.rmtree(socket_dir, ignore_errors=True)


async def _run_briefly(daemon, hold=0.2):
    """Starts the daemon, waits for it to be up, stops it, and returns cleanly.

    Any exception `run()` raises propagates here rather than vanishing into a
    detached task — which is exactly how the original bug stayed invisible.
    """
    task = asyncio.create_task(daemon.run())
    await asyncio.sleep(hold)
    if task.done():
        await task  # re-raise whatever killed it
    daemon.stop()
    await asyncio.wait_for(task, timeout=10)


async def test_run_starts_and_stops_cleanly(quiet_daemon):
    """The whole point: `run()` must survive being run."""
    await _run_briefly(quiet_daemon)


async def test_run_creates_the_control_socket(quiet_daemon):
    task = asyncio.create_task(quiet_daemon.run())
    try:
        for _ in range(40):
            await asyncio.sleep(0.05)
            if task.done():
                await task
            if (quiet_daemon.socket_dir / "c.sock").exists():
                break
        assert (quiet_daemon.socket_dir / "c.sock").exists()
    finally:
        quiet_daemon.stop()
        await asyncio.wait_for(task, timeout=10)


async def test_run_accepts_a_peer_connection(quiet_daemon):
    task = asyncio.create_task(quiet_daemon.run())
    try:
        await asyncio.sleep(0.2)
        if task.done():
            await task
        reader, writer = await asyncio.open_connection("127.0.0.1", quiet_daemon.port)
        writer.close()
    finally:
        quiet_daemon.stop()
        await asyncio.wait_for(task, timeout=10)


async def test_keep_awake_is_held_for_the_whole_run_then_released(quiet_daemon):
    task = asyncio.create_task(quiet_daemon.run())
    try:
        await asyncio.sleep(0.2)
        if task.done():
            await task
        assert quiet_daemon.acquired, "the assertion should be held while serving"
    finally:
        quiet_daemon.stop()
        await asyncio.wait_for(task, timeout=10)
    assert not quiet_daemon.acquired, "and released once it stops"


async def test_no_keep_awake_never_takes_the_assertion(tmp_path, monkeypatch, unused_tcp_port):
    monkeypatch.setenv("BIGBRO_HOME", str(tmp_path))
    socket_dir = Path(tempfile.mkdtemp(dir="/tmp"))
    monkeypatch.setattr("bigbro.control.control_socket_path", lambda: socket_dir / "c.sock")

    from bigbro.macos.bonjour import BonjourAdvertiser
    from bigbro.macos.power import PowerAssertion

    monkeypatch.setattr(BonjourAdvertiser, "start", lambda self, port, name=None: None)
    monkeypatch.setattr(BonjourAdvertiser, "stop", lambda self: None)

    acquired: list[str] = []
    monkeypatch.setattr(PowerAssertion, "acquire", lambda self, reason: acquired.append(reason))
    monkeypatch.setattr(PowerAssertion, "release", lambda self: None)

    daemon = Daemon(port=unused_tcp_port, keep_awake=False)
    try:
        await _run_briefly(daemon)
        assert acquired == []
    finally:
        shutil.rmtree(socket_dir, ignore_errors=True)


# MARK: - Flags vs the config file


def test_a_flag_beats_the_config_file(tmp_path, monkeypatch):
    """A flag is what someone typed for this run; the file is what they left set."""
    monkeypatch.setenv("BIGBRO_HOME", str(tmp_path))
    from bigbro.config import JSONStore, Settings

    Settings(port=9100, keep_awake=False).save(JSONStore(tmp_path / "config.json"))

    assert Daemon().port == 9100                      # no flag: the file wins
    assert Daemon(port=8765).port == 8765             # flag given: it wins
    assert Daemon().keep_awake is False
    assert Daemon(keep_awake=True).keep_awake is True


def test_defaults_apply_with_no_config_file(tmp_path, monkeypatch):
    monkeypatch.setenv("BIGBRO_HOME", str(tmp_path))
    daemon = Daemon()
    assert daemon.port == 8765
    assert daemon.keep_awake is True
