"""Unit tests for the remaining platform-independent pieces.

The ctypes bindings in `bigbro.macos` cannot run here, but the pure functions beside
them — TXT record encoding, PCM conversion, WAV parsing, template context — can, and
they are where the format bugs live.
"""

from __future__ import annotations

import asyncio
import struct
from pathlib import Path

import numpy as np
import pytest

from bigbro.control import ControlClientError, ControlServer, send_command
from bigbro.inference.catalog import model as catalog_model
from bigbro.inference.downloader import hub_repository_root
from bigbro.inference.engine import generation_kwargs, template_context
from bigbro.macos.bonjour import encode_txt_record
from bigbro.router import explicit_reasoning_effort, resolve_reasoning_effort
from bigbro.speech import SpeechError, float_samples, kinds_for, pcm16


# MARK: - Bonjour TXT records


def test_txt_record_is_length_prefixed():
    assert encode_txt_record({"version": "1.0"}) == b"\x0bversion=1.0"


def test_txt_record_with_several_keys():
    encoded = encode_txt_record({"version": "1.0", "port": "8765"})
    assert encoded == b"\x0bversion=1.0" + b"\x09port=8765"
    # Each entry's declared length must match what follows it.
    assert encoded[0] == len(b"version=1.0")
    assert encoded[12] == len(b"port=8765")


def test_txt_record_rejects_an_oversized_entry():
    """A length byte cannot express more than 255, so this must fail loudly."""
    with pytest.raises(ValueError, match="max 255"):
        encode_txt_record({"k": "x" * 300})


# MARK: - Audio conversion


def test_pcm16_round_trip():
    samples = np.array([0.0, 0.5, -0.5], dtype=np.float32)
    raw = pcm16(samples)
    assert len(raw) == 6  # 3 samples, 2 bytes each
    recovered = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32767.0
    assert np.allclose(recovered, samples, atol=1e-4)


def test_pcm16_clips_rather_than_wrapping():
    """Kokoro occasionally overshoots; wrapping would turn a peak into a loud click."""
    raw = np.frombuffer(pcm16(np.array([2.0, -2.0], dtype=np.float32)), dtype="<i2")
    assert raw[0] == 32767
    assert raw[1] == -32767


def test_pcm16_is_little_endian():
    raw = pcm16(np.array([1.0], dtype=np.float32))
    assert raw == b"\xff\x7f"


def _wav(samples: np.ndarray, channels: int = 1, rate: int = 16000) -> bytes:
    pcm = (samples * 32767).astype("<i2").tobytes()
    return (
        b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVE"
        + b"fmt " + struct.pack("<IHHIIHH", 16, 1, channels, rate, rate * channels * 2, channels * 2, 16)
        + b"data" + struct.pack("<I", len(pcm)) + pcm
    )


def test_wav_decoding():
    original = np.array([0.0, 0.25, -0.25], dtype=np.float32)
    decoded = float_samples(_wav(original), "wav")
    assert np.allclose(decoded, original, atol=1e-3)


def test_wav_with_an_extra_chunk_before_data():
    """iOS recordings often carry a LIST chunk — a fixed 44-byte header misreads them."""
    base = _wav(np.array([0.5, -0.5], dtype=np.float32))
    head, tail = base[:36], base[36:]
    extra = b"LIST" + struct.pack("<I", 4) + b"INFO"
    payload = head + extra + tail
    payload = b"RIFF" + struct.pack("<I", len(payload) - 8) + payload[8:]
    decoded = float_samples(payload, "wav")
    assert np.allclose(decoded, [0.5, -0.5], atol=1e-3)


def test_stereo_wav_is_downmixed_to_mono():
    interleaved = np.array([1.0, 0.0, 1.0, 0.0], dtype=np.float32)  # L,R,L,R
    decoded = float_samples(_wav(interleaved, channels=2), "wav")
    assert len(decoded) == 2
    assert np.allclose(decoded, [0.5, 0.5], atol=1e-3)


def test_headerless_pcm_decoding():
    raw = np.array([1000, -1000], dtype="<i2").tobytes()
    decoded = float_samples(raw, "pcm")
    assert np.allclose(decoded, [1000 / 32768, -1000 / 32768], atol=1e-5)


@pytest.mark.parametrize("payload,fmt", [
    (b"not a wav at all", "wav"),
    (b"RIFF" + b"\x00" * 40, "wav"),
    (b"whatever", "mp3"),
])
def test_undecodable_audio_is_refused_rather_than_guessed(payload, fmt):
    """Misreading a container yields noise that transcribes to plausible nonsense."""
    with pytest.raises(SpeechError):
        float_samples(payload, fmt)


@pytest.mark.parametrize("requested,count", [("tts", 1), ("stt", 1), ("speech", 2)])
def test_speech_kinds_for(requested, count):
    assert len(kinds_for(requested)) == count


def test_speech_kinds_for_a_language_model_is_none():
    assert kinds_for("qwen3-4b") is None


# MARK: - Template context


def test_harmony_gets_reasoning_effort_as_a_string():
    context = template_context(catalog_model("gpt-oss-20b"), "high", True)
    assert context == {"reasoning_effort": "high"}


def test_harmony_without_an_effort_leaves_the_template_default():
    assert template_context(catalog_model("gpt-oss-20b"), None, True) == {}


def test_qwen3_gets_enable_thinking_as_a_bool_not_a_string():
    """Jinja treats any non-empty string as truthy — "false" would enable thinking."""
    context = template_context(catalog_model("qwen3-8b"), None, False)
    assert context == {"enable_thinking": False}
    assert isinstance(context["enable_thinking"], bool)


