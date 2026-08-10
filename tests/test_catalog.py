"""Catalog tests.

The three hand-verified facts per model are the whole value of this list, and a wrong
one corrupts responses rather than failing. These tests pin the invariants that
protect them, plus the loose name resolution older clients depend on.
"""

from __future__ import annotations

import pytest

from bigbro.inference.catalog import (
    ALL_MODELS,
    Family,
    ReasoningStyle,
    model,
    resolve,
)
from bigbro.inference.parsers import HarmonyStreamParser, PlainTextParser, ThinkTagParser


def test_ids_are_unique():
    ids = [m.id for m in ALL_MODELS]
    assert len(ids) == len(set(ids))


def test_every_model_has_a_repo():
    """`owner/name`, and MLX-format weights.

    Not pinned to `mlx-community/` any more: Bonsai's ternary weights are published in
    MLX form by the model's own authors and have no mlx-community mirror, so requiring
    that one owner would mean either shipping a worse conversion or not shipping it.
    What actually has to hold is that the repo is a well-formed Hub id — `bigbro models
    check` is what confirms each one resolves.
    """
    for m in ALL_MODELS:
        owner, _, name = m.repo.partition("/")
        assert owner and name and "/" not in name, m.repo


@pytest.mark.parametrize("name,expected", [
    ("gpt-oss-20b", "gpt-oss-20b"),
    ("gpt-oss:20b", "gpt-oss-20b"),     # Ollama-style tag from an older client
    ("gpt_oss_20b", "gpt-oss-20b"),
    ("GPT-OSS-20B", "gpt-oss-20b"),
    ("qwen3-8b", "qwen3-8b"),
    ("llama-3.2-1b", "llama-3.2-1b"),
    ("qwen2.5-vl-3b", "qwen2.5-vl-3b"),
    ("qwen3.6-35b-a3b", "qwen3.6-35b-a3b"),
    ("qwen3.6-35b", "qwen3.6-35b-a3b"),          # prefix: the A3B suffix is optional
    ("bonsai-27b-ternary", "bonsai-27b-ternary"),
    ("bonsai_27b_ternary", "bonsai-27b-ternary"),
])
def test_resolve_folds_the_punctuation_clients_vary_on(name, expected):
    resolved = resolve(name)
    assert resolved is not None and resolved.id == expected


@pytest.mark.parametrize("name", ["", "not-a-model", "gpt-4", "llama-99b", "   "])
def test_resolve_returns_none_rather_than_substituting(name):
    """No default, no fallback: a wrong model answering is worse than an error."""
    assert resolve(name) is None


def test_exact_match_wins_over_prefix_match():
    """`qwen3-4b` must not resolve to `qwen3-4b`-prefixed anything else."""
    assert resolve("qwen3-4b").id == "qwen3-4b"
    assert resolve("qwen3-8b").id == "qwen3-8b"


def test_only_vision_models_accept_images():
    for entry in ALL_MODELS:
        assert entry.supports_images == (entry.family is Family.VISION)


def test_reasoning_effort_is_harmony_only():
    """`reasoning_effort` renders into the prompt — offering it elsewhere is a lie."""
    for entry in ALL_MODELS:
        assert entry.reasoning.accepts_effort == (entry.reasoning is ReasoningStyle.HARMONY)


def test_only_reasoning_models_produce_a_trace():
    for entry in ALL_MODELS:
        assert entry.reasoning.produces_trace == (entry.reasoning is not ReasoningStyle.NONE)


@pytest.mark.parametrize("model_id,parser_type", [
    ("gpt-oss-20b", HarmonyStreamParser),
    ("qwen3-8b", ThinkTagParser),
    ("deepseek-r1-7b", ThinkTagParser),
    ("llama-3.2-1b", PlainTextParser),
    ("gemma-3-1b", PlainTextParser),
    ("phi-3.5-mini", PlainTextParser),
    ("qwen3.6-35b-a3b", ThinkTagParser),
    ("bonsai-27b-ternary", ThinkTagParser),
])
def test_reasoning_style_selects_the_matching_parser(model_id, parser_type):
    """A model's reasoning style *is* its output framing — the pairing is fixed."""
    entry = model(model_id)
    assert entry is not None
    assert isinstance(entry.reasoning.make_parser(), parser_type)


def test_gemma_and_phi_have_no_tool_support():
    """Their chat templates have no tools slot; claiming otherwise throws at render."""
    for model_id in ("gemma-4-e4b", "gemma-4-e2b", "gemma-3-1b", "phi-3.5-mini"):
        assert model(model_id).supports_tools is False


def test_qwen3_5_architecture_models_run_text_only():
    """Both ship a vision tower; both are LANGUAGE on purpose.

    mlx-lm strips the vision weights and keeps the tools slot and `enable_thinking`.
    Filing either under VISION would route it through mlx-vlm, which templates without
    tools and without a template context — so this pins the decision, not the loader.
    """
    for model_id in ("qwen3.6-35b-a3b", "bonsai-27b-ternary"):
        entry = model(model_id)
        assert entry.family is Family.LANGUAGE
        assert entry.supports_images is False
        assert entry.supports_tools is True
        assert entry.reasoning.togglable is True


def test_deepseek_reasoning_is_not_togglable():
    """The R1 distills always reason — unlike Qwen3, whose template takes a flag."""
    assert model("deepseek-r1-7b").reasoning is ReasoningStyle.THINK_TAGS_ALWAYS
    assert model("deepseek-r1-7b").reasoning.togglable is False
    assert model("qwen3-8b").reasoning.togglable is True
