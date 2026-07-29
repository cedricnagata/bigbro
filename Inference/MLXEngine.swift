import Foundation
import Combine
import CoreImage
import MLX
import MLXLLM
import MLXVLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

// MARK: - Shared error / event types

enum InferenceError: Error, LocalizedError {
    case invalidImage(messageIndex: Int)
    case modelNotSelected(capability: String)
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidImage(let index):
            return "Message \(index) included an image that could not be decoded."
        case .modelNotSelected(let capability):
            return "No \(capability) model is selected. Pick one in BigBro Settings → Speech."
        case .generationFailed(let message):
            return message
        }
    }
}

/// One event from an inference response. Unchanged from the OpenAI-proxy era — this is the
/// seam `AppRouter` forwards over the (also unchanged) peer wire protocol, so nothing on the
/// client side needs to know the backend swapped out from under it.
enum InferenceEvent {
    case delta(String)
    case reasoning(String)
    case toolCalls([[String: Any]])
}

/// Runs gpt-oss-20b (text) and Qwen2.5-VL-3B (vision) in-process via MLX, replacing the
/// Ollama/LocalAI OpenAI-compatible proxy. Both models can stay resident at once — roughly
/// 12 GB + 2 GB — so unlike little-chef (a phone app, one model at a time) this never evicts
/// one to make room for the other.
@MainActor
final class MLXEngine: ObservableObject, BackendStatusReporting {
    static let shared = MLXEngine()

    enum ModelKind: String, CaseIterable {
        case text
        case vision

        var configuration: ModelConfiguration {
            switch self {
            case .text:   return LLMRegistry.gpt_oss_20b_MXFP4_Q8
            case .vision: return VLMRegistry.qwen2_5VL3BInstruct4Bit
            }
        }

        var displayName: String {
            switch self {
            case .text:   return "gpt-oss-20b"
            case .vision: return "Qwen2.5-VL-3B"
            }
        }

        fileprivate var readyDefaultsKey: String { "bigbro.modelReady.\(rawValue)" }

        /// Maps a legacy Ollama-style declared name (`gpt-oss:20b`, `qwen3-vl:30b`) onto
        /// whichever local model it plausibly refers to — the only signal such a name gives
        /// us now that there are exactly two fixed models. The one heuristic every other
        /// name-to-capability decision in the app (routing, missing-model checks, download
        /// progress lookups) goes through, so they can never drift apart.
        static func matching(declaredName name: String) -> ModelKind {
            name.lowercased().contains("vl") ? .vision : .text
        }
    }

    @Published private(set) var loadProgress: [ModelKind: Double] = [:]
    @Published private(set) var loadErrors: [ModelKind: String] = [:]

    private var containers: [ModelKind: ModelContainer] = [:]
    private var loadingTasks: [ModelKind: Task<ModelContainer, Error>] = [:]

    private init() {
        // little-chef's 20 MB cache limit exists to avoid phone jetsam under memory
        // pressure; nothing like that applies here, and two resident models benefit from
        // MLX being able to actually cache buffers between requests.
        MLX.Memory.cacheLimit = 512 * 1024 * 1024
    }

    // MARK: - BackendStatusReporting

    /// The backend is in-process, so there is no "unreachable" — it either has models ready
    /// or it doesn't. `detailItems` carries the real state.
    var status: BackendStatus { .running }

    var runningSummary: String {
        let ready = ModelKind.allCases.filter { isLoaded($0) }.count
        return "Running (\(ready)/\(ModelKind.allCases.count) model\(ModelKind.allCases.count == 1 ? "" : "s") loaded)"
    }

    var detailItems: [String] {
        ModelKind.allCases.map { "\($0.displayName): \(stateDescription($0))" }
    }

    var unreachableHint: String { "" }

    private func stateDescription(_ kind: ModelKind) -> String {
        if isLoaded(kind) { return "loaded" }
        if let error = loadErrors[kind] { return "error: \(error)" }
        if let p = loadProgress[kind] { return "downloading \(Int((p * 100).rounded()))%" }
        if isDownloaded(kind) { return "downloaded" }
        return "not downloaded"
    }

    // MARK: - Model lifecycle

    func isLoaded(_ kind: ModelKind) -> Bool { containers[kind] != nil }

    /// Best-effort "has this been downloaded" check, deliberately *not* a cache-path guess.
    /// little-chef's `isModelDownloaded` inspects the Hub cache directory directly and will
    /// happily report a half-finished download as present. Here, "downloaded" only becomes
    /// true once a load has actually completed — mlx-swift-lm's own downloader is the
    /// authority on whether cached files are complete, and re-running it after a genuine
    /// prior success is a fast cache hit, not a re-download.
    func isDownloaded(_ kind: ModelKind) -> Bool {
        isLoaded(kind) || UserDefaults.standard.bool(forKey: kind.readyDefaultsKey)
    }

