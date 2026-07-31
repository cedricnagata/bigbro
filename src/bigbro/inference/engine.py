"""Runs catalog models in-process via mlx-lm / mlx-vlm.

Any model in the catalog can be downloaded and run, and more than one can stay
resident at once — a Mac has the memory for a 12 GB text model and a 2 GB vision
model together, so unlike a phone app there is no need to evict one to make room for
the other. Loaded models are keyed by catalog id and never evicted automatically; a
Mac that loads several large models will hold them all until told otherwise.
"""

from __future__ import annotations

import asyncio
import base64
import binascii
import io
import logging
import queue
import threading
from dataclasses import dataclass
from enum import Enum
from typing import Any, AsyncIterator

from .catalog import BigBroModel, Family, ReasoningStyle, resolve
from .downloader import ModelDownloader
from .parsers import Delta, ParsedEvent, Reasoning, ToolCall

log = logging.getLogger("bigbro.engine")

#: Sentinel pushed onto the bridge queue when a generation thread finishes.
_DONE = object()


class InferenceError(Exception):
    """Anything the client should see as an `error` message rather than a crash."""


class ModelNotSpecified(InferenceError):
    def __init__(self) -> None:
        super().__init__(
            "No model was named. BigBro has no default — every request must name the model it wants."
        )


class UnknownModel(InferenceError):
    def __init__(self, name: str) -> None:
        super().__init__(f"'{name}' is not a model BigBro knows about.")


class ModelCannotSeeImages(InferenceError):
    def __init__(self, display_name: str) -> None:
        super().__init__(
            f"{display_name} cannot see images. Name a vision model for requests that carry them."
        )


class InvalidImage(InferenceError):
    def __init__(self, index: int) -> None:
        super().__init__(f"Message {index} included an image that could not be decoded.")


class RunState(str, Enum):
    """Where a model is in its lifecycle.

    Downloaded and running are genuinely different states, not two names for one: a
    12 GB model on disk costs nothing until its weights are materialized into memory,
    and that step is both slow and expensive enough to see and control separately.
    """
    NOT_DOWNLOADED = "not downloaded"
    DOWNLOADING = "downloading"
    DOWNLOADED = "downloaded"
    STARTING = "starting"
    RUNNING = "running"
    FAILED = "failed"


@dataclass(frozen=True)
class ResolvedRequest:
    """What was actually done with a request, once the model's capabilities were
    taken into account.

    Only ever describes capabilities that were *dropped* — never a model that was
    swapped. BigBro runs the model it was asked for or fails; there is no
    substitution to report.
    """
    model: BigBroModel
    dropped_tools: bool
    dropped_reasoning_effort: bool


