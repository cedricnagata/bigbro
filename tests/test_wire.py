"""End-to-end protocol tests over a real socket.

Drives PeerServer + AppRouter with stub engines, so the whole path a BigBroKit client
takes — connect, hello, approval, request, stream, disconnect — is exercised against
the actual framing rather than mocked out. This is the test that would catch a
message type going missing in the port.
"""

from __future__ import annotations

import asyncio
import base64
import contextlib

import pytest

from bigbro.config import JSONStore
from bigbro.inference.engine import MLXEngine
from bigbro.inference.parsers import Delta, Reasoning, ToolCall
from bigbro.protocol.framing import FrameDecoder, encode
from bigbro.protocol.pairing import PairingManager
from bigbro.protocol.server import PeerServer
from bigbro.router import AppRouter


class StubEngine:
    """Stands in for MLXEngine. Never touches MLX."""

    def __init__(self, events=None, downloaded=True):
        self.events = events if events is not None else [Delta("Hello.")]
        self.downloaded = downloaded
        self.started: list[str] = []
        self.stopped: list[str] = []
        self.downloader = self

    # engine surface
    def is_downloaded(self, _model_id):
        return self.downloaded

    def is_downloading(self, _model_id):
        return False

    # The real resolution logic — capability negotiation and the image check are the
    # behaviour under test, so borrow them rather than reimplementing them in a stub
    # that would agree with itself no matter what the engine does.
    resolve = MLXEngine.resolve

    def is_required_model_satisfied(self, _name):
        return self.downloaded

    async def chat_stream(self, **_kwargs):
        for event in self.events:
            yield event

    async def run(self, entry):
        self.started.append(entry.id)

    async def download(self, entry):
        self.downloaded = True

    def stop(self, model_id):
        self.stopped.append(model_id)


class StubSpeech:
    def __init__(self):
        self.ran = []

    async def run(self, kind):
        self.ran.append(kind)

    async def synthesize(self, text, voice=None, speed=None):
        for chunk in (b"\x01\x02", b"\x03\x04"):
            yield chunk

    async def transcribe(self, audio, audio_format="wav"):
        return "transcribed text", "en"


class Client:
    """A minimal BigBroKit stand-in speaking the real wire protocol."""

    def __init__(self, reader, writer):
        self.reader, self.writer = reader, writer
        self.decoder = FrameDecoder()
        self.inbox: list[dict] = []

    async def send(self, message):
        self.writer.write(encode(message))
        await self.writer.drain()

    async def next(self, timeout=5.0):
        while not self.inbox:
            chunk = await asyncio.wait_for(self.reader.read(65536), timeout)
            if not chunk:
                raise ConnectionError("server closed the connection")
            self.inbox.extend(self.decoder.feed(chunk))
        return self.inbox.pop(0)

    async def collect_until(self, kind, timeout=5.0):
        """Everything up to and including the first message of type `kind`."""
        received = []
        while True:
            message = await self.next(timeout)
            received.append(message)
            if message.get("type") == kind:
                return received

    async def close(self):
        with contextlib.suppress(Exception):
            self.writer.close()
            await self.writer.wait_closed()


@pytest.fixture
async def harness(tmp_path, unused_tcp_port):
    engine, speech = StubEngine(), StubSpeech()
    pairing = PairingManager(JSONStore(tmp_path / "devices.json"))
    pairing.is_model_satisfied = engine.is_required_model_satisfied

    server = PeerServer()
    router = AppRouter(server, pairing, engine, speech)
    server.delegate = router
    await server.start(unused_tcp_port, host="127.0.0.1")

    async def connect():
        reader, writer = await asyncio.open_connection("127.0.0.1", unused_tcp_port)
        return Client(reader, writer)

    yield type("Harness", (), {
        "connect": staticmethod(connect), "server": server, "pairing": pairing,
        "engine": engine, "speech": speech, "router": router,
    })()

    await server.stop()


async def approved_client(harness, device_id="device-1", models=None):
    client = await harness.connect()
    await client.send({
        "type": "hello", "deviceId": device_id, "deviceName": "iPhone",
        "appName": "TestApp", "requiredModels": models or [],
    })
    await asyncio.sleep(0.05)
    harness.pairing.resolve_pending(device_id, approved=True)
    ack = await client.next()
    assert ack["type"] == "helloAck" and ack["status"] == "approved"
    return client


# MARK: - Pairing