    @discardableResult
    func ensureLoaded(_ kind: ModelKind, onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> ModelContainer {
        if let container = containers[kind] { return container }
        if let existing = loadingTasks[kind] { return try await existing.value }

        let task = Task<ModelContainer, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            do {
                let progressHandler: @Sendable (Progress) -> Void = { progress in
                    Task { @MainActor in
                        self.loadProgress[kind] = progress.fractionCompleted
                        onProgress?(progress.fractionCompleted)
                    }
                }
                let container: ModelContainer
                switch kind {
                case .text:
                    container = try await LLMModelFactory.shared.loadContainer(
                        from: #hubDownloader(),
                        using: #huggingFaceTokenizerLoader(),
                        configuration: kind.configuration,
                        progressHandler: progressHandler
                    )
                case .vision:
                    container = try await VLMModelFactory.shared.loadContainer(
                        from: #hubDownloader(),
                        using: #huggingFaceTokenizerLoader(),
                        configuration: kind.configuration,
                        progressHandler: progressHandler
                    )
                }
                await MainActor.run {
                    self.containers[kind] = container
                    self.loadProgress[kind] = 1.0
                    self.loadErrors[kind] = nil
                    self.loadingTasks[kind] = nil
                    UserDefaults.standard.set(true, forKey: kind.readyDefaultsKey)
                }
                return container
            } catch {
                await MainActor.run {
                    self.loadErrors[kind] = error.localizedDescription
                    self.loadingTasks[kind] = nil
                }
                throw error
            }
        }
        loadingTasks[kind] = task
        return try await task.value
    }

    // MARK: - Chat

    /// Which capability a request needs, decided purely by whether any message carries
    /// images — never by the `model` name the client asked for. BigBroKit clients predate
    /// this backend and pass Ollama-style tags (`gpt-oss:20b`, `qwen3-vl:30b`); routing on
    /// content rather than name means those names never need to match anything real.
    func kind(for messages: [[String: Any]]) -> ModelKind {
        let hasImages = messages.contains { ($0["images"] as? [String])?.isEmpty == false }
        return hasImages ? .vision : .text
    }

    /// True if the capability a request would need is ready to use without first triggering
    /// a multi-gigabyte download. Named model strings from the client (see `kind(for:)`) are
    /// mapped onto that same capability using a "does the name mention vision" heuristic —
    /// the only signal a legacy Ollama-style name gives us — so existing clients' `hello`
    /// required-model lists still produce a sensible missing/ready state.
    func isRequiredModelSatisfied(_ name: String) -> Bool {
        isDownloaded(.matching(declaredName: name))
    }

    func chatStream(
        messages rawMessages: [[String: Any]],
        tools rawTools: [[String: Any]],
        options: [String: Any]?
    ) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let kind = self.kind(for: rawMessages)
                    let chatMessages = try Self.chatMessages(from: rawMessages)
                    let toolSpecs = Self.toolSpecs(from: rawTools)

                    let container = try await self.ensureLoaded(kind)
                    let userInput = UserInput(chat: chatMessages, tools: toolSpecs)
                    let parameters = Self.generateParameters(from: options)

                    let stream: AsyncStream<Generation> = try await container.perform { (context: ModelContext) in
                        let lmInput = try await context.processor.prepare(input: userInput)
                        return try MLXLMCommon.generate(input: lmInput, parameters: parameters, context: context)
                    }