class MLXEngine:
    def __init__(self, downloader: ModelDownloader | None = None) -> None:
        self.downloader = downloader or ModelDownloader()
        self._loaded: dict[str, Any] = {}                       # id → (model, processor)
        self._load_tasks: dict[str, asyncio.Task] = {}
        self._errors: dict[str, str] = {}
        # MLX generation is not safe to run concurrently — Metal command buffers and
        # the model's own KV cache are shared mutable state. Swift got this for free
        # from actor isolation on ModelContainer; here it has to be explicit.
        self._generation_lock = asyncio.Lock()

    # MARK: - State

    def state(self, model_id: str) -> RunState:
        if model_id in self._loaded:
            return RunState.RUNNING
        if model_id in self._errors:
            return RunState.FAILED
        if model_id in self._load_tasks:
            return RunState.STARTING if self.is_downloaded(model_id) else RunState.DOWNLOADING
        if self.downloader.is_downloading(model_id):
            return RunState.DOWNLOADING
        return RunState.DOWNLOADED if self.is_downloaded(model_id) else RunState.NOT_DOWNLOADED

    def state_description(self, model_id: str) -> str:
        state = self.state(model_id)
        if state is RunState.DOWNLOADING:
            progress = self.downloader.progress(model_id)
            if progress is not None and progress.bytes_total:
                return f"downloading {round(progress.fraction * 100)}%"
        if state is RunState.FAILED:
            return f"error: {self._errors.get(model_id, 'unknown')}"
        return state.value

    def is_running(self, model_id: str) -> bool:
        return model_id in self._loaded

    def is_busy(self, model_id: str) -> bool:
        return model_id in self._load_tasks or self.downloader.is_downloading(model_id)

    def is_downloaded(self, model_id: str) -> bool:
        return model_id in self._loaded or self.downloader.record.is_downloaded(model_id)

    # MARK: - Lifecycle

    async def download(self, model: BigBroModel) -> None:
        await self.downloader.download(model)
        self._errors.pop(model.id, None)

    async def run(self, model: BigBroModel):
        """Materializes a model's weights into memory. Downloads first if needed."""
        loaded = self._loaded.get(model.id)
        if loaded is not None:
            return loaded

        existing = self._load_tasks.get(model.id)
        if existing is not None:
            return await existing

        task = asyncio.create_task(self._load(model))
        self._load_tasks[model.id] = task
        try:
            return await task
        finally:
            self._load_tasks.pop(model.id, None)

    async def _load(self, model: BigBroModel):
        try:
            # Always through the downloader first, even when the files are cached: it
            # is a fast no-op then, and it is what records the directory `remove`
            # later deletes.
            await self.downloader.download(model)
            log.info("loading %s (%s)", model.display_name, model.repo)
            loaded = await asyncio.to_thread(self._load_blocking, model)
        except Exception as exc:
            self._errors[model.id] = str(exc)
            log.error("failed to load %s: %s", model.id, exc)
            raise

        self._loaded[model.id] = loaded
        self._errors.pop(model.id, None)
        log.info("%s is running", model.display_name)
        return loaded

    @staticmethod
    def _load_blocking(model: BigBroModel):
        if model.family is Family.VISION:
            from mlx_vlm import load as vlm_load
            return vlm_load(model.repo)
        from mlx_lm import load as lm_load
        return lm_load(model.repo)

    def stop(self, model_id: str) -> None:
        """Unloads a model from memory, keeping the download.

        Succeeds whether or not the model was running — "stop what isn't started" is
        the state the caller wanted, not an error.
        """
        if self._loaded.pop(model_id, None) is None:
            return
        self._errors.pop(model_id, None)
        log.info("stopped %s", model_id)
        # Reclaim what the model was holding. MLX caches buffers between requests, and
        # those survive the model object going away unless the cache is cleared.
        try:
            import mlx.core as mx
            mx.clear_cache()
        except Exception:  # pragma: no cover - depends on the MLX version
            pass

    def remove(self, model: BigBroModel) -> None:
        """Deletes a model's downloaded weights. Stops it first if it is running."""
        self.stop(model.id)
        self._errors.pop(model.id, None)
        self.downloader.remove(model)

    # MARK: - Routing

    def resolve(
        self,
        requested_model: str | None,
        messages: list[dict[str, Any]],
        tool_count: int = 0,
        reasoning_effort: str | None = None,
    ) -> ResolvedRequest:
        """Resolves the model a request named, or raises.

        Every request names its own model — BigBro keeps no default to fall back on.
        That is deliberate: a fallback turns "the client asked for something this Mac
        doesn't have" into an ordinary-looking answer from a different model, which
        the client has no way to detect.

        Images are checked against the named model rather than routed around it, for
        the same reason. A language model handed an image cannot describe it — it has
        no vision tower and the image never reaches the prompt — and with nothing
        configured to substitute, this is an error rather than a silent answer from
        the text alone.
        """
        if not requested_model:
            raise ModelNotSpecified()
        model = resolve(requested_model)
        if model is None:
            raise UnknownModel(requested_model)

        has_images = any(msg.get("images") for msg in messages)
        if has_images and not model.supports_images:
            raise ModelCannotSeeImages(model.display_name)

        return ResolvedRequest(
            model=model,
            dropped_tools=tool_count > 0 and not model.supports_tools,
            dropped_reasoning_effort=reasoning_effort is not None and not model.reasoning.accepts_effort,
        )

    def is_required_model_satisfied(self, name: str) -> bool:
        """True if a model a client declared is ready without a multi-gigabyte download.

        A name matching nothing in the catalog cannot be "missing" in a way the user
        could fix by downloading, so it is not reported and no pull is offered.
        """
        model = resolve(name)
        if model is None:
            return True
        return self.is_downloaded(model.id)

    # MARK: - Chat

    async def chat_stream(
        self,
        model: BigBroModel,
        messages: list[dict[str, Any]],
        tools: list[dict[str, Any]] | None = None,
        options: dict[str, Any] | None = None,
        reasoning_effort: str | None = None,
        wants_thinking: bool = True,
    ) -> AsyncIterator[ParsedEvent]:
        """Runs one request, adapting it to what the chosen model can actually do.

        Three capabilities are negotiated here rather than assumed, because getting
        any of them wrong fails quietly rather than loudly:

        - **Tools.** A model whose chat template has no tools slot either throws when
          handed tool definitions or drops them. Neither tells the caller anything, so
          tools are removed before templating and the omission is reported back.
        - **Reasoning effort.** `reasoning_effort` is meaningful only to harmony
          models. Put into any other template it is an unused variable at best; for
          Qwen3 the equivalent lever is `enable_thinking`, a different key.
        - **Output framing.** Each model's reasoning style decides how the raw stream
          is parsed back apart. See `parsers`.
        """
        tools = tools or []
        if tools and not model.supports_tools:
            log.info("%s cannot call tools — dropped %d", model.id, len(tools))
        effective_tools = tools if model.supports_tools else []

        loaded = await self.run(model)
        parser = model.reasoning.make_parser()
        context = template_context(model, reasoning_effort, wants_thinking)

        # One generation at a time, process-wide. Held across the whole stream, so a
        # second request queues behind this one rather than corrupting it.
        async with self._generation_lock:
            bridge: queue.Queue = queue.Queue(maxsize=256)
            loop = asyncio.get_running_loop()

            def produce() -> None:
                try:
                    for text in _generate_blocking(
                        loaded, model, messages, effective_tools, options, context
                    ):
                        bridge.put(text)
                except Exception as exc:  # surfaced on the consuming side
                    bridge.put(exc)
                finally:
                    bridge.put(_DONE)

            thread = threading.Thread(target=produce, name=f"generate-{model.id}", daemon=True)
            thread.start()

            try:
                while True:
                    item = await loop.run_in_executor(None, bridge.get)
                    if item is _DONE:
                        break
                    if isinstance(item, Exception):
                        raise InferenceError(str(item)) from item
                    for event in parser.feed(item):
                        yield event
                for event in parser.finish():
                    yield event
            finally:
                thread.join(timeout=5)