async def test_hello_parks_then_approves(harness):
    client = await harness.connect()
    await client.send({
        "type": "hello", "deviceId": "d1", "deviceName": "iPhone", "appName": "App",
    })
    await asyncio.sleep(0.05)

    assert len(harness.pairing.pending_requests) == 1
    harness.pairing.resolve_pending("d1", approved=True)

    ack = await client.next()
    assert ack == {"type": "helloAck", "status": "approved"}
    assert harness.pairing.is_approved("d1")
    await client.close()


async def test_denied_device_is_told_and_disconnected(harness):
    client = await harness.connect()
    await client.send({"type": "hello", "deviceId": "d2", "deviceName": "iPhone", "appName": "App"})
    await asyncio.sleep(0.05)
    harness.pairing.resolve_pending("d2", approved=False)

    ack = await client.next()
    assert ack == {"type": "helloAck", "status": "denied"}
    assert not harness.pairing.is_approved("d2")
    await client.close()


async def test_known_device_reconnects_without_approval(harness):
    harness.pairing.approve("known", "iPhone", "App", [])
    client = await harness.connect()
    await client.send({"type": "hello", "deviceId": "known", "deviceName": "iPhone", "appName": "App"})

    ack = await client.next()
    assert ack["status"] == "approved"
    assert harness.pairing.pending_requests == []
    await client.close()


async def test_hello_ack_reports_missing_models(harness):
    harness.engine.downloaded = False
    harness.pairing.approve("d3", "iPhone", "App", [])
    client = await harness.connect()
    await client.send({
        "type": "hello", "deviceId": "d3", "deviceName": "iPhone",
        "appName": "App", "requiredModels": ["qwen3-4b"],
    })

    ack = await client.next()
    assert ack["missingModels"] == ["qwen3-4b"]
    await client.close()


# MARK: - Keepalive


async def test_ping_is_answered_with_pong(harness):
    client = await approved_client(harness)
    await client.send({"type": "ping"})
    assert (await client.next())["type"] == "pong"
    await client.close()


# MARK: - Inference


async def test_request_streams_chunks_then_done(harness):
    harness.engine.events = [Delta("Hello, "), Delta("world.")]
    client = await approved_client(harness)
    await client.send({
        "type": "request", "requestId": "r1", "streaming": True,
        "model": "llama-3.2-1b", "messages": [{"role": "user", "content": "hi"}],
    })

    received = await client.collect_until("done")
    assert [m["type"] for m in received] == ["chunk", "chunk", "done"]
    assert "".join(m["delta"] for m in received[:2]) == "Hello, world."
    assert all(m["requestId"] == "r1" for m in received)
    await client.close()


async def test_reasoning_is_a_separate_message_type(harness):
    """Merged into `chunk`, the client would speak the model's deliberation aloud."""
    harness.engine.events = [Reasoning("thinking..."), Delta("The answer.")]
    client = await approved_client(harness)
    await client.send({
        "type": "request", "requestId": "r2", "model": "qwen3-4b",
        "messages": [{"role": "user", "content": "hi"}],
    })

    received = await client.collect_until("done")
    assert [m["type"] for m in received] == ["thinking", "chunk", "done"]
    assert received[0]["delta"] == "thinking..."
    await client.close()


async def test_think_false_suppresses_reasoning_on_the_wire(harness):
    harness.engine.events = [Reasoning("hidden"), Delta("shown")]
    client = await approved_client(harness)
    await client.send({
        "type": "request", "requestId": "r3", "model": "qwen3-4b", "think": False,
        "messages": [{"role": "user", "content": "hi"}],
    })

    received = await client.collect_until("done")
    assert [m["type"] for m in received] == ["chunk", "done"]
    await client.close()


async def test_think_false_is_not_reported_as_a_dropped_setting(harness):
    """`think: false` implies "low" internally — that is bigbro's inference, not a
    setting the client sent, so it must not come back as one that was ignored."""
    harness.engine.events = [Delta("answer")]
    client = await approved_client(harness)
    await client.send({
        "type": "request", "requestId": "r3b", "model": "qwen3-4b", "think": False,
        "messages": [{"role": "user", "content": "hi"}],
    })

    received = await client.collect_until("done")
    assert "modelCapabilities" not in [m["type"] for m in received]
    await client.close()


