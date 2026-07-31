"""Pairing tests — the behaviour that changed most in the terminal pivot.

The menu-bar app blocked on a modal. A daemon parks the request instead, which
introduces two things the modal never had: a queue someone has to read, and a timeout
so an ignored request cannot hold a socket open forever.
"""

from __future__ import annotations

import asyncio

import pytest

from bigbro.config import JSONStore
from bigbro.protocol import pairing as pairing_module
from bigbro.protocol.pairing import PairingManager


@pytest.fixture
def manager(tmp_path):
    return PairingManager(JSONStore(tmp_path / "devices.json"))


async def _hello(manager, device_id="device-1", name="iPhone", app="TestApp", models=None):
    return await manager.await_decision(device_id, name, app, models or [], "conn-1")


# MARK: - Approval flow


async def test_unknown_device_parks_until_approved(manager):
    task = asyncio.create_task(_hello(manager))
    await asyncio.sleep(0)  # let it park

    assert len(manager.pending_requests) == 1
    assert manager.pending_requests[0].device_name == "iPhone"

    manager.resolve_pending("device-1", approved=True)
    assert await task is True


async def test_denial_resolves_to_false(manager):
    task = asyncio.create_task(_hello(manager))
    await asyncio.sleep(0)
    manager.resolve_pending("device-1", approved=False)
    assert await task is False


async def test_pending_request_times_out_and_denies(manager, monkeypatch):
    """An ignored request must not hold a live socket forever."""
    monkeypatch.setattr(pairing_module, "PENDING_TIMEOUT_SECONDS", 0.05)
    assert await _hello(manager) is False
    assert manager.pending_requests == []


async def test_resolved_request_is_removed_from_the_queue(manager):
    task = asyncio.create_task(_hello(manager))
    await asyncio.sleep(0)
    manager.resolve_pending("device-1", approved=True)
    await task
    assert manager.pending_requests == []


async def test_approval_by_unambiguous_prefix(manager):
    task = asyncio.create_task(_hello(manager, device_id="abcdef123456"))
    await asyncio.sleep(0)
    assert manager.resolve_pending("abcdef", approved=True) is not None
    assert await task is True


async def test_ambiguous_prefix_matches_nothing(manager):
    """Approving the wrong device is not a mistake worth guessing into."""
    first = asyncio.create_task(_hello(manager, device_id="abc111"))
    second = asyncio.create_task(_hello(manager, device_id="abc222"))
    await asyncio.sleep(0)

    assert manager.resolve_pending("abc", approved=True) is None

    manager.resolve_pending("abc111", approved=True)
    manager.resolve_pending("abc222", approved=False)
    assert await first is True
    assert await second is False


async def test_repeated_hello_replaces_rather_than_queues(manager):
    """A client retrying its handshake is one device asking one question."""
    first = asyncio.create_task(_hello(manager))
    await asyncio.sleep(0)
    second = asyncio.create_task(_hello(manager))
    await asyncio.sleep(0)

    assert len(manager.pending_requests) == 1
    assert await first is False  # superseded

    manager.resolve_pending("device-1", approved=True)
    assert await second is True


# MARK: - Persistence


def test_approved_devices_survive_a_restart(tmp_path):
    path = tmp_path / "devices.json"
    first = PairingManager(JSONStore(path))
    first.approve("device-1", "iPhone", "TestApp", ["qwen3-4b"])

    second = PairingManager(JSONStore(path))
    assert second.is_approved("device-1")
    assert second.display_name("device-1") == "iPhone • TestApp"


def test_note_seen_updates_names_without_reapproving(tmp_path):
    manager = PairingManager(JSONStore(tmp_path / "devices.json"))
    manager.approve("device-1", "iPhone", "TestApp", [])
    manager.note_seen("device-1", "Renamed iPhone", "TestApp", [])
    assert manager.display_name("device-1") == "Renamed iPhone • TestApp"
    assert manager.is_approved("device-1")


def test_remove_forgets_a_device(tmp_path):
    manager = PairingManager(JSONStore(tmp_path / "devices.json"))
    manager.approve("device-1", "iPhone", "TestApp", [])
    assert manager.remove("device-1") is True
    assert manager.is_approved("device-1") is False
    assert manager.remove("device-1") is False  # already gone


def test_remove_all(tmp_path):
    manager = PairingManager(JSONStore(tmp_path / "devices.json"))
    manager.approve("a", "A", "App", [])
    manager.approve("b", "B", "App", [])
    assert manager.remove_all() == 2
    assert manager.approved_device_ids == []


def test_resolve_device_id_by_prefix(tmp_path):
    manager = PairingManager(JSONStore(tmp_path / "devices.json"))
    manager.approve("abcdef123", "A", "App", [])
    manager.approve("zzz999", "B", "App", [])
    assert manager.resolve_device_id("abcdef") == "abcdef123"
    assert manager.resolve_device_id("nope") is None


def test_corrupt_device_file_starts_empty_rather_than_crashing(tmp_path):
    """A torn write must not lock every paired device out permanently."""
    path = tmp_path / "devices.json"
    path.write_text("{not valid json")
    manager = PairingManager(JSONStore(path))
    assert manager.approved_device_ids == []


# MARK: - Missing models


def test_missing_models_filters_through_the_satisfaction_check(tmp_path):
    manager = PairingManager(JSONStore(tmp_path / "devices.json"))
    manager.is_model_satisfied = lambda name: name == "qwen3-4b"
    assert manager.missing_models(["qwen3-4b", "gpt-oss-20b"]) == ["gpt-oss-20b"]


def test_connection_state_tracking(tmp_path):
    manager = PairingManager(JSONStore(tmp_path / "devices.json"))
    manager.approve("device-1", "iPhone", "App", ["qwen3-4b"])
    manager.mark_connected("device-1")
    assert manager.connected_device_ids == {"device-1"}

    manager.mark_disconnected("device-1")
    assert manager.connected_device_ids == set()
    # Required models are per-session — a disconnected device declares them again.
    assert manager.required_models("device-1") == []