def test_qwen3_low_effort_maps_onto_the_only_lever_it_has():
    assert template_context(catalog_model("qwen3-8b"), "low", True) == {"enable_thinking": False}
    assert template_context(catalog_model("qwen3-8b"), "high", True) == {"enable_thinking": True}


def test_non_togglable_think_model_gets_no_context():
    """The R1 distills have no `enable_thinking` in their template."""
    assert template_context(catalog_model("deepseek-r1-7b"), None, False) == {}


def test_plain_models_never_receive_reasoning_keys():
    """An unknown Jinja variable is ignored — it would look like it worked."""
    assert template_context(catalog_model("llama-3.2-1b"), "high", True) == {}


# MARK: - Reasoning effort resolution


@pytest.mark.parametrize("message,send_reasoning,expected", [
    ({"reasoning_effort": "high"}, True, "high"),
    ({"reasoning_effort": "HIGH"}, True, "high"),
    ({"reasoning_effort": "bogus"}, True, None),   # junk is dropped, not forwarded
    ({}, True, None),
    ({}, False, "low"),                            # think:false reads as "want speed"
    ({"reasoning_effort": "high"}, False, "high"), # explicit always wins
])
def test_resolve_reasoning_effort(message, send_reasoning, expected):
    assert resolve_reasoning_effort(message, send_reasoning) == expected


@pytest.mark.parametrize("message,expected", [
    ({"reasoning_effort": "high"}, "high"),
    ({"reasoning_effort": "bogus"}, None),
    ({}, None),
])
def test_explicit_reasoning_effort_ignores_what_bigbro_inferred(message, expected):
    assert explicit_reasoning_effort(message) == expected


# MARK: - Generation options


def test_generation_kwargs_forwards_what_maps():
    result = generation_kwargs({"num_predict": 128, "temperature": 0.7, "top_p": 0.9, "seed": 42})
    assert result["max_tokens"] == 128
    assert result["_sampler_args"] == {"temp": 0.7, "top_p": 0.9}
    assert result["_seed"] == 42


def test_generation_kwargs_drops_what_has_no_equivalent():
    result = generation_kwargs({"num_ctx": 4096, "num_thread": 8, "stop": ["\n"]})
    assert result == {}


def test_generation_kwargs_with_no_options():
    assert generation_kwargs(None) == {}


# MARK: - Hub cache layout


def test_hub_repository_root_identifies_a_snapshot(tmp_path):
    """Deleting only the snapshot removes symlinks and leaves every blob behind."""
    snapshot = tmp_path / "models--mlx-community--Qwen3-4B-4bit" / "snapshots" / "abc123"
    assert hub_repository_root(snapshot) == snapshot.parent.parent


@pytest.mark.parametrize("path", [
    "some/other/directory",
    "models--org--name/blobs/abc",
    "notmodels--org--name/snapshots/abc",
])
def test_hub_repository_root_refuses_to_guess(path, tmp_path):
    """A path this cannot positively identify is not one to delete the parents of."""
    assert hub_repository_root(Path(path)) is None


# MARK: - Control socket


@pytest.fixture
def socket_dir():
    """A short-pathed temp directory for Unix sockets.

    pytest's `tmp_path` lives under `/private/var/folders/...` on macOS, which
    overruns the 104-byte `sun_path` limit before a socket name is even appended.
    """
    import shutil
    import tempfile

    directory = Path(tempfile.mkdtemp(dir="/tmp"))
    try:
        yield directory
    finally:
        shutil.rmtree(directory, ignore_errors=True)


async def test_control_socket_round_trip(socket_dir):
    async def handler(request):
        return {"ok": True, "echo": request.get("command")}

    server = ControlServer(handler, socket_dir / "control.sock")
    await server.start()
    try:
        reply = await send_command({"command": "status"}, socket_dir / "control.sock")
        assert reply == {"ok": True, "echo": "status"}
    finally:
        await server.stop()


async def test_control_socket_reports_handler_errors_instead_of_hanging(socket_dir):
    async def handler(_request):
        raise RuntimeError("boom")

    server = ControlServer(handler, socket_dir / "control.sock")
    await server.start()
    try:
        reply = await send_command({"command": "x"}, socket_dir / "control.sock")
        assert reply["ok"] is False
        assert "boom" in reply["error"]
    finally:
        await server.stop()


async def test_control_client_says_how_to_start_the_daemon(socket_dir):
    with pytest.raises(ControlClientError, match="bigbro serve"):
        await send_command({"command": "status"}, socket_dir / "nonexistent.sock")


async def test_control_socket_is_owner_only(socket_dir):
    """Anyone who can write here can approve a device onto the inference server."""
    server = ControlServer(lambda _r: asyncio.sleep(0, {"ok": True}), socket_dir / "control.sock")
    await server.start()
    try:
        assert (socket_dir / "control.sock").stat().st_mode & 0o777 == 0o600
    finally:
        await server.stop()


async def test_control_socket_replaces_a_stale_file(socket_dir):
    """A socket left by a crashed daemon must not block the next start."""
    path = socket_dir / "control.sock"
    path.write_text("stale")

    server = ControlServer(lambda _r: asyncio.sleep(0, {"ok": True}), path)
    await server.start()
    await server.stop()


async def test_oversized_socket_path_explains_itself(tmp_path):
    """macOS reports the overflow as a bare "AF_UNIX path too long"."""
    deep = tmp_path / ("d" * 60) / ("e" * 60) / "control.sock"
    with pytest.raises(OSError, match="BIGBRO_HOME"):
        await ControlServer(lambda _r: None, deep).start()
