"""Control-command tests — the backend for every CLI verb except `serve`.

The Daemon object is constructed without ever starting the listener, Bonjour or the
power assertion, so these run anywhere. `BIGBRO_HOME` keeps them off the real
support directory.
"""

from __future__ import annotations

import pytest

from bigbro.daemon import Daemon


@pytest.fixture
def daemon(tmp_path, monkeypatch):
    monkeypatch.setenv("BIGBRO_HOME", str(tmp_path))
    return Daemon(port=8765)


async def test_unknown_command_is_rejected(daemon):
    reply = await daemon.handle_control({"command": "nope"})
    assert reply["ok"] is False
    assert "unknown command" in reply["error"]


async def test_status_reports_the_daemon_shape(daemon):
    reply = await daemon.handle_control({"command": "status"})
    assert reply["ok"] is True
    assert reply["port"] == 8765
    assert reply["paired"] == 0
    assert reply["connected"] == []
    assert set(reply["speech"]) == {"tts", "stt"}


async def test_models_list_is_grouped_by_family(daemon):
    """Grouped because they are not interchangeable — naming the wrong kind fails."""
    from bigbro.inference.catalog import EVERY_MODEL, Family

    reply = await daemon.handle_control({"command": "models.list"})
    assert reply["ok"] is True

    groups = {g["family"]: g for g in reply["groups"]}
    assert list(groups) == [f.value for f in Family]
    assert [g["label"] for g in reply["groups"]] == ["Text", "Vision", "TTS", "STT"]

    listed = [m for g in reply["groups"] for m in g["models"]]
    assert len(listed) == len(EVERY_MODEL)

    entry = next(m for m in groups["language"]["models"] if m["id"] == "gpt-oss-20b")
    assert entry["tools"] is True
    assert entry["reasoning"] == "harmony"
    assert entry["state"] == "not downloaded"


async def test_speech_models_are_listed_by_name_under_their_role(daemon):
    """"tts" names a job; "kokoro" names something a person can look up."""
    reply = await daemon.handle_control({"command": "models.list"})
    groups = {g["family"]: g for g in reply["groups"]}

    assert [m["id"] for m in groups["tts"]["models"]] == ["kokoro"]
    assert groups["tts"]["models"][0]["name"] == "Kokoro 82M"
    assert [m["id"] for m in groups["stt"]["models"]] == ["parakeet"]


@pytest.mark.parametrize("name", ["tts", "kokoro", "stt", "parakeet"])
async def test_speech_commands_accept_role_and_model_name(daemon, name):
    """The wire sends roles; the panes show model names. Both must work."""
    reply = await daemon.handle_control({"command": "models.stop", "model": name})
    assert reply["ok"] is True, reply


async def test_speech_as_a_whole_addresses_both_roles(daemon):
    reply = await daemon.handle_control({"command": "models.stop", "model": "speech"})
    assert reply["ok"] is True
    assert reply["model"] == "kokoro, parakeet"


async def test_a_speech_model_cannot_be_named_for_inference(daemon):
    """Asking Kokoro to answer a chat message is a category error, not a fallback."""
    from bigbro.inference import catalog

    assert catalog.resolve("kokoro") is None
    assert catalog.resolve("parakeet") is None


async def test_models_commands_reject_an_unknown_model(daemon):
    for action in ("models.download", "models.start", "models.stop", "models.delete"):
        reply = await daemon.handle_control({"command": action, "model": "gpt-4"})
        assert reply["ok"] is False, action
        assert "not a model BigBro knows about" in reply["error"]


async def test_models_stop_accepts_an_ollama_style_tag(daemon):
    """Older clients and muscle memory both write `gpt-oss:20b`."""
    reply = await daemon.handle_control({"command": "models.stop", "model": "gpt-oss:20b"})
    assert reply["ok"] is True
    assert reply["model"] == "gpt-oss-20b"


async def test_models_stop_is_idempotent(daemon):
    """"Stop what isn't started" is the state the caller wanted, not an error."""
    first = await daemon.handle_control({"command": "models.stop", "model": "qwen3-4b"})
    second = await daemon.handle_control({"command": "models.stop", "model": "qwen3-4b"})
    assert first["ok"] and second["ok"]


async def test_pair_list_is_empty_on_a_fresh_install(daemon):
    reply = await daemon.handle_control({"command": "pair.list"})
    assert reply == {"ok": True, "pending": [], "devices": []}


async def test_pair_approve_with_nothing_pending(daemon):
    reply = await daemon.handle_control({"command": "pair.approve", "deviceId": "nobody"})
    assert reply["ok"] is False
    assert "no pending request" in reply["error"]