                    let harmony = HarmonyStreamParser()
                    for await generation in stream {
                        switch generation {
                        case .chunk(let text):
                            for event in harmony.feed(text) {
                                continuation.yield(Self.inferenceEvent(from: event))
                            }
                        case .toolCall(let call):
                            continuation.yield(.toolCalls([Self.toolCallDict(call)]))
                        case .info:
                            break
                        @unknown default:
                            break
                        }
                    }
                    for event in harmony.finish() {
                        continuation.yield(Self.inferenceEvent(from: event))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private static func inferenceEvent(from event: HarmonyStreamParser.ParsedEvent) -> InferenceEvent {
        switch event {
        case .reasoning(let text):
            return .reasoning(text)
        case .delta(let text):
            return .delta(text)
        case .toolCall(let name, let argumentsJSON):
            let arguments = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
            return .toolCalls([[
                "id": "call_\(UUID().uuidString.prefix(8))",
                "type": "function",
                "function": ["name": name, "arguments": arguments],
            ]])
        }
    }

    private static func toolCallDict(_ call: ToolCall) -> [String: Any] {
        [
            "id": call.id ?? "call_\(UUID().uuidString.prefix(8))",
            "type": "function",
            "function": [
                "name": call.function.name,
                "arguments": call.function.arguments.mapValues { $0.anyValue },
            ],
        ]
    }

    // MARK: - Generation parameters

    /// Only `maxTokens` and `temperature` are wired in little-chef; this maps the rest of
    /// `GenerationOptions` where `GenerateParameters` has an equivalent (`topK`, `topP`,
    /// `seed`, the three penalties) and silently drops what has none (`num_ctx`, `num_thread`,
    /// `stop`) — the same "forward what maps, ignore what can't" discipline the OpenAI proxy
    /// used for its own backend extensions.
    private static func generateParameters(from options: [String: Any]?) -> GenerateParameters {
        var parameters = GenerateParameters()
        guard let options else { return parameters }
        if let v = options["num_predict"] as? Int          { parameters.maxTokens = v }
        if let v = options["temperature"] as? Double        { parameters.temperature = Float(v) }
        if let v = options["top_k"] as? Int                 { parameters.topK = v }
        if let v = options["top_p"] as? Double              { parameters.topP = Float(v) }
        if let v = options["seed"] as? Int                  { parameters.seed = UInt64(v) }
        if let v = options["repeat_penalty"] as? Double     { parameters.repetitionPenalty = Float(v) }
        if let v = options["presence_penalty"] as? Double   { parameters.presencePenalty = Float(v) }
        if let v = options["frequency_penalty"] as? Double  { parameters.frequencyPenalty = Float(v) }
        return parameters
    }

    // MARK: - Message translation (Ollama-shape → Chat.Message)

    /// Translates the Ollama-shaped messages BigBroKit sends into MLXLMCommon's `Chat.Message`.
    /// Simpler than the old OpenAI translation: no tool-call id synthesis is needed for the
    /// wire format itself, only to correlate a `tool` message back to the assistant call it
    /// answers, since Ollama shape addresses that by `tool_name` rather than an id.
    private static func chatMessages(from raw: [[String: Any]]) throws -> [Chat.Message] {
        var messages: [Chat.Message] = []
        var callIdsByName: [String: String] = [:]

        for (i, msg) in raw.enumerated() {
            let role = msg["role"] as? String ?? "user"
            let content = msg["content"] as? String ?? ""

            switch role {
            case "system":
                messages.append(.system(content))

            case "user":
                let rawImages = msg["images"] as? [String] ?? []
                var images: [UserInput.Image] = []
                for base64 in rawImages {
                    guard let data = Data(base64Encoded: base64), let ciImage = CIImage(data: data) else {
                        throw InferenceError.invalidImage(messageIndex: i)
                    }
                    images.append(.ciImage(ciImage))
                }
                messages.append(.user(content, images: images))

            case "assistant":
                callIdsByName.removeAll()
                var toolCalls: [ToolCall]? = nil
                if let rawCalls = msg["tool_calls"] as? [[String: Any]] {
                    var calls: [ToolCall] = []
                    for (j, call) in rawCalls.enumerated() {
                        guard let fn = call["function"] as? [String: Any],
                              let name = fn["name"] as? String else { continue }
                        let id = (call["id"] as? String) ?? "call_\(i)_\(j)"
                        callIdsByName[name] = id
                        let arguments = argumentsObject(fn["arguments"])
                        calls.append(ToolCall(function: .init(name: name, arguments: arguments), id: id))
                    }
                    if !calls.isEmpty { toolCalls = calls }
                }
                messages.append(.assistant(content, toolCalls: toolCalls))

            case "tool":
                let name = msg["tool_name"] as? String
                let id = name.flatMap { callIdsByName[$0] }
                messages.append(.tool(content, id: id))

            default:
                messages.append(.user(content))
            }
        }
        return messages
    }

    private static func toolSpecs(from raw: [[String: Any]]) -> [ToolSpec]? {
        guard !raw.isEmpty else { return nil }
        return raw.map { dict in
            var spec: ToolSpec = [:]
            for (key, value) in dict { spec[key] = sendable(value) }
            return spec
        }
    }

    private static func argumentsObject(_ value: Any?) -> [String: any Sendable] {
        guard let dict = value as? [String: Any] else { return [:] }
        var out: [String: any Sendable] = [:]
        for (key, v) in dict { out[key] = sendable(v) }
        return out
    }

    private static func sendable(_ value: Any) -> any Sendable {
        switch value {
        case let v as Bool:            return v
        case let v as Int:             return v
        case let v as Double:          return v
        case let v as String:          return v
        case let v as [Any]:           return v.map { sendable($0) }
        case let v as [String: Any]:
            var out: [String: any Sendable] = [:]
            for (k, x) in v { out[k] = sendable(x) }
            return out
        default:
            return "\(value)"
        }
    }
}