async def test_explicit_effort_on_a_non_harmony_model_is_reported(harness):
    """An effort the client really did send, on a model that cannot honour it, is."""
    harness.engine.events = [Delta("answer")]
    client = await approved_client(harness)
    await client.send({
        "type": "request", "requestId": "r3c", "model": "qwen3-4b",
        "reasoning_effort": "high",
        "messages": [{"role": "user", "content": "hi"}],
    })

    received = await client.collect_until("done")
    assert received[0]["type"] == "modelCapabilities"
    assert "no reasoning effort control" in received[0]["notes"][0]
    await client.close()


async def test_tool_calls_are_forwarded(harness):
    harness.engine.events = [ToolCall("get_weather", '{"city":"Tokyo"}')]
    client = await approved_client(harness)
    await client.send({
        "type": "request", "requestId": "r4", "model": "llama-3.2-1b",
        "tools": [{"type": "function", "function": {"name": "get_weather"}}],
        "messages": [{"role": "user", "content": "weather?"}],
    })

    received = await client.collect_until("done")
    call = next(m for m in received if m["type"] == "toolCall")
    assert call["calls"][0]["function"]["name"] == "get_weather"
    assert call["calls"][0]["function"]["arguments"] == {"city": "Tokyo"}
    await client.close()


async def test_capability_gaps_are_reported_before_the_answer(harness):
    """The client cannot otherwise distinguish "chose not to call" from "cannot call"."""
    client = await approved_client(harness)
    await client.send({
        "type": "request", "requestId": "r5", "model": "gemma-3-1b",
        "tools": [{"type": "function", "function": {"name": "f"}}],
        "messages": [{"role": "user", "content": "hi"}],
    })

    received = await client.collect_until("done")
    assert received[0]["type"] == "modelCapabilities"
    assert received[0]["supportsTools"] is False
    assert "does not support tool calling" in received[0]["notes"][0]
    await client.close()


async def test_unknown_model_is_an_error_not_a_substitution(harness):
    client = await approved_client(harness)
    await client.send({
        "type": "request", "requestId": "r6", "model": "gpt-4",
        "messages": [{"role": "user", "content": "hi"}],
    })

    error = await client.next()
    assert error["type"] == "error"
    assert "not a model BigBro knows about" in error["message"]
    await client.close()


async def test_missing_model_triggers_download_notice_not_generation(harness):
    harness.engine.downloaded = False
    client = await approved_client(harness)
    await client.send({
        "type": "request", "requestId": "r7", "model": "llama-3.2-1b",
        "messages": [{"role": "user", "content": "hi"}],
    })

    received = await client.collect_until("done")
    assert [m["type"] for m in received] == ["modelDownloading", "done"]
    assert received[0]["model"] == "llama-3.2-1b"
    await client.close()


async def test_generate_request_builds_a_system_and_user_turn(harness):
    harness.engine.events = [Delta("ok")]
    client = await approved_client(harness)
    await client.send({
        "type": "generateRequest", "requestId": "r8", "model": "llama-3.2-1b",
        "prompt": "hello", "system": "be brief",
    })

    received = await client.collect_until("done")
    assert [m["type"] for m in received] == ["chunk", "done"]
    await client.close()


async def test_image_on_a_language_model_fails_rather_than_answering_blind(harness):
    client = await approved_client(harness)
    await client.send({
        "type": "generateRequest", "requestId": "r9", "model": "llama-3.2-1b",
        "prompt": "what is this?", "images": ["aGVsbG8="],
    })

    error = await client.next()
    assert error["type"] == "error"
    assert "cannot see images" in error["message"]
    await client.close()


# MARK: - Lifecycle


async def test_run_loads_without_generating(harness):
    client = await approved_client(harness)
    await client.send({"type": "run", "requestId": "r10", "model": "llama-3.2-1b"})

    assert (await client.next())["type"] == "done"
    assert harness.engine.started == ["llama-3.2-1b"]
    await client.close()


async def test_preload_is_still_accepted_as_an_alias_for_run(harness):
    client = await approved_client(harness)
    await client.send({"type": "preload", "requestId": "r11", "model": "llama-3.2-1b"})

    assert (await client.next())["type"] == "done"
    assert harness.engine.started == ["llama-3.2-1b"]
    await client.close()


async def test_stop_unloads(harness):
    client = await approved_client(harness)
    await client.send({"type": "stop", "requestId": "r12", "model": "llama-3.2-1b"})

    assert (await client.next())["type"] == "done"
    assert harness.engine.stopped == ["llama-3.2-1b"]
    await client.close()


async def test_speech_models_cannot_be_stopped_remotely(harness):
    """They are shared by every device and reload slowly."""
    client = await approved_client(harness)
    await client.send({"type": "stop", "requestId": "r13", "model": "tts"})

    error = await client.next()
    assert error["type"] == "error"
    assert "cannot be stopped remotely" in error["message"]
    await client.close()