async def test_pair_approve_with_no_device_id(daemon):
    reply = await daemon.handle_control({"command": "pair.approve", "deviceId": ""})
    assert reply["ok"] is False


async def test_pair_remove_reports_an_unmatched_prefix(daemon):
    reply = await daemon.handle_control({"command": "pair.remove", "deviceId": "ghost"})
    assert reply["ok"] is False
    assert "no paired device" in reply["error"]


async def test_pair_list_then_remove(daemon):
    daemon.pairing.approve("device-abc123", "iPhone", "TestApp", ["qwen3-4b"])

    listed = await daemon.handle_control({"command": "pair.list"})
    assert len(listed["devices"]) == 1
    assert listed["devices"][0]["name"] == "iPhone"
    assert listed["devices"][0]["connected"] is False

    removed = await daemon.handle_control({"command": "pair.remove", "deviceId": "device-abc"})
    assert removed["ok"] is True
    assert removed["deviceId"] == "device-abc123"

    after = await daemon.handle_control({"command": "pair.list"})
    assert after["devices"] == []


async def test_pair_remove_all(daemon):
    daemon.pairing.approve("a", "A", "App", [])
    daemon.pairing.approve("b", "B", "App", [])
    reply = await daemon.handle_control({"command": "pair.remove-all"})
    assert reply == {"ok": True, "removed": 2}


async def test_devices_persist_across_daemon_instances(tmp_path, monkeypatch):
    monkeypatch.setenv("BIGBRO_HOME", str(tmp_path))
    first = Daemon()
    first.pairing.approve("device-1", "iPhone", "TestApp", [])

    second = Daemon()
    reply = await second.handle_control({"command": "pair.list"})
    assert [d["deviceId"] for d in reply["devices"]] == ["device-1"]


# MARK: - The four model verbs


@pytest.mark.parametrize("command", [
    "models.download", "models.delete", "models.start", "models.stop",
])
async def test_each_model_verb_is_handled(daemon, command):
    """download/delete are about disk, start/stop are about memory."""
    reply = await daemon.handle_control({"command": command, "model": "qwen3-4b"})
    assert reply["ok"] is True, command
    assert reply["model"] == "qwen3-4b"


@pytest.mark.parametrize("old,new", [("models.run", "models.start"), ("models.remove", "models.delete")])
async def test_the_pre_rename_control_names_still_resolve(daemon, old, new):
    """So a CLI and daemon from either side of the rename still understand each other."""
    assert (await daemon.handle_control({"command": old, "model": "qwen3-4b"}))["ok"] is True


async def test_the_verbs_accept_speech_models(daemon):
    """`tts` and `stt` are addressable by the same verbs as a catalog model.

    Only the local ones are exercised here — `start` would really fetch and load
    Kokoro, which is not something a test run should do.
    """
    for command in ("models.stop", "models.delete"):
        reply = await daemon.handle_control({"command": command, "model": "tts"})
        assert reply["ok"] is True, command


# MARK: - Shutdown


async def test_shutdown_acknowledges_before_it_stops(daemon):
    """The reply has to win the race against the socket it is sent on.

    `stop()` sets the event `run()` waits on, and shutdown closes the control
    socket. Firing it inline would tear the connection down before the caller
    heard anything, which reads as a crash rather than a clean stop.
    """
    import asyncio

    loop = asyncio.get_running_loop()
    scheduled: list[float] = []
    real_call_later = loop.call_later

    def record(delay, callback, *args):
        scheduled.append(delay)
        return real_call_later(delay, callback, *args)

    loop.call_later = record  # type: ignore[method-assign]
    try:
        reply = await daemon.handle_control({"command": "daemon.shutdown"})
    finally:
        loop.call_later = real_call_later  # type: ignore[method-assign]

    assert reply["ok"] is True
    assert reply["stopping"] is True
    # Deferred, not immediate.
    assert scheduled and scheduled[0] > 0


async def test_shutdown_actually_sets_the_stop_event(daemon):
    import asyncio

    await daemon.handle_control({"command": "daemon.shutdown"})
    await asyncio.sleep(0.2)
    assert daemon._stopping.is_set()


async def test_every_route_that_moves_a_model_reaches_attached_uis(daemon):
    """Three things load models — a control command, a peer's `run`, and the lazy
    load a plain inference request triggers — and all three have to announce it."""
    assert daemon.router.on_model_change == daemon._publish_model_state
    assert daemon.engine.on_state_change == daemon._publish_model_state

    queue = daemon.events.subscribe()
    daemon.engine.on_state_change("qwen3-4b")

    import asyncio

    event = await asyncio.wait_for(queue.get(), 1)
    assert event["event"] == "model.state"
    assert event["model"] == "qwen3-4b"
