"""The models BigBro offers, and the facts about them that change behaviour.

A curated subset of what MLX can run rather than all of it. Every entry here has had
its capabilities checked by hand, and that is the whole value of the list — an
automatically-derived catalog would have to guess at tool support and reasoning
style, and a wrong guess corrupts responses rather than failing. Adding a model is a
deliberate act: add the entry, verify the three fields.

| Fact             | Why it can't be guessed                                          |
|------------------|------------------------------------------------------------------|
| Tool support     | Whether the chat template has a tools slot at all. Gemma and Phi don't. |
| Reasoning style  | None (Gemma, Llama), harmony channels (gpt-oss), or `<think>` tags (Qwen3, DeepSeek-R1). |
| Effort control   | `reasoning_effort` is harmony-only; Qwen3's lever is `enable_thinking`, a different key. |

`repo` replaces the `ModelConfiguration` constant the Swift catalog used. Run
`bigbro models check` to confirm every id here resolves on the Hub.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum

from .parsers import HarmonyStreamParser, PlainTextParser, ResponseParser, ThinkTagParser


class Family(str, Enum):
    """Which loader handles the model. Vision models accept images; language ones do not."""
    LANGUAGE = "language"
    VISION = "vision"


class ReasoningStyle(str, Enum):
    """How a model exposes its reasoning, if it has any.

    This is not cosmetic — it decides three separate things per model: what (if
    anything) can be put in the chat template to control thinking, how the raw token
    stream has to be parsed back apart, and whether a `reasoning_effort` from the
    client means anything at all. Getting it wrong on a given model does not fail
    loudly; it silently mangles the response.
    """

    #: No reasoning phase. Output is the answer, start to finish. Gemma, Llama, Phi.
    NONE = "none"

    #: OpenAI harmony channels — `<|channel|>analysis ... <|channel|>final`. Effort is
    #: set by putting `reasoning_effort` (low/medium/high) in the template context,
    #: which renders as `Reasoning: <level>` in the system message. gpt-oss.
    HARMONY = "harmony"

    #: A `<think>…</think>` block ahead of the answer, where the chat template accepts
    #: `enable_thinking` — a genuine on/off, unlike harmony where the model always reasons.
    THINK_TAGS_TOGGLABLE = "think_tags_togglable"

    #: A `<think>…</think>` block with no off switch. The DeepSeek-R1 distills.
    THINK_TAGS_ALWAYS = "think_tags_always"

    @property
    def accepts_effort(self) -> bool:
        """Whether the client's `reasoning_effort` can be honoured at all."""
        return self is ReasoningStyle.HARMONY

    @property
    def produces_trace(self) -> bool:
        """Whether the model produces a reasoning trace worth forwarding as `thinking`."""
        return self is not ReasoningStyle.NONE

    @property
    def togglable(self) -> bool:
        return self is ReasoningStyle.THINK_TAGS_TOGGLABLE

    def make_parser(self) -> ResponseParser:
        """The parser this style needs. The pairing is fixed — a model's reasoning
        style *is* its output framing."""
        if self is ReasoningStyle.HARMONY:
            return HarmonyStreamParser()
        if self in (ReasoningStyle.THINK_TAGS_TOGGLABLE, ReasoningStyle.THINK_TAGS_ALWAYS):
            return ThinkTagParser()
        return PlainTextParser()


@dataclass(frozen=True)
class BigBroModel:
    #: Stable key. This is what a client names in `model`, what the daemon persists, and
    #: what download progress is reported against — deliberately not the Hugging Face
    #: repo id, which is long and version-specific.
    id: str
    display_name: str
    family: Family
    reasoning: ReasoningStyle
    #: Whether the model was trained for function calling *and* its chat template has a
    #: slot for tool definitions. False means tools must be dropped before templating.
    supports_tools: bool
    #: Rough download size in GB, for `bigbro models list`. Approximate by nature:
    #: quantized weights vary by a few hundred MB between revisions.
    approximate_gb: float
    #: The Hugging Face repo the weights come from.
    repo: str

    @property
    def supports_images(self) -> bool:
        return self.family is Family.VISION


