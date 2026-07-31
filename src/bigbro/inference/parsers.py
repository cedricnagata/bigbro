"""Turns a model's raw token stream back into the three things the router forwards.

Necessary because models disagree about how to mark up a response, and the generator
hands over whatever the tokenizer decoded without interpreting it. gpt-oss writes
harmony channel markers, Qwen3 writes `<think>` tags, Gemma and Llama write the
answer and nothing else. One parser cannot serve all three: running the harmony
parser over plain output withholds the opening of every reply while it waits for
framing that never comes.
"""

from __future__ import annotations

import json
import uuid
from dataclasses import dataclass
from typing import Protocol, Union


@dataclass(frozen=True)
class Reasoning:
    """A slice of the model's chain of thought."""
    text: str


@dataclass(frozen=True)
class Delta:
    """A slice of the answer the user sees."""
    text: str


@dataclass(frozen=True)
class ToolCall:
    name: str
    arguments_json: str

    def to_wire(self) -> dict:
        """The OpenAI-shaped tool call the `toolCall` message carries.

        Arguments that are not valid JSON become `{}` rather than raising — a
        truncated call is better delivered empty than not at all, since the client
        can see the name and recover.
        """
        try:
            arguments = json.loads(self.arguments_json) if self.arguments_json.strip() else {}
        except json.JSONDecodeError:
            arguments = {}
        if not isinstance(arguments, dict):
            arguments = {}
        return {
            "id": f"call_{uuid.uuid4().hex[:8]}",
            "type": "function",
            "function": {"name": self.name, "arguments": arguments},
        }


ParsedEvent = Union[Reasoning, Delta, ToolCall]


class ResponseParser(Protocol):
    def feed(self, text: str) -> list[ParsedEvent]:
        """Feed newly-decoded text. Returns whatever became complete."""
        ...

    def finish(self) -> list[ParsedEvent]:
        """Call once generation ends. Flushes anything still buffered."""
        ...


class PlainTextParser:
    """Pass-through, for models with no reasoning phase and no channel markup.

    Not merely a simplification — it is the correct behaviour. Everything the model
    emits is the answer, so buffering any of it only delays the first token, which
    for a spoken reply delays the first audible word.
    """

    def feed(self, text: str) -> list[ParsedEvent]:
        return [Delta(text)] if text else []

    def finish(self) -> list[ParsedEvent]:
        return []


def _longest_suffix_that_could_start(tag: str, text: str) -> int:
    """Length of the longest suffix of `text` that is a prefix of `tag`.

    This is what stops a tag split across two chunks from leaking. Without it, text
    ending in `<thi` would be emitted as answer text and the `<think>` that completes
    on the next chunk would never be recognized.
    """
    max_overlap = min(len(tag) - 1, len(text))
    for length in range(max_overlap, 0, -1):
        if tag.startswith(text[-length:]):
            return length
    return 0


def _longest_suffix_that_could_start_any(tags, text: str) -> int:
    """The same, across several possible tags — the widest tail that must be held back."""
    return max((_longest_suffix_that_could_start(tag, text) for tag in tags), default=0)


class ThinkTagParser:
    """Splits a leading `<think>…</think>` block off the answer. Qwen3, DeepSeek-R1.

    Text inside the tags is streamed as reasoning and text after them as answer, both
    incrementally — neither is held back waiting for a close tag, since the client
    renders both as they arrive.
    """

    OPEN_TAG = "<think>"
    CLOSE_TAG = "</think>"

    def __init__(self) -> None:
        self._buffer = ""
        self._inside = False
        # Once the think block has closed, tag scanning stops: a later literal
        # `<think>` in prose is content, not markup.
        self._finished_thinking = False

    def feed(self, text: str) -> list[ParsedEvent]:
        self._buffer += text
        return self._drain(is_final=False)

    def finish(self) -> list[ParsedEvent]:
        events = self._drain(is_final=True)
        if self._buffer:
            events.append(Reasoning(self._buffer) if self._inside else Delta(self._buffer))
            self._buffer = ""
        return events

    def _emit(self, text: str) -> ParsedEvent:
        return Reasoning(text) if self._inside else Delta(text)

    def _drain(self, is_final: bool) -> list[ParsedEvent]:
        events: list[ParsedEvent] = []

        while self._buffer:
            if self._finished_thinking:
                events.append(Delta(self._buffer))
                self._buffer = ""
                break

            tag = self.CLOSE_TAG if self._inside else self.OPEN_TAG
            index = self._buffer.find(tag)

            if index != -1:
                before = self._buffer[:index]
                if before:
                    events.append(self._emit(before))
                self._buffer = self._buffer[index + len(tag):]
                if self._inside:
                    self._inside = False
                    self._finished_thinking = True
                else:
                    self._inside = True
                continue

            # No tag in view. Emit everything that cannot be the start of one and keep
            # the tail, which may be a tag straddling this chunk and the next.
            keep = _longest_suffix_that_could_start(tag, self._buffer)
            emit_count = len(self._buffer) - keep
            if emit_count > 0:
                events.append(self._emit(self._buffer[:emit_count]))
                self._buffer = self._buffer[emit_count:]
            if is_final:
                break
            return events

        return events


