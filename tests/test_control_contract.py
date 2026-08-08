"""The control-socket reply shapes a non-Python client decodes.

Every other client of this daemon has been Python, so a renamed field was caught
by the caller crashing. A Swift client decodes these replies into structs, and a
field that quietly changes name does not crash it — it leaves a pane empty, which
is the kind of bug that ships.

So the keys are pinned here, explicitly and by hand. The lists below are a
contract: changing one is allowed, but it has to be a decision, and the Swift
decoder has to change with it.

The committed fixtures under `app/Tests/Fixtures/` are the same replies captured
as JSON, so the Swift tests decode real daemon output rather than something
hand-written from a second reading of this file. `test_the_fixtures_still_match`
keeps them from rotting; regenerate with:

    uv run python tests/test_control_contract.py
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from bigbro.daemon import Daemon

FIXTURES = Path(__file__).resolve().parent.parent / "app" / "Tests" / "Fixtures"

STATUS_KEYS = {
    "ok", "name", "port", "keepAwake", "paired", "connected",
    "pending", "running", "downloaded", "speech", "memory",
}
#: `to_wire` emits all nine unconditionally, so this is stable across platforms
#: even though every value is `None` wherever the mach calls do not resolve.
MEMORY_KEYS = {
    "resident", "peak", "footprint", "total", "pressure", "mlx", "models",
    "headline", "weights",
}
SPEECH_KEYS = {"name", "model", "state"}
MODEL_ENTRY_KEYS = {
    "id", "name", "family", "state", "sizeGB", "tools", "images", "reasoning", "memory",
}
GROUP_KEYS = {"family", "label", "models"}
DEVICE_KEYS = {"deviceId", "name", "appName", "connected", "requiredModels"}
PENDING_KEYS = {"deviceId", "deviceName", "appName", "requiredModels", "waitingSeconds"}
SETTINGS_KEYS = {"port", "keep_awake", "log_level"}


@pytest.fixture
def daemon(tmp_path, monkeypatch):
    monkeypatch.setenv("BIGBRO_HOME", str(tmp_path))
    return Daemon(port=8765)


async def test_status_carries_every_key_the_client_decodes(daemon):
    reply = await daemon.handle_control({"command": "status"})
    assert set(reply) == STATUS_KEYS
    assert set(reply["memory"]) == MEMORY_KEYS
    for role, info in reply["speech"].items():
        assert set(info) == SPEECH_KEYS, role


async def test_status_keeps_its_one_camel_cased_key(daemon):
    """`status` says `keepAwake`; `settings.get` says `keep_awake`. Both, on purpose.

    A single global key-decoding strategy on the client cannot serve both, so this
    pins the split rather than leaving someone to discover it in a silent `false`.
    """
    status = await daemon.handle_control({"command": "status"})
    settings = await daemon.handle_control({"command": "settings.get"})

    assert "keepAwake" in status and "keep_awake" not in status
    assert "keep_awake" in settings["settings"] and "keepAwake" not in settings["settings"]


async def test_models_list_entries_carry_every_key(daemon):
    reply = await daemon.handle_control({"command": "models.list"})
    assert set(reply) == {"ok", "groups"}
    assert reply["groups"], "the catalog is never empty"

    for group in reply["groups"]:
        assert set(group) == GROUP_KEYS, group.get("family")
        for entry in group["models"]:
            assert set(entry) == MODEL_ENTRY_KEYS, entry.get("id")


async def test_a_speech_entry_reports_no_memory_rather_than_zero(daemon):
    """`memory` is null for speech models, so the client's field must be optional."""
    reply = await daemon.handle_control({"command": "models.list"})
    speech = [
        entry
        for group in reply["groups"] if group["family"] in ("tts", "stt")
        for entry in group["models"]
    ]
    assert speech, "the catalog ships a TTS and an STT model"
    assert all(entry["memory"] is None for entry in speech)


async def test_settings_get_reports_what_may_be_written(daemon):
    reply = await daemon.handle_control({"command": "settings.get"})
    assert set(reply) == {"ok", "settings", "editable"}
    assert set(reply["settings"]) == SETTINGS_KEYS
    assert set(reply["editable"]) == SETTINGS_KEYS


async def test_pair_list_shapes(daemon):
    reply = await daemon.handle_control({"command": "pair.list"})
    assert set(reply) == {"ok", "pending", "devices"}


async def test_a_failed_command_still_answers_the_envelope(daemon):
    """Clients read `ok` before anything else, so a failure must carry it too."""
    reply = await daemon.handle_control({"command": "models.start", "model": "nope"})
    assert reply["ok"] is False
    assert isinstance(reply["error"], str) and reply["error"]


# MARK: - Fixtures shared with the Swift tests


async def _payloads(daemon) -> dict[str, dict]:
    """The replies worth freezing, with the machine-specific bits scrubbed."""
    status = await daemon.handle_control({"command": "status"})
    # The computer name is whatever ran this, and every memory figure depends on
    # the host and what is loaded. Neither is what the fixtures are for.
    status["name"] = "Test Mac"
    status["memory"] = dict.fromkeys(MEMORY_KEYS - {"mlx", "models"})
    status["memory"]["mlx"] = {}
    status["memory"]["models"] = {}

    return {
        "status": status,
        "models_list": await daemon.handle_control({"command": "models.list"}),
        "settings_get": await daemon.handle_control({"command": "settings.get"}),
        "pair_list": await daemon.handle_control({"command": "pair.list"}),
    }


def _keys_only(value):
    """Key structure with every leaf erased, so values may drift and names may not."""
    if isinstance(value, dict):
        return {key: _keys_only(inner) for key, inner in sorted(value.items())}
    if isinstance(value, list):
        return [_keys_only(value[0])] if value else []
    return None


@pytest.mark.parametrize("name", ["status", "models_list", "settings_get", "pair_list"])
async def test_the_fixtures_still_match_the_daemon(daemon, name):
    """A rename would leave the Swift decoder reading a fixture nobody sends."""
    path = FIXTURES / f"{name}.json"
    assert path.exists(), f"missing fixture {path}; regenerate with tests/test_control_contract.py"

    live = (await _payloads(daemon))[name]
    assert _keys_only(json.loads(path.read_text())) == _keys_only(live)


if __name__ == "__main__":
    import asyncio
    import os
    import tempfile

    async def regenerate() -> None:
        with tempfile.TemporaryDirectory() as home:
            os.environ["BIGBRO_HOME"] = home
            FIXTURES.mkdir(parents=True, exist_ok=True)
            for name, payload in (await _payloads(Daemon(port=8765))).items():
                path = FIXTURES / f"{name}.json"
                path.write_text(json.dumps(payload, indent=2) + "\n")
                print(f"wrote {path}")

    asyncio.run(regenerate())