async def test_run_speech_starts_both_engines(harness):
    client = await approved_client(harness)
    await client.send({"type": "run", "requestId": "r14", "model": "speech"})

    assert (await client.next())["type"] == "done"
    assert len(harness.speech.ran) == 2
    await client.close()


# MARK: - Speech


async def test_speech_request_streams_audio_with_a_header_first(harness):
    client = await approved_client(harness)
    await client.send({"type": "speechRequest", "requestId": "r15", "input": "hello"})

    received = await client.collect_until("done")
    assert [m["type"] for m in received] == ["audioStart", "audioChunk", "audioChunk", "done"]
    assert received[0]["format"] == "pcm"
    assert received[0]["sampleRate"] == 24_000
    assert received[0]["channels"] == 1
    assert received[0]["voice"] == "af_heart"
    assert [m["seq"] for m in received[1:3]] == [0, 1]
    assert base64.b64decode(received[1]["audio"]) == b"\x01\x02"
    await client.close()


async def test_transcribe_returns_text_and_language(harness):
    client = await approved_client(harness)
    await client.send({
        "type": "transcribeRequest", "requestId": "r16",
        "audio": base64.b64encode(b"RIFF fake wav").decode(),
    })

    received = await client.collect_until("done")
    assert received[0]["type"] == "transcript"
    assert received[0]["text"] == "transcribed text"
    assert received[0]["language"] == "en"
    await client.close()


async def test_transcribe_rejects_invalid_base64(harness):
    client = await approved_client(harness)
    await client.send({"type": "transcribeRequest", "requestId": "r17", "audio": "!!!not base64!!!"})

    error = await client.next()
    assert error["type"] == "error"
    assert "valid base64" in error["message"]
    await client.close()


async def test_transcribe_rejects_oversized_upload(harness):
    client = await approved_client(harness)
    oversized = base64.b64encode(b"\x00" * (10 * 1024 * 1024 + 1)).decode()
    await client.send({"type": "transcribeRequest", "requestId": "r18", "audio": oversized})

    error = await client.next()
    assert error["type"] == "error"
    assert "upload limit" in error["message"]
    await client.close()


# MARK: - Disconnect


async def test_bye_gets_a_bye_back_and_marks_disconnected(harness):
    client = await approved_client(harness, device_id="bye-device")
    await client.send({"type": "bye"})

    assert (await client.next())["type"] == "bye"
    await asyncio.sleep(0.05)
    assert "bye-device" not in harness.pairing.connected_device_ids
    await client.close()


async def test_dropped_connection_marks_the_device_disconnected(harness):
    client = await approved_client(harness, device_id="drop-device")
    assert "drop-device" in harness.pairing.connected_device_ids

    await client.close()
    await asyncio.sleep(0.1)
    assert "drop-device" not in harness.pairing.connected_device_ids


async def test_two_devices_are_addressed_independently(harness):
    first = await approved_client(harness, device_id="dev-a")
    second = await approved_client(harness, device_id="dev-b")

    assert set(harness.server.connected_device_ids) == {"dev-a", "dev-b"}
    await harness.server.send({"type": "chunk", "requestId": "x", "delta": "for-a"}, to="dev-a")

    message = await first.next()
    assert message["delta"] == "for-a"
    await first.close()
    await second.close()


# MARK: - Nothing to speak
#
# Kokoro yields no segments for whitespace-only input, and the engine reported
# that as "Kokoro produced no audio for that input" — the symptom, not the cause.
# A client whose answer was all reasoning, or ended up as a couple of newlines,
# got a message about the speech model.


@pytest.mark.parametrize("text", ["", "   ", "\n\n", "\t \n"])
async def test_speaking_nothing_says_so(harness, text):
    client = await approved_client(harness)
    await client.send({"type": "speechRequest", "requestId": "sx", "input": text})

    error = await client.next()
    assert error["type"] == "error"
    assert error["message"] == "There was no text to speak."
    await client.close()


async def test_text_with_something_in_it_is_still_spoken(harness):
    """The guard must not swallow input that only looks unpromising."""
    client = await approved_client(harness)
    await client.send({"type": "speechRequest", "requestId": "sy", "input": "  ...  "})

    received = await client.collect_until("done")
    assert [m["type"] for m in received] == ["audioStart", "audioChunk", "audioChunk", "done"]
    await client.close()