class HarmonyStreamParser:
    """Incrementally splits gpt-oss's harmony response format out of a raw text stream.

    gpt-oss (like every OpenAI "harmony" model) writes its output as a sequence of
    channel blocks rather than plain text:

        <|channel|>analysis<|message|>...chain of thought...<|end|>
        <|channel|>final<|message|>...the reply the user sees...
        <|channel|>commentary to=functions.NAME <|constrain|>json<|message|>{...}<|call|>

    This depends on gpt-oss's special tokens surviving detokenization as literal text.
    If a generator strips them before they reach us, this parser sees no `<|channel|>`
    markers at all and falls back to treating everything as plain final-channel text
    (see `PLAIN_TEXT_FALLBACK_THRESHOLD`) rather than silently swallowing the whole
    response.
    """

    CHANNEL_TAG = "<|channel|>"
    MESSAGE_TAG = "<|message|>"
    TERMINATORS = ("<|end|>", "<|call|>", "<|return|>", "<|start|>")

    # If this many characters accumulate with no channel tag ever seen, give up on
    # harmony framing and pass everything through as plain final-channel text.
    PLAIN_TEXT_FALLBACK_THRESHOLD = 200

    _ANALYSIS = "analysis"
    _FINAL = "final"

    def __init__(self) -> None:
        self._buffer = ""
        # None when between blocks; otherwise ("analysis"|"final"|"commentary", recipient)
        self._channel: tuple[str, str | None] | None = None
        self._saw_channel_tag = False
        self._abandoned_framing = False

    def feed(self, text: str) -> list[ParsedEvent]:
        self._buffer += text
        return self._drain(is_final=False)

    def finish(self) -> list[ParsedEvent]:
        return self._drain(is_final=True)

    def _first_terminator(self) -> int:
        positions = [i for i in (self._buffer.find(t) for t in self.TERMINATORS) if i != -1]
        return min(positions) if positions else -1

    def _terminator_at(self, index: int) -> str:
        for terminator in self.TERMINATORS:
            if self._buffer.startswith(terminator, index):
                return terminator
        return ""

    def _drain(self, is_final: bool) -> list[ParsedEvent]:
        events: list[ParsedEvent] = []

        if self._abandoned_framing:
            if self._buffer:
                events.append(Delta(self._buffer))
                self._buffer = ""
            return events

        while True:
            if self._channel is None:
                index = self._buffer.find(self.CHANNEL_TAG)
                if index == -1:
                    if not self._saw_channel_tag and len(self._buffer) >= self.PLAIN_TEXT_FALLBACK_THRESHOLD:
                        self._abandoned_framing = True
                        events.append(Delta(self._buffer))
                        self._buffer = ""
                    break

                self._saw_channel_tag = True
                # Anything before the first channel tag isn't part of harmony framing —
                # in practice this is empty, since gpt-oss opens every turn with a tag.
                rest = self._buffer[index + len(self.CHANNEL_TAG):]

                message_index = rest.find(self.MESSAGE_TAG)
                if message_index == -1:
                    if is_final:
                        break
                    # Header hasn't fully arrived — wait for more text.
                    break

                header = rest[:message_index].strip()
                self._buffer = rest[message_index + len(self.MESSAGE_TAG):]
                self._channel = self._parse_header(header)
                continue

            kind, recipient = self._channel
            index = self._first_terminator()

            if kind in (self._ANALYSIS, self._FINAL):
                if index != -1:
                    content = self._buffer[:index]
                    if content:
                        events.append(Reasoning(content) if kind == self._ANALYSIS else Delta(content))
                    self._buffer = self._buffer[index + len(self._terminator_at(index)):]
                    self._channel = None
                    continue

                # Stream analysis/final text live rather than waiting for the
                # terminator — the client displays both incrementally as they arrive.
                #
                # All but the tail: a terminator can straddle two chunks, and emitting
                # a partial `<|end|>` would leak the marker into the answer and then
                # fail to recognize the terminator once it completes.
                keep = 0 if is_final else _longest_suffix_that_could_start_any(
                    self.TERMINATORS, self._buffer
                )
                emit = self._buffer[:len(self._buffer) - keep] if keep else self._buffer
                if emit:
                    events.append(Reasoning(emit) if kind == self._ANALYSIS else Delta(emit))
                    self._buffer = self._buffer[len(emit):]
                if is_final:
                    self._buffer = ""
                    self._channel = None
                return events

            # commentary
            if index != -1:
                content = self._buffer[:index]
                self._buffer = self._buffer[index + len(self._terminator_at(index)):]
                self._channel = None
                if recipient:
                    events.append(ToolCall(recipient, content))
                # Bare commentary (no `to=functions.X`) is user-visible preamble text,
                # not a function call — drop it rather than speaking it aloud, since it
                # isn't the model's final answer either.
                continue

            if is_final:
                content = self._buffer
                self._buffer = ""
                self._channel = None
                if recipient and content:
                    events.append(ToolCall(recipient, content))
                continue

            # Tool call arguments must be complete, valid JSON — never emit partial.
            return events

        return events

    @staticmethod
    def _parse_header(header: str) -> tuple[str, str | None]:
        if header.startswith("analysis"):
            return ("analysis", None)
        if header.startswith("final"):
            return ("final", None)
        if header.startswith("commentary"):
            marker = "to=functions."
            index = header.find(marker)
            if index != -1:
                rest = header[index + len(marker):]
                name = ""
                for char in rest:
                    if char.isspace() or char == "<":
                        break
                    name += char
                return ("commentary", name or None)
            return ("commentary", None)
        # Unrecognized channel name — treat as final so the content isn't lost.
        return ("final", None)
