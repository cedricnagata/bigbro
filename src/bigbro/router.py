"""Routes wire messages to the engines. Port of AppRouter in App/bigbroApp.swift.

Pure protocol logic — every message type in the README's tables is produced or
consumed here, and none of it changed in the move off Swift. A BigBroKit client
cannot tell which implementation it is talking to, which is the point.
"""

from __future__ import annotations

import base64
import binascii
import logging
from typing import Any, Callable

from .inference import catalog
from .inference.engine import InferenceError, MLXEngine
from .inference.parsers import Delta, Reasoning, ToolCall
from .protocol.pairing import PairingManager
from .protocol.server import PeerServer
from .speech import ModelKind, SpeechEngine, kinds_for

log = logging.getLogger("bigbro.router")

#: Cap on an uploaded utterance after base64 decoding. Rejecting an oversized upload
#: beats buffering it unboundedly.
MAX_UPLOAD_BYTES = 10 * 1024 * 1024

#: The reasoning budgets gpt-oss will accept. The harmony template renders the value
#: straight into the system message as `Reasoning: <level>`, and the model was trained
#: on exactly these three words — a fourth would land in the prompt as text it has
#: never seen. There is deliberately no "off". Anything unrecognized is dropped rather
#: than forwarded, so a client sending junk gets the template default, not a poisoned
#: prompt.
VALID_REASONING_EFFORTS = frozenset({"low", "medium", "high"})

#: What a request handler treats as a failed request rather than a reason to stop.
#:
#: `BaseException` minus the two that genuinely mean "stop": a library is allowed
#: to be badly behaved without taking the server with it. misaki really does call
#: `sys.exit(2)` when it cannot fetch its spaCy model, and SystemExit is not an
#: Exception — so one client asking for speech killed the daemon for every other
#: device connected to it.
REQUEST_FAILURES = (Exception, SystemExit)


def explicit_reasoning_effort(message: dict[str, Any]) -> str | None:
    """The effort the client actually named, if it named a valid one.

    Kept separate from the effective effort below because only an explicitly-sent
    setting can be *dropped*. The "low" that `think: false` implies is bigbro's own
    inference, and reporting it back as an ignored setting tells the client its
    request was degraded when it never made that request — and for a togglable
    think-tag model it is not even true, since "low" maps onto `enable_thinking`.
    """
    requested = message.get("reasoning_effort")
    if isinstance(requested, str) and requested.lower() in VALID_REASONING_EFFORTS:
        return requested.lower()
    return None


def resolve_reasoning_effort(message: dict[str, Any], send_reasoning: bool) -> str | None:
    """Resolves the effort for one request.

    An explicit `reasoning_effort` from the client always wins — that is the client
    saying how hard the model should think, independent of whether it wants to see the
    result. Absent one, `think: false` is read as a hint that the caller wants speed
    and has no use for the trace, so the budget drops to "low"; this is what that flag
    alone did before clients could ask for a level, and keeps their behaviour
    unchanged. When neither is specified the template's own default ("medium") stands.
    """
    requested = message.get("reasoning_effort")
    if isinstance(requested, str):
        lowered = requested.lower()
        if lowered not in VALID_REASONING_EFFORTS:
            log.info("ignoring unrecognized reasoning_effort '%s'", requested)
            return None
        return lowered
    return None if send_reasoning else "low"


