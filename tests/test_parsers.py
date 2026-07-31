"""Parser tests — the highest-risk part of the port.

Getting output framing wrong does not fail loudly, it silently mangles responses:
reasoning leaks into the spoken answer, or the opening of every reply is swallowed.
These tests feed the streams one character at a time as well as whole, because a
parser that only works on complete input is a parser that works in tests and fails
on a real token stream.
"""

from __future__ import annotations

import pytest

from bigbro.inference.parsers import (
    Delta,
    HarmonyStreamParser,
    PlainTextParser,
    Reasoning,
    ThinkTagParser,
    ToolCall,
    _longest_suffix_that_could_start,
)


def drain(parser, text: str, chunk_size: int | None = None) -> list:
    """Feeds `text` through a parser, optionally split into fixed-size chunks."""
    events = []
    if chunk_size is None:
        events.extend(parser.feed(text))
    else:
        for start in range(0, len(text), chunk_size):
            events.extend(parser.feed(text[start:start + chunk_size]))
    events.extend(parser.finish())
    return events


def text_of(events, kind) -> str:
    return "".join(e.text for e in events if isinstance(e, kind))


# MARK: - Plain


def test_plain_passes_everything_through_as_answer():
    events = drain(PlainTextParser(), "Hello, world.")
    assert text_of(events, Delta) == "Hello, world."
    assert text_of(events, Reasoning) == ""


def test_plain_never_withholds_the_first_token():
    """A buffered first token delays the first audible word of a spoken reply."""
    parser = PlainTextParser()
    assert parser.feed("H") == [Delta("H")]


def test_plain_ignores_empty_feeds():
    assert PlainTextParser().feed("") == []


# MARK: - Think tags


@pytest.mark.parametrize("chunk_size", [None, 1, 3, 7])
def test_think_tags_split_reasoning_from_answer(chunk_size):
    raw = "<think>Let me count.</think>The answer is 4."
    events = drain(ThinkTagParser(), raw, chunk_size)
    assert text_of(events, Reasoning) == "Let me count."
    assert text_of(events, Delta) == "The answer is 4."


def test_think_tag_split_across_chunks_does_not_leak():
    """A tag straddling two chunks must not emit `<thi` as answer text."""
    parser = ThinkTagParser()
    first = parser.feed("<thi")
    assert first == [], f"leaked partial tag: {first}"
    events = first + parser.feed("nk>reasoning</think>answer") + parser.finish()
    assert text_of(events, Reasoning) == "reasoning"
    assert text_of(events, Delta) == "answer"


def test_think_tags_stream_incrementally_without_waiting_for_close():
    """Reasoning is displayed as it arrives, so it must not be held to the close tag."""
    parser = ThinkTagParser()
    parser.feed("<think>")
    events = parser.feed("partial reasoning")
    assert text_of(events, Reasoning) == "partial reasoning"


def test_literal_think_tag_after_the_block_is_content_not_markup():
    raw = "<think>thinking</think>Use the <think> tag to reason."
    events = drain(ThinkTagParser(), raw)
    assert text_of(events, Reasoning) == "thinking"
    assert text_of(events, Delta) == "Use the <think> tag to reason."


def test_think_parser_handles_output_with_no_tags_at_all():
    events = drain(ThinkTagParser(), "Just an answer.")
    assert text_of(events, Delta) == "Just an answer."
    assert text_of(events, Reasoning) == ""


def test_unterminated_think_block_flushes_as_reasoning():
    """A generation cut short mid-thought should not silently drop the partial trace."""
    events = drain(ThinkTagParser(), "<think>cut off mid-thou")
    assert text_of(events, Reasoning) == "cut off mid-thou"
    assert text_of(events, Delta) == ""


@pytest.mark.parametrize(
    "tag,text,expected",
    [
        ("<think>", "abc<thi", 4),
        ("<think>", "abc", 0),
        ("<think>", "<", 1),
        ("<think>", "", 0),
        ("</think>", "text</", 2),
    ],
)
def test_longest_suffix_that_could_start(tag, text, expected):
    assert _longest_suffix_that_could_start(tag, text) == expected


