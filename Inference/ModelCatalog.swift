import Foundation
import MLXLMCommon
import MLXLLM
import MLXVLM

/// How a model exposes its reasoning, if it has any.
///
/// This is not cosmetic — it decides three separate things per model: what (if anything) can
/// be put in the chat template to control thinking, how the raw token stream has to be parsed
/// back apart, and whether a `reasoning_effort` from the client means anything at all. Getting
/// it wrong on a given model does not fail loudly; it silently mangles the response, which is
/// why it lives in the catalog next to the model rather than being sniffed at runtime.
enum ReasoningStyle: Sendable, Equatable {
    /// No reasoning phase. Output is the answer, start to finish. Gemma, Llama, Phi.
    case none

    /// OpenAI harmony channels — `<|channel|>analysis ... <|channel|>final`. Effort is set by
    /// putting `reasoning_effort` (low/medium/high) in the template context, which renders as
    /// `Reasoning: <level>` in the system message. gpt-oss.
    case harmony

    /// A `<think>…</think>` block ahead of the answer. Qwen3 and the DeepSeek-R1 distills.
    /// `togglable` is true where the chat template accepts `enable_thinking`, which is a
    /// genuine on/off — unlike harmony, where the model always reasons.
    case thinkTags(togglable: Bool)

    /// Whether the client's `reasoning_effort` can be honoured at all.
    var acceptsEffort: Bool { self == .harmony }

    /// Whether the model produces a reasoning trace worth forwarding as `thinking` messages.
    var producesTrace: Bool { self != .none }
}

/// One model BigBro can download and run, with the facts about it that change behaviour.
struct BigBroModel: Identifiable, Sendable, Hashable {
    /// Which factory loads it. Vision models go through `VLMModelFactory` and accept images;
    /// language models through `LLMModelFactory` and do not.
    enum Family: String, Sendable {
        case language
        case vision
    }

    /// Stable key. This is what a client names in `model`, what Settings persists, and what
    /// download progress is reported against — deliberately not the Hugging Face repo id,
    /// which is long and version-specific.
    let id: String
    let displayName: String
    let family: Family
    let reasoning: ReasoningStyle
    /// Whether the model was trained for function calling *and* its chat template has a slot
    /// for tool definitions. False means tools must be dropped before templating — see
    /// `MLXEngine.chatStream`.
    let supportsTools: Bool
    /// Rough download size, for the Settings list. Approximate by nature: quantized weights
    /// vary by a few hundred MB between revisions.
    let approximateGB: Double
    let configuration: ModelConfiguration

    var supportsImages: Bool { family == .vision }

    static func == (lhs: BigBroModel, rhs: BigBroModel) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// The models BigBro offers.
///
/// A curated subset of `LLMRegistry`/`VLMRegistry` rather than all of them. Every entry here
/// has had its capabilities checked by hand, and that is the whole value of the list — an
/// automatically-derived catalog would have to guess at tool support and reasoning style, and
/// a wrong guess corrupts responses rather than failing. Adding a model is a deliberate act:
/// add the entry, verify the three fields.
enum ModelCatalog {

    static let all: [BigBroModel] = language + vision

    // MARK: - Language