class AppRouter:
    def __init__(
        self,
        server: PeerServer,
        pairing: PairingManager,
        engine: MLXEngine,
        speech: SpeechEngine,
    ) -> None:
        self.server = server
        self.pairing = pairing
        self.engine = engine
        self.speech = speech
        #: Set by the daemon: called with (device_id, connected) whenever a peer
        #: attaches or drops, so an attached UI can move without polling.
        self.on_peer_change: Callable[[str, bool], None] = lambda _id, _connected: None

    # MARK: - PeerServerDelegate

    async def on_message(self, message: dict[str, Any], connection_id: str) -> None:
        kind = message.get("type")
        if not isinstance(kind, str):
            log.warning("message with no type from %s", connection_id[:8])
            return

        if kind == "hello":
            await self._handle_hello(message, connection_id)
            return

        device_id = self.server.device_id(connection_id)
        if device_id is None:
            log.warning("no device for connection %s (type=%s)", connection_id[:8], kind)
            return

        if kind == "request":
            await self._handle_request(message, device_id)
        elif kind == "generateRequest":
            await self._handle_generate(message, device_id)
        elif kind == "speechRequest":
            await self._handle_speech(message, device_id)
        elif kind == "transcribeRequest":
            await self._handle_transcribe(message, device_id)
        elif kind in ("run", "preload"):
            # `preload` is the old name for `run`, kept so clients built before the
            # rename keep working — the two do exactly the same thing.
            await self._handle_run(message, device_id)
        elif kind == "stop":
            await self._handle_stop(message, device_id)
        elif kind == "bye":
            log.info("bye from %s", device_id[:8])
            self.pairing.mark_disconnected(device_id)
            await self.server.disconnect(device_id)
        else:
            log.warning("unhandled message type '%s' from %s", kind, device_id[:8])

    async def on_peer_disconnected(self, device_id: str) -> None:
        self.pairing.mark_disconnected(device_id)
        self.on_peer_change(device_id, False)

    # MARK: - Pairing

    async def _handle_hello(self, message: dict[str, Any], connection_id: str) -> None:
        device_id = str(message.get("deviceId") or "")
        device_name = str(message.get("deviceName") or "Unknown")
        app_name = str(message.get("appName") or "Unknown App")
        required = [str(m) for m in (message.get("requiredModels") or [])]

        if not device_id:
            log.warning("hello with no deviceId from %s", connection_id[:8])
            self.server.disconnect_pending(connection_id)
            return

        log.info(
            "hello from %s name='%s' app='%s' requiredModels=%s",
            device_id[:8], device_name, app_name, required,
        )

        if self.pairing.is_approved(device_id):
            self.pairing.note_seen(device_id, device_name, app_name, required)
        else:
            approved = await self.pairing.await_decision(
                device_id, device_name, app_name, required, connection_id
            )
            if not approved:
                await self.server.send_to_pending(
                    {"type": "helloAck", "status": "denied"}, connection_id
                )
                self.server.disconnect_pending(connection_id)
                log.info("helloAck(denied) sent to %s", device_id[:8])
                return
            self.pairing.approve(device_id, device_name, app_name, required)

        self.pairing.mark_connected(device_id)
        self.server.register(connection_id, device_id)
        self.on_peer_change(device_id, True)

        missing = self.pairing.missing_models(required)
        ack: dict[str, Any] = {"type": "helloAck", "status": "approved"}
        if missing:
            ack["missingModels"] = missing
        await self.server.send(ack, to=device_id)
        log.info("helloAck(approved) sent to %s, missing=%s", device_id[:8], missing)

        if missing:
            log.warning(
                "%s requires model(s) that aren't downloaded: %s — run: bigbro models download %s",
                device_name, ", ".join(missing), " ".join(missing),
            )

    async def push_models_update(self) -> None:
        """Pushes updated missing-model lists to every connected device that declared any.

        Called when a local download finishes, so a client waiting on a model learns it
        arrived without having to retry a request to find out.
        """
        for device_id in self.server.connected_device_ids:
            required = self.pairing.required_models(device_id)
            if not required:
                continue
            missing = self.pairing.missing_models(required)
            await self.server.send({"type": "modelsUpdate", "missingModels": missing}, to=device_id)

    # MARK: - Helpers

    async def _fail(self, request_id: str, message: str, device_id: str) -> None:
        log.info("%s: %s", request_id[:8], message)
        await self.server.send(
            {"type": "error", "requestId": request_id, "message": message}, to=device_id
        )

    async def _ensure_model_ready(
        self, model: catalog.BigBroModel, request_id: str, device_id: str
    ) -> bool:
        """True once `model` is ready to use.

        If it isn't, kicks off (or reports) a download and tells the peer, mirroring
        the old Ollama-missing-model flow so BigBroKit clients need no changes.
        """
        if self.engine.is_downloaded(model.id):
            return True

        already = self.engine.downloader.is_downloading(model.id)
        if not already:
            log.info("model '%s' missing — starting download for %s", model.id, device_id[:8])
            import asyncio
            asyncio.create_task(self._download_quietly(model))
        else:
            log.info("model '%s' already downloading — informing %s", model.id, device_id[:8])

        await self.server.send({
            "type": "modelDownloading",
            "requestId": request_id,
            "model": model.id,
            "alreadyInProgress": already,
        }, to=device_id)
        await self.server.send({"type": "done", "requestId": request_id}, to=device_id)
        return False

    async def _download_quietly(self, model: catalog.BigBroModel) -> None:
        try:
            await self.engine.download(model)
        except Exception as exc:
            log.error("background download of %s failed: %s", model.id, exc)
            return
        await self.push_models_update()

    async def _report_capability_gaps(self, resolved, request_id: str, device_id: str) -> None:
        """Tells the peer what the chosen model could not do, before any of the answer arrives.

        Without this the client cannot tell the difference between "the model
        considered your tools and chose not to call one" and "this model has no tool
        support and they were discarded" — the transcript looks identical. A client
        that predates the message ignores it, same as every other additive type.
        """
        notes: list[str] = []
        if resolved.dropped_tools:
            notes.append(
                f"{resolved.model.display_name} does not support tool calling — tools were ignored."
            )
        if resolved.dropped_reasoning_effort:
            notes.append(
                f"{resolved.model.display_name} has no reasoning effort control — the setting was ignored."
            )
        if not notes:
            return

        log.info("%s capability notes: %s", request_id[:8], " ".join(notes))
        await self.server.send({
            "type": "modelCapabilities",
            "requestId": request_id,
            "model": resolved.model.id,
            "supportsTools": resolved.model.supports_tools,
            "supportsImages": resolved.model.supports_images,
            "supportsReasoning": resolved.model.reasoning.produces_trace,
            "supportsReasoningEffort": resolved.model.reasoning.accepts_effort,
            "notes": notes,
        }, to=device_id)

    async def _drain(self, stream, request_id: str, device_id: str, label: str, send_reasoning: bool) -> None:
        """Drains an inference stream to the peer.

        `request` and `generateRequest` both funnel through here — the old split
        between a streamed and single-shot code path existed because the
        OpenAI-compatible backend had two different HTTP shapes; MLX generation is
        always token-by-token, so there is one path now regardless of the client's
        `streaming` flag (which governs *client-side* accumulation).
        """
        chunks = 0
        try:
            async for event in stream:
                if isinstance(event, Delta):
                    chunks += 1
                    await self.server.send(
                        {"type": "chunk", "requestId": request_id, "delta": event.text},
                        to=device_id,
                    )
                elif isinstance(event, Reasoning):
                    # Reasoning goes out as its own message type rather than folded
                    # into `chunk`: the client pipes chunks to text-to-speech, so
                    # merging them would have the model narrate its own deliberation
                    # aloud.
                    if send_reasoning:
                        await self.server.send(
                            {"type": "thinking", "requestId": request_id, "delta": event.text},
                            to=device_id,
                        )
                elif isinstance(event, ToolCall):
                    log.info("toolCall for %s: %s", request_id[:8], event.name)
                    await self.server.send(
                        {"type": "toolCall", "requestId": request_id, "calls": [event.to_wire()]},
                        to=device_id,
                    )
        except REQUEST_FAILURES as exc:
            log.error("%s error for %s: %s", label, request_id[:8], exc)
            await self.server.send(
                {"type": "error", "requestId": request_id, "message": str(exc)}, to=device_id
            )
            return

        log.info("%s complete for %s: %d chunk(s)", label, request_id[:8], chunks)
        await self.server.send({"type": "done", "requestId": request_id}, to=device_id)

    # MARK: - Inference handlers

    async def _handle_request(self, message: dict[str, Any], device_id: str) -> None:
        request_id = message.get("requestId")
        raw_messages = message.get("messages")
        if not isinstance(request_id, str) or not isinstance(raw_messages, list):
            log.warning("request missing requestId or messages")
            return

        tools = message.get("tools") or []
        options = message.get("options")
        # Absent means "unspecified", which defaults to on — this is what every client
        # sent before `think` existed, so their behaviour is unchanged.
        send_reasoning = message.get("think", True) is not False
        effort = resolve_reasoning_effort(message, send_reasoning)

        try:
            resolved = self.engine.resolve(
                message.get("model"), raw_messages, tool_count=len(tools),
                reasoning_effort=explicit_reasoning_effort(message),
            )
        except InferenceError as exc:
            await self._fail(request_id, str(exc), device_id)
            return

        log.info(
            "request %s model=%s tools=%d messages=%d think=%s effort=%s",
            request_id[:8], resolved.model.id, len(tools), len(raw_messages),
            send_reasoning, effort or "default",
        )

        if not await self._ensure_model_ready(resolved.model, request_id, device_id):
            return
        await self._report_capability_gaps(resolved, request_id, device_id)

        stream = self.engine.chat_stream(
            model=resolved.model,
            messages=raw_messages,
            tools=tools,
            options=options,
            reasoning_effort=effort,
            wants_thinking=send_reasoning,
        )
        await self._drain(stream, request_id, device_id, "Request", send_reasoning)

    async def _handle_generate(self, message: dict[str, Any], device_id: str) -> None:
        request_id = message.get("requestId")
        prompt = message.get("prompt")
        if not isinstance(request_id, str) or not isinstance(prompt, str):
            log.warning("generateRequest missing requestId or prompt")
            return

        images = message.get("images") or []
        system = message.get("system")
        options = message.get("options")
        send_reasoning = message.get("think", True) is not False
        effort = resolve_reasoning_effort(message, send_reasoning)

        raw_messages: list[dict[str, Any]] = []
        if isinstance(system, str) and system:
            raw_messages.append({"role": "system", "content": system})
        user: dict[str, Any] = {"role": "user", "content": prompt}
        if images:
            user["images"] = images
        raw_messages.append(user)

        try:
            resolved = self.engine.resolve(
                message.get("model"), raw_messages,
                reasoning_effort=explicit_reasoning_effort(message),
            )
        except InferenceError as exc:
            await self._fail(request_id, str(exc), device_id)
            return

        log.info(
            "generateRequest %s model=%s prompt='%s…' think=%s effort=%s",
            request_id[:8], resolved.model.id, prompt[:40], send_reasoning, effort or "default",
        )

        if not await self._ensure_model_ready(resolved.model, request_id, device_id):
            return
        await self._report_capability_gaps(resolved, request_id, device_id)

        stream = self.engine.chat_stream(
            model=resolved.model,
            messages=raw_messages,
            tools=[],
            options=options,
            reasoning_effort=effort,
            wants_thinking=send_reasoning,
        )
        await self._drain(stream, request_id, device_id, "Generate", send_reasoning)

    # MARK: - Lifecycle handlers

    async def _requested_model(
        self, requested: str | None, request_id: str, device_id: str
    ) -> catalog.BigBroModel | None:
        """Resolves the `model` field of a run/stop message, or reports why it could not.

        There are no capability words like `text` or `vision` any more — those meant
        "whichever model is configured for this", and nothing is configured. A
        run/stop names the exact model it means, the same as a request does.
        """
        if not requested:
            await self._fail(
                request_id,
                "No model was named. BigBro has no default — every request must name the model it wants.",
                device_id,
            )
            return None
        model = catalog.resolve(requested)
        if model is None:
            await self._fail(request_id, f"'{requested}' is not a model BigBro knows about.", device_id)
            return None
        return model

    async def _handle_run(self, message: dict[str, Any], device_id: str) -> None:
        """Starts a model — materializes its weights into memory — without generating.

        Purely an optimization: skipping it is harmless, since a request starts the
        model it needs anyway. It exists so a client can pay the multi-second load
        ahead of the user's first message.
        """
        request_id = message.get("requestId")
        if not isinstance(request_id, str):
            log.warning("run missing requestId")
            return

        requested = message.get("model")
        requested = requested.lower() if isinstance(requested, str) else None

        # Speech runs through its own engine. Kokoro and Parakeet load lazily on first
        # use, so this is what gives a client somewhere to *wait* — which matters for a
        # voice loop, where a cold load would otherwise eat the first utterance.
        if requested is not None:
            speech_kinds = kinds_for(requested)
            if speech_kinds is not None:
                await self._run_speech(speech_kinds, request_id, device_id)
                return

        model = await self._requested_model(requested, request_id, device_id)
        if model is None:
            return

        log.info("run requested by %s for %s", device_id[:8], model.display_name)
        if not await self._ensure_model_ready(model, request_id, device_id):
            return

        try:
            await self.engine.run(model)
        except Exception as exc:
            log.error("run error for %s: %s", device_id[:8], exc)
            await self.server.send(
                {"type": "error", "requestId": request_id, "message": str(exc)}, to=device_id
            )
            return

        log.info("run complete for %s: %s", device_id[:8], model.display_name)
        await self.server.send({"type": "done", "requestId": request_id}, to=device_id)

    async def _run_speech(self, kinds: list[ModelKind], request_id: str, device_id: str) -> None:
        log.info(
            "speech run requested by %s for %s",
            device_id[:8], ", ".join(k.display_name for k in kinds),
        )
        try:
            # Sequential, not concurrent: both are Metal loads, so racing them
            # contends for the same device and finishes no sooner.
            for kind in kinds:
                await self.speech.run(kind)
        except Exception as exc:
            log.error("speech run error for %s: %s", device_id[:8], exc)
            await self.server.send(
                {"type": "error", "requestId": request_id, "message": str(exc)}, to=device_id
            )
            return

        log.info("speech run complete for %s", device_id[:8])
        await self.server.send({"type": "done", "requestId": request_id}, to=device_id)

    async def _handle_stop(self, message: dict[str, Any], device_id: str) -> None:
        """Unloads a model from memory, keeping its download.

        Deliberately not a delete: the weights stay on disk, so starting it again
        skips the download entirely. Removal is not exposed over the wire at all —
        that is destructive and belongs to whoever owns the Mac.
        """
        request_id = message.get("requestId")
        if not isinstance(request_id, str):
            log.warning("stop missing requestId")
            return

        requested = message.get("model")
        requested = requested.lower() if isinstance(requested, str) else None

        if requested is not None and kinds_for(requested) is not None:
            # Speech models are shared by every paired device and reload slowly;
            # letting one client evict them for everyone is not a trade worth offering.
            await self._fail(request_id, "Speech models cannot be stopped remotely.", device_id)
            return

        model = await self._requested_model(requested, request_id, device_id)
        if model is None:
            return

        self.engine.stop(model.id)
        log.info("stopped %s for %s", model.display_name, device_id[:8])
        await self.server.send({"type": "done", "requestId": request_id}, to=device_id)

    # MARK: - Speech handlers

    async def _handle_speech(self, message: dict[str, Any], device_id: str) -> None:
        request_id = message.get("requestId")
        text = message.get("input")
        if not isinstance(request_id, str) or not isinstance(text, str):
            log.warning("speechRequest missing requestId or input")
            return

        # Rejected here, with the reason, rather than deep in the engine. Kokoro
        # yields no segments for whitespace-only input, and "Kokoro produced no
        # audio for that input" describes the symptom while hiding the cause: an
        # answer that was all reasoning, or all newlines, was sent to be spoken.
        if not text.strip():
            await self._fail(request_id, "There was no text to speak.", device_id)
            return

        voice = message.get("voice")
        voice = voice if isinstance(voice, str) and voice else None
        speed = message.get("speed")
        speed = float(speed) if isinstance(speed, (int, float)) else None

        from .speech import DEFAULT_VOICE
        resolved_voice = voice or DEFAULT_VOICE

        try:
            # Headerless PCM describes nothing about itself, so the client is told the
            # format up front — it needs the rate and channel count to configure
            # playback before the first chunk lands. Always pcm/24kHz/mono: Kokoro has
            # no other output shape, so there is nothing left to negotiate.
            await self.server.send({
                "type": "audioStart",
                "requestId": request_id,
                "format": "pcm",
                "sampleRate": 24_000,
                "channels": 1,
                "voice": resolved_voice,
            }, to=device_id)

            seq = 0
            async for chunk in self.speech.synthesize(text, voice=voice, speed=speed):
                if not self.server.is_connected(device_id):
                    log.info("peer %s gone, abandoning speech %s", device_id[:8], request_id[:8])
                    return
                await self.server.send({
                    "type": "audioChunk",
                    "requestId": request_id,
                    "audio": base64.b64encode(chunk).decode(),
                    "seq": seq,
                }, to=device_id)
                seq += 1
        except REQUEST_FAILURES as exc:
            log.error("speech error for %s: %s", request_id[:8], exc)
            await self.server.send(
                {"type": "error", "requestId": request_id, "message": str(exc)}, to=device_id
            )
            return

        log.info("speech complete for %s: %d chunk(s)", request_id[:8], seq)
        await self.server.send({"type": "done", "requestId": request_id}, to=device_id)

    async def _handle_transcribe(self, message: dict[str, Any], device_id: str) -> None:
        request_id = message.get("requestId")
        encoded = message.get("audio")
        if not isinstance(request_id, str) or not isinstance(encoded, str):
            log.warning("transcribeRequest missing requestId or audio")
            return

        try:
            audio = base64.b64decode(encoded, validate=True)
        except (binascii.Error, ValueError):
            await self._fail(request_id, "Audio payload was not valid base64.", device_id)
            return

        if len(audio) > MAX_UPLOAD_BYTES:
            megabytes = MAX_UPLOAD_BYTES // 1_048_576
            await self._fail(request_id, f"Audio exceeds the {megabytes} MB upload limit.", device_id)
            return

        audio_format = message.get("audioFormat")
        audio_format = audio_format if isinstance(audio_format, str) else "wav"

        try:
            text, language = await self.speech.transcribe(audio, audio_format)
        except REQUEST_FAILURES as exc:
            log.error("transcribe error for %s: %s", request_id[:8], exc)
            await self.server.send(
                {"type": "error", "requestId": request_id, "message": str(exc)}, to=device_id
            )
            return

        log.info("transcript for %s: %d chars", request_id[:8], len(text))
        reply: dict[str, Any] = {"type": "transcript", "requestId": request_id, "text": text}
        if language:
            reply["language"] = language
        await self.server.send(reply, to=device_id)
        await self.server.send({"type": "done", "requestId": request_id}, to=device_id)
