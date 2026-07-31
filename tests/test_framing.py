"""Wire codec tests.

The framing is the one thing that absolutely cannot change in this port: every
existing BigBroKit build speaks it. These tests pin the byte layout, not just the
round trip.
"""

from __future__ import annotations

import json

import pytest

from bigbro.protocol.framing import FrameDecoder, encode


def test_frame_layout_is_four_byte_big_endian_length_then_json():
    frame = encode({"type": "ping"})
    length = int.from_bytes(frame[:4], "big")
    assert length == len(frame) - 4
    assert json.loads(frame[4:]) == {"type": "ping"}


def test_round_trip():
    message = {"type": "chunk", "requestId": "abc", "delta": "hello"}
    assert FrameDecoder().feed(encode(message)) == [message]


def test_several_frames_in_one_read():
    payload = encode({"type": "a"}) + encode({"type": "b"}) + encode({"type": "c"})
    assert [m["type"] for m in FrameDecoder().feed(payload)] == ["a", "b", "c"]


def test_frame_split_across_reads():
    frame = encode({"type": "hello", "deviceId": "d1"})
    decoder = FrameDecoder()
    assert decoder.feed(frame[:3]) == []      # not even the length prefix yet
    assert decoder.feed(frame[3:9]) == []     # partial body
    assert decoder.feed(frame[9:]) == [{"type": "hello", "deviceId": "d1"}]


def test_byte_at_a_time_delivery():
    frame = encode({"type": "done", "requestId": "r1"})
    decoder = FrameDecoder()
    messages = []
    for index in range(len(frame)):
        messages.extend(decoder.feed(frame[index:index + 1]))
    assert messages == [{"type": "done", "requestId": "r1"}]


def test_trailing_partial_frame_is_held_not_dropped():
    complete = encode({"type": "a"})
    partial = encode({"type": "b"})[:5]
    decoder = FrameDecoder()
    assert [m["type"] for m in decoder.feed(complete + partial)] == ["a"]


def test_unicode_survives_the_round_trip():
    message = {"type": "chunk", "delta": "こんにちは 🎉 café"}
    assert FrameDecoder().feed(encode(message)) == [message]


def test_malformed_json_is_skipped_without_killing_the_connection():
    """One bad frame should not tear down a connection that is otherwise fine."""
    bad = b"\x00\x00\x00\x05" + b"{not!"
    good = encode({"type": "ok"})
    assert [m["type"] for m in FrameDecoder().feed(bad + good)] == ["ok"]


def test_non_object_json_is_skipped():
    array = json.dumps([1, 2, 3]).encode()
    payload = len(array).to_bytes(4, "big") + array + encode({"type": "ok"})
    assert [m["type"] for m in FrameDecoder().feed(payload)] == ["ok"]


def test_absurd_length_prefix_is_rejected():
    """A desync or hostile peer must not be able to make us buffer unboundedly."""
    with pytest.raises(ValueError, match="exceeds"):
        FrameDecoder().feed(b"\xff\xff\xff\xff" + b"x")


def test_empty_body_frame():
    payload = (0).to_bytes(4, "big") + encode({"type": "after"})
    assert [m["type"] for m in FrameDecoder().feed(payload)] == ["after"]