def template_context(
    model: BigBroModel, reasoning_effort: str | None, wants_thinking: bool
) -> dict[str, Any]:
    """Extra variables handed to the chat template, chosen per model.

    Passing the wrong key is not harmless. Templates are Jinja, and an unexpected
    variable is ignored — so a `reasoning_effort` sent to Qwen3 does nothing at all
    while looking like it worked. Each style gets only the key its own template
    defines.
    """
    if model.reasoning is ReasoningStyle.HARMONY:
        # A string, because the harmony template interpolates it into the system
        # message as text: `Reasoning: <level>`. Absent leaves the template's own
        # default ("medium") — gpt-oss always reasons, only the budget is adjustable.
        return {"reasoning_effort": reasoning_effort} if reasoning_effort else {}

    if model.reasoning is ReasoningStyle.THINK_TAGS_TOGGLABLE:
        # A bool, not the string "false" — these templates branch on
        # `{% if enable_thinking %}`, and Jinja treats any non-empty string as truthy,
        # so "false" would enable thinking while looking like it disabled it.
        #
        # Qwen3 has no effort dial, only on/off. "low" is the closest thing a caller
        # can say to "think less", so it maps onto the only lever the template has.
        return {"enable_thinking": wants_thinking and reasoning_effort != "low"}

    return {}


def generation_kwargs(options: dict[str, Any] | None) -> dict[str, Any]:
    """Maps the client's Ollama-shaped options onto mlx-lm's generation arguments.

    Forwards what maps and silently drops what has no equivalent (`num_ctx`,
    `num_thread`, `stop`, and the presence/frequency penalties mlx-lm does not
    implement) — the same discipline the OpenAI proxy used for its own extensions.
    """
    result: dict[str, Any] = {}
    if not options:
        return result

    if isinstance(options.get("num_predict"), int):
        result["max_tokens"] = options["num_predict"]

    sampler_args: dict[str, Any] = {}
    if isinstance(options.get("temperature"), (int, float)):
        sampler_args["temp"] = float(options["temperature"])
    if isinstance(options.get("top_k"), int):
        sampler_args["top_k"] = options["top_k"]
    if isinstance(options.get("top_p"), (int, float)):
        sampler_args["top_p"] = float(options["top_p"])
    if sampler_args:
        result["_sampler_args"] = sampler_args

    if isinstance(options.get("repeat_penalty"), (int, float)):
        result["_repetition_penalty"] = float(options["repeat_penalty"])
    if isinstance(options.get("seed"), int):
        result["_seed"] = options["seed"]

    return result