    static let language: [BigBroModel] = [
        BigBroModel(
            id: "gpt-oss-20b",
            displayName: "gpt-oss 20B",
            family: .language,
            reasoning: .harmony,
            supportsTools: true,
            approximateGB: 12,
            configuration: LLMRegistry.gpt_oss_20b_MXFP4_Q8
        ),
        BigBroModel(
            id: "qwen3-8b",
            displayName: "Qwen3 8B",
            family: .language,
            // Qwen3's template takes `enable_thinking`, so thinking is genuinely optional here
            // in a way it is not for gpt-oss.
            reasoning: .thinkTags(togglable: true),
            supportsTools: true,
            approximateGB: 4.7,
            configuration: LLMRegistry.qwen3_8b_4bit
        ),
        BigBroModel(
            id: "qwen3-4b",
            displayName: "Qwen3 4B",
            family: .language,
            reasoning: .thinkTags(togglable: true),
            supportsTools: true,
            approximateGB: 2.4,
            configuration: LLMRegistry.qwen3_4b_4bit
        ),
        BigBroModel(
            id: "llama-3.1-8b",
            displayName: "Llama 3.1 8B",
            family: .language,
            reasoning: .none,
            supportsTools: true,
            approximateGB: 4.5,
            configuration: LLMRegistry.llama3_1_8B_4bit
        ),
        BigBroModel(
            id: "llama-3.2-3b",
            displayName: "Llama 3.2 3B",
            family: .language,
            reasoning: .none,
            supportsTools: true,
            approximateGB: 1.8,
            configuration: LLMRegistry.llama3_2_3B_4bit
        ),
        BigBroModel(
            id: "llama-3.2-1b",
            displayName: "Llama 3.2 1B",
            family: .language,
            reasoning: .none,
            supportsTools: true,
            approximateGB: 0.7,
            configuration: LLMRegistry.llama3_2_1B_4bit
        ),
        BigBroModel(
            id: "gemma-4-e4b",
            displayName: "Gemma 4 E4B",
            family: .language,
            reasoning: .none,
            // Gemma's chat template has no tools slot. Passing tool definitions anyway either
            // throws in the template or drops them silently — neither is a useful outcome.
            supportsTools: false,
            approximateGB: 4.4,
            configuration: LLMRegistry.gemma4_e4b_it_4bit
        ),
        BigBroModel(
            id: "gemma-4-e2b",
            displayName: "Gemma 4 E2B",
            family: .language,
            reasoning: .none,
            supportsTools: false,
            approximateGB: 3.0,
            configuration: LLMRegistry.gemma4_e2b_it_4bit
        ),
        BigBroModel(
            id: "gemma-3-1b",
            displayName: "Gemma 3 1B",
            family: .language,
            reasoning: .none,
            supportsTools: false,
            approximateGB: 0.8,
            configuration: LLMRegistry.gemma3_1B_qat_4bit
        ),
        BigBroModel(
            id: "phi-3.5-mini",
            displayName: "Phi 3.5 Mini",
            family: .language,
            reasoning: .none,
            supportsTools: false,
            approximateGB: 2.2,
            configuration: LLMRegistry.phi3_5_4bit
        ),
        BigBroModel(
            id: "deepseek-r1-7b",
            displayName: "DeepSeek-R1 Distill 7B",
            family: .language,
            // Always reasons — the distills have no off switch, unlike Qwen3 proper.
            reasoning: .thinkTags(togglable: false),
            supportsTools: false,
            approximateGB: 4.2,
            configuration: LLMRegistry.deepSeekR1_7B_4bit
        ),
    ]

    // MARK: - Vision

    static let vision: [BigBroModel] = [
        BigBroModel(
            id: "qwen2.5-vl-3b",
            displayName: "Qwen2.5-VL 3B",
            family: .vision,
            reasoning: .none,
            supportsTools: false,
            approximateGB: 2.0,
            configuration: VLMRegistry.qwen2_5VL3BInstruct4Bit
        ),
        BigBroModel(
            id: "qwen3-vl-4b",
            displayName: "Qwen3-VL 4B",
            family: .vision,
            reasoning: .none,
            supportsTools: false,
            approximateGB: 2.5,
            configuration: VLMRegistry.qwen3VL4BInstruct4Bit
        ),
        BigBroModel(
            id: "gemma-3-4b-vision",
            displayName: "Gemma 3 4B (vision)",
            family: .vision,
            reasoning: .none,
            supportsTools: false,
            approximateGB: 3.0,
            configuration: VLMRegistry.gemma3_4B_qat_4bit
        ),
        BigBroModel(
            id: "gemma-4-e2b-vision",
            displayName: "Gemma 4 E2B (vision)",
            family: .vision,
            reasoning: .none,
            supportsTools: false,
            approximateGB: 3.0,
            configuration: VLMRegistry.gemma4_E2B_it_4bit
        ),
    ]

    // MARK: - Lookup

    static func model(id: String) -> BigBroModel? {
        all.first { $0.id == id }
    }

    /// Resolves a name a client sent in `model` to a catalog entry.
    ///
    /// Exact id first. Failing that, a loose match, because clients predate this catalog and
    /// send Ollama-style tags — `gpt-oss:20b` for `gpt-oss-20b`, `qwen3-vl:30b` for a Qwen VL
    /// model. Returns nil for a name that matches nothing, which callers report back as an
    /// error: BigBro has no default to fall back to, and answering a request for a model this
    /// Mac has never heard of with some *other* model would be a silent substitution the
    /// client could not detect.
    static func resolve(_ name: String) -> BigBroModel? {
        let normalized = normalize(name)
        if let exact = all.first(where: { normalize($0.id) == normalized }) { return exact }
        return all.first { normalize($0.id).hasPrefix(normalized) || normalized.hasPrefix(normalize($0.id)) }
    }

    /// Folds the punctuation clients vary on — `gpt-oss:20b`, `gpt_oss_20b`, `gpt-oss-20b` all
    /// collapse to the same key.
    private static func normalize(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