LANGUAGE_MODELS: tuple[BigBroModel, ...] = (
    BigBroModel(
        id="gpt-oss-20b",
        display_name="gpt-oss 20B",
        family=Family.LANGUAGE,
        reasoning=ReasoningStyle.HARMONY,
        supports_tools=True,
        approximate_gb=12,
        repo="mlx-community/gpt-oss-20b-MXFP4-Q8",
    ),
    BigBroModel(
        id="qwen3-8b",
        display_name="Qwen3 8B",
        family=Family.LANGUAGE,
        # Qwen3's template takes `enable_thinking`, so thinking is genuinely optional
        # here in a way it is not for gpt-oss.
        reasoning=ReasoningStyle.THINK_TAGS_TOGGLABLE,
        supports_tools=True,
        approximate_gb=4.7,
        repo="mlx-community/Qwen3-8B-4bit",
    ),
    BigBroModel(
        id="qwen3-4b",
        display_name="Qwen3 4B",
        family=Family.LANGUAGE,
        reasoning=ReasoningStyle.THINK_TAGS_TOGGLABLE,
        supports_tools=True,
        approximate_gb=2.4,
        repo="mlx-community/Qwen3-4B-4bit",
    ),
    BigBroModel(
        id="llama-3.1-8b",
        display_name="Llama 3.1 8B",
        family=Family.LANGUAGE,
        reasoning=ReasoningStyle.NONE,
        supports_tools=True,
        approximate_gb=4.5,
        repo="mlx-community/Meta-Llama-3.1-8B-Instruct-4bit",
    ),
    BigBroModel(
        id="llama-3.2-3b",
        display_name="Llama 3.2 3B",
        family=Family.LANGUAGE,
        reasoning=ReasoningStyle.NONE,
        supports_tools=True,
        approximate_gb=1.8,
        repo="mlx-community/Llama-3.2-3B-Instruct-4bit",
    ),
    BigBroModel(
        id="llama-3.2-1b",
        display_name="Llama 3.2 1B",
        family=Family.LANGUAGE,
        reasoning=ReasoningStyle.NONE,
        supports_tools=True,
        approximate_gb=0.7,
        repo="mlx-community/Llama-3.2-1B-Instruct-4bit",
    ),
    BigBroModel(
        id="gemma-4-e4b",
        display_name="Gemma 4 E4B",
        family=Family.LANGUAGE,
        reasoning=ReasoningStyle.NONE,
        # Gemma's chat template has no tools slot. Passing tool definitions anyway
        # either throws in the template or drops them silently — neither is useful.
        supports_tools=False,
        approximate_gb=4.4,
        repo="mlx-community/gemma-3n-E4B-it-4bit",
    ),
    BigBroModel(
        id="gemma-4-e2b",
        display_name="Gemma 4 E2B",
        family=Family.LANGUAGE,
        reasoning=ReasoningStyle.NONE,
        supports_tools=False,
        approximate_gb=3.0,
        repo="mlx-community/gemma-3n-E2B-it-4bit",
    ),
    BigBroModel(
        id="gemma-3-1b",
        display_name="Gemma 3 1B",
        family=Family.LANGUAGE,
        reasoning=ReasoningStyle.NONE,
        supports_tools=False,
        approximate_gb=0.8,
        repo="mlx-community/gemma-3-1b-it-qat-4bit",
    ),
    BigBroModel(
        id="phi-3.5-mini",
        display_name="Phi 3.5 Mini",
        family=Family.LANGUAGE,
        reasoning=ReasoningStyle.NONE,
        supports_tools=False,
        approximate_gb=2.2,
        repo="mlx-community/Phi-3.5-mini-instruct-4bit",
    ),
    BigBroModel(
        id="deepseek-r1-7b",
        display_name="DeepSeek-R1 Distill 7B",
        family=Family.LANGUAGE,
        # Always reasons — the distills have no off switch, unlike Qwen3 proper.
        reasoning=ReasoningStyle.THINK_TAGS_ALWAYS,
        supports_tools=False,
        approximate_gb=4.2,
        repo="mlx-community/DeepSeek-R1-Distill-Qwen-7B-4bit",
    ),
)

VISION_MODELS: tuple[BigBroModel, ...] = (
    BigBroModel(
        id="qwen2.5-vl-3b",
        display_name="Qwen2.5-VL 3B",
        family=Family.VISION,
        reasoning=ReasoningStyle.NONE,
        supports_tools=False,
        approximate_gb=2.0,
        repo="mlx-community/Qwen2.5-VL-3B-Instruct-4bit",
    ),
    BigBroModel(
        id="qwen3-vl-4b",
        display_name="Qwen3-VL 4B",
        family=Family.VISION,
        reasoning=ReasoningStyle.NONE,
        supports_tools=False,
        approximate_gb=2.5,
        repo="mlx-community/Qwen3-VL-4B-Instruct-4bit",
    ),
    BigBroModel(
        id="gemma-3-4b-vision",
        display_name="Gemma 3 4B (vision)",
        family=Family.VISION,
        reasoning=ReasoningStyle.NONE,
        supports_tools=False,
        approximate_gb=3.0,
        repo="mlx-community/gemma-3-4b-it-qat-4bit",
    ),
    BigBroModel(
        id="gemma-4-e2b-vision",
        display_name="Gemma 4 E2B (vision)",
        family=Family.VISION,
        reasoning=ReasoningStyle.NONE,
        supports_tools=False,
        approximate_gb=3.0,
        repo="mlx-community/gemma-3n-E2B-it-4bit",
    ),
)

ALL_MODELS: tuple[BigBroModel, ...] = LANGUAGE_MODELS + VISION_MODELS


def _normalize(name: str) -> str:
    """Folds the punctuation clients vary on — `gpt-oss:20b`, `gpt_oss_20b` and
    `gpt-oss-20b` all collapse to the same key."""
    return "".join(c for c in name.lower() if c.isalnum())


def model(model_id: str) -> BigBroModel | None:
    return next((m for m in ALL_MODELS if m.id == model_id), None)


def resolve(name: str) -> BigBroModel | None:
    """Resolves a name a client sent in `model` to a catalog entry.

    Exact id first. Failing that, a loose match, because clients predate this catalog
    and send Ollama-style tags — `gpt-oss:20b` for `gpt-oss-20b`. Returns None for a
    name that matches nothing, which callers report back as an error: BigBro has no
    default to fall back to, and answering a request for a model this Mac has never
    heard of with some *other* model would be a silent substitution the client could
    not detect.
    """
    if not name:
        return None
    normalized = _normalize(name)
    if not normalized:
        return None

    for candidate in ALL_MODELS:
        if _normalize(candidate.id) == normalized:
            return candidate
    for candidate in ALL_MODELS:
        candidate_key = _normalize(candidate.id)
        if candidate_key.startswith(normalized) or normalized.startswith(candidate_key):
            return candidate
    return None