def decode_images(messages: list[dict[str, Any]]) -> list:
    """Decodes every base64 image in the conversation, in order.

    Raises rather than skipping a bad one: an image the model never sees produces an
    answer written as if it had, which the client cannot distinguish from a real one.
    """
    from PIL import Image

    images = []
    for index, message in enumerate(messages):
        for encoded in message.get("images") or []:
            try:
                raw = base64.b64decode(encoded, validate=True)
                images.append(Image.open(io.BytesIO(raw)).convert("RGB"))
            except (binascii.Error, ValueError, OSError) as exc:
                raise InvalidImage(index) from exc
    return images


def _chat_messages(messages: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Translates the Ollama-shaped messages BigBroKit sends into chat-template shape.

    `tool` messages address the call they answer by `tool_name` on the wire, but chat
    templates expect a `tool_call_id`, so ids are synthesized on the assistant turn
    and looked back up here.
    """
    out: list[dict[str, Any]] = []
    call_ids_by_name: dict[str, str] = {}

    for index, message in enumerate(messages):
        role = message.get("role", "user")
        content = message.get("content", "") or ""

        if role == "assistant":
            call_ids_by_name.clear()
            entry: dict[str, Any] = {"role": "assistant", "content": content}
            raw_calls = message.get("tool_calls") or []
            calls = []
            for position, call in enumerate(raw_calls):
                function = call.get("function") or {}
                name = function.get("name")
                if not name:
                    continue
                call_id = call.get("id") or f"call_{index}_{position}"
                call_ids_by_name[name] = call_id
                calls.append({
                    "id": call_id,
                    "type": "function",
                    "function": {"name": name, "arguments": function.get("arguments") or {}},
                })
            if calls:
                entry["tool_calls"] = calls
            out.append(entry)
            continue

        if role == "tool":
            entry = {"role": "tool", "content": content}
            name = message.get("tool_name")
            if name:
                entry["name"] = name
                if name in call_ids_by_name:
                    entry["tool_call_id"] = call_ids_by_name[name]
            out.append(entry)
            continue

        if role not in ("system", "user"):
            role = "user"
        out.append({"role": role, "content": content})

    return out


def _generate_blocking(
    loaded,
    model: BigBroModel,
    messages: list[dict[str, Any]],
    tools: list[dict[str, Any]],
    options: dict[str, Any] | None,
    context: dict[str, Any],
):
    """Yields decoded text chunks. Runs on a worker thread, never the event loop."""
    kwargs = generation_kwargs(options)
    seed = kwargs.pop("_seed", None)
    sampler_args = kwargs.pop("_sampler_args", None)
    repetition_penalty = kwargs.pop("_repetition_penalty", None)

    if seed is not None:
        import mlx.core as mx
        mx.random.seed(seed)

    if model.family is Family.VISION:
        yield from _generate_vision(loaded, messages, kwargs)
        return

    from mlx_lm import stream_generate
    from mlx_lm.sample_utils import make_logits_processors, make_sampler

    lm_model, tokenizer = loaded
    prompt = tokenizer.apply_chat_template(
        _chat_messages(messages),
        tools=tools or None,
        add_generation_prompt=True,
        tokenize=False,
        **context,
    )

    if sampler_args:
        kwargs["sampler"] = make_sampler(**sampler_args)
    if repetition_penalty is not None:
        kwargs["logits_processors"] = make_logits_processors(repetition_penalty=repetition_penalty)

    for response in stream_generate(lm_model, tokenizer, prompt, **kwargs):
        if response.text:
            yield response.text


def _generate_vision(loaded, messages: list[dict[str, Any]], kwargs: dict[str, Any]):
    from mlx_vlm import stream_generate as vlm_stream_generate
    from mlx_vlm.prompt_utils import apply_chat_template as vlm_apply_chat_template

    vlm_model, processor = loaded
    images = decode_images(messages)
    config = getattr(vlm_model, "config", None)
    prompt = vlm_apply_chat_template(
        processor, config, _chat_messages(messages), num_images=len(images)
    )

    for response in vlm_stream_generate(vlm_model, processor, prompt, images, **kwargs):
        text = getattr(response, "text", response)
        if text:
            yield text


__all__ = [
    "MLXEngine",
    "RunState",
    "ResolvedRequest",
    "InferenceError",
    "ModelNotSpecified",
    "UnknownModel",
    "ModelCannotSeeImages",
    "InvalidImage",
    "template_context",
    "generation_kwargs",
    "Delta",
    "Reasoning",
    "ToolCall",
]