# MARK: - Harmony


HARMONY_SIMPLE = (
    "<|channel|>analysis<|message|>Working it out.<|end|>"
    "<|channel|>final<|message|>The answer is 4."
)


@pytest.mark.parametrize("chunk_size", [None, 1, 5, 13])
def test_harmony_splits_analysis_from_final(chunk_size):
    events = drain(HarmonyStreamParser(), HARMONY_SIMPLE, chunk_size)
    assert text_of(events, Reasoning) == "Working it out."
    assert text_of(events, Delta) == "The answer is 4."


def test_harmony_extracts_tool_calls_from_commentary():
    raw = (
        "<|channel|>analysis<|message|>Need the weather.<|end|>"
        '<|channel|>commentary to=functions.get_weather <|constrain|>json<|message|>'
        '{"city":"Tokyo"}<|call|>'
    )
    events = drain(HarmonyStreamParser(), raw)
    calls = [e for e in events if isinstance(e, ToolCall)]
    assert len(calls) == 1
    assert calls[0].name == "get_weather"
    assert calls[0].to_wire()["function"]["arguments"] == {"city": "Tokyo"}


def test_harmony_never_emits_partial_tool_call_arguments():
    """Half a JSON object is worse than none — the client would parse garbage."""
    parser = HarmonyStreamParser()
    parser.feed('<|channel|>commentary to=functions.f <|message|>{"a":')
    assert [e for e in parser.feed("1") if isinstance(e, ToolCall)] == []
    calls = [e for e in parser.feed("}") + parser.finish() if isinstance(e, ToolCall)]
    assert len(calls) == 1
    assert calls[0].to_wire()["function"]["arguments"] == {"a": 1}


def test_harmony_drops_bare_commentary():
    """Commentary with no `to=functions.X` is preamble, not a call and not the answer."""
    raw = (
        "<|channel|>commentary<|message|>I'll check that.<|end|>"
        "<|channel|>final<|message|>Done."
    )
    events = drain(HarmonyStreamParser(), raw)
    assert [e for e in events if isinstance(e, ToolCall)] == []
    assert text_of(events, Delta) == "Done."


def test_harmony_falls_back_to_plain_text_when_markers_are_stripped():
    """If a future mlx-lm strips harmony tokens, the reply must still reach the client.

    Losing the reasoning/final split is bad; swallowing the entire response is worse.
    """
    plain = "x" * HarmonyStreamParser.PLAIN_TEXT_FALLBACK_THRESHOLD
    events = drain(HarmonyStreamParser(), plain)
    assert text_of(events, Delta) == plain


def test_harmony_holds_short_output_rather_than_guessing():
    """Below the threshold it keeps waiting — real harmony output opens with a tag."""
    parser = HarmonyStreamParser()
    assert parser.feed("short") == []


def test_harmony_streams_final_text_before_the_terminator_arrives():
    parser = HarmonyStreamParser()
    parser.feed("<|channel|>final<|message|>")
    events = parser.feed("streaming as it comes")
    assert text_of(events, Delta) == "streaming as it comes"


def test_harmony_header_split_across_chunks():
    parser = HarmonyStreamParser()
    assert parser.feed("<|channel|>anal") == []
    events = parser.feed("ysis<|message|>thinking") + parser.finish()
    assert text_of(events, Reasoning) == "thinking"


def test_harmony_unrecognized_channel_is_treated_as_final():
    """An unknown channel name must not lose its content."""
    events = drain(HarmonyStreamParser(), "<|channel|>mystery<|message|>content here")
    assert text_of(events, Delta) == "content here"


def test_harmony_return_terminator_ends_the_final_channel():
    raw = "<|channel|>final<|message|>Answer.<|return|>"
    events = drain(HarmonyStreamParser(), raw)
    assert text_of(events, Delta) == "Answer."


def test_tool_call_with_invalid_json_arguments_degrades_to_empty():
    call = ToolCall("f", "{not json")
    assert call.to_wire()["function"]["arguments"] == {}
    assert call.to_wire()["function"]["name"] == "f"
