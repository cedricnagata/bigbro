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
    case generationFailed(String)
    case unknownModel(String)

    var errorDescription: String? {
        switch self {
        case .invalidImage(let index):
            return "Message \(index) included an image that could not be decoded."
        case .generationFailed(let message):
            return message
        case .unknownModel(let name):
            return "'\(name)' is not a model BigBro knows about."
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

/// What was actually done with a request, once the model's capabilities were taken into
/// account. Reported alongside the stream so `AppRouter` can tell the client what it did not
/// get, rather than leaving it to infer from an answer that quietly ignored half the request.
struct ResolvedRequest: Sendable {
    let model: BigBroModel
    /// True when tools were dropped because the model cannot call them.
    let droppedTools: Bool
    /// True when a `reasoning_effort` was dropped because the model has no effort control.
    let droppedReasoningEffort: Bool
    /// Set when images forced a different model than the one asked for.
    let substitutedForImages: Bool
}

/// Runs MLX models in-process, replacing the Ollama/LocalAI OpenAI-compatible proxy.
///
/// Any model in `ModelCatalog` can be downloaded and run, and more than one can stay resident
/// at once — the Mac has the memory for a 12 GB text model and a 2 GB vision model together,
/// so unlike a phone app there is no need to evict one to make room for the other. Containers
/// are keyed by model id and never evicted; a Mac that loads several large models will hold
/// them all.
@MainActor
final class MLXEngine: ObservableObject, BackendStatusReporting {
    static let shared = MLXEngine()

    @Published private(set) var loadProgress: [String: Double] = [:]
    @Published private(set) var loadErrors: [String: String] = [:]

    private var containers: [String: ModelContainer] = [:]
    private var runTasks: [String: Task<ModelContainer, Error>] = [:]
    private var downloadTasks: [String: Task<URL, Error>] = [:]

    /// Bumped whenever a model's lifecycle state changes.
    ///
    /// `state(_:)` is computed from the dictionaries above plus a UserDefaults record, none of
    /// which SwiftUI can observe. Without this a row would show whatever state it was built
    /// with and never update — a model would appear to stay "starting" forever after it had
    /// actually started.
    @Published private var stateRevision = 0

    private func stateChanged() { stateRevision &+= 1 }

    private init() {
        // little-chef's 20 MB cache limit exists to avoid phone jetsam under memory
        // pressure; nothing like that applies here, and resident models benefit from MLX
        // being able to actually cache buffers between requests.
        MLX.Memory.cacheLimit = 512 * 1024 * 1024
    }

    // MARK: - Selection

    /// The model used when a request names none, or names one this Mac does not have.
    var defaultTextModel: BigBroModel {
        ModelCatalog.model(id: AppSettings.shared.textModelID) ?? ModelCatalog.defaultText
    }

    var defaultVisionModel: BigBroModel {
        ModelCatalog.model(id: AppSettings.shared.visionModelID) ?? ModelCatalog.defaultVision
    }

    // MARK: - BackendStatusReporting

    /// The backend is in-process, so there is no "unreachable" — it either has models ready
    /// or it doesn't. `detailItems` carries the real state.
    var status: BackendStatus { .running }

    var runningSummary: String {
        let running = containers.count
        let downloaded = ModelCatalog.all.filter { isDownloaded($0.id) }.count
        return "\(running) running, \(downloaded) downloaded"
    }

    var detailItems: [String] {
        // Only models the user has some relationship with — listing every catalog entry as
        // "not downloaded" would bury the two or three that matter.
        ModelCatalog.all
            .filter { state($0.id) != .notDownloaded }
            .map { "\($0.displayName): \(state($0.id).description)" }
    }

    var unreachableHint: String { "" }

    // MARK: - Model state

    /// Where a model is in its lifecycle.
    ///
    /// Downloaded and running are genuinely different states, not two names for one: a 12 GB
    /// model on disk costs nothing until its weights are materialized into memory, and that
    /// step is both slow and expensive enough that the user needs to see and control it
    /// separately from the download.
    enum ModelRunState: Equatable {
        /// Not on disk.
        case notDownloaded
        /// Fetching weights. Fraction complete.
        case downloading(Double)
        /// On disk, using no memory. Ready to start quickly.
        case downloaded
        /// On disk, materializing weights into memory.
        case starting
        /// Resident in memory and ready to answer.
        case running
        case failed(String)

        var description: String {
            switch self {
            case .notDownloaded:        return "not downloaded"
            case .downloading(let p):   return "downloading \(Int((p * 100).rounded()))%"
            case .downloaded:           return "downloaded"
            case .starting:             return "starting"
            case .running:              return "running"
            case .failed(let message):  return "error: \(message)"
            }
        }
    }

    func state(_ id: String) -> ModelRunState {
        if containers[id] != nil { return .running }
        if let error = loadErrors[id] { return .failed(error) }
        if runTasks[id] != nil { return isDownloaded(id) ? .starting : .downloading(loadProgress[id] ?? 0) }
        if let progress = loadProgress[id], downloadTasks[id] != nil { return .downloading(progress) }
        if downloadTasks[id] != nil { return .downloading(0) }
        return isDownloaded(id) ? .downloaded : .notDownloaded
    }

    func isRunning(_ id: String) -> Bool { containers[id] != nil }

    func isBusy(_ id: String) -> Bool { runTasks[id] != nil || downloadTasks[id] != nil }

    /// Whether the weights are on disk.
    ///
    /// Checks that the directory mlx-swift-lm reported after a completed download still
    /// exists, rather than trusting a "was downloaded once" flag. Deliberately not a guess at
    /// the Hub cache layout — the path is only ever one the downloader itself returned — but
    /// checking it does mean a cache cleared behind BigBro's back reads as gone rather than as
    /// present-and-broken.
    func isDownloaded(_ id: String) -> Bool {
        if containers[id] != nil { return true }
        guard let path = downloadedPaths[id] else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    // MARK: - Lifecycle

    /// Fetches a model's weights to disk without materializing them into memory.
    ///
    /// Split from `run` because they cost different things: downloading is bandwidth and disk,
    /// running is RAM. Bundling them — which is what happens if you only ever call
    /// `loadContainer` — means pulling a 12 GB model from Settings also pins 12 GB of memory
    /// the user never asked to spend.
    @discardableResult
    func download(
        _ model: BigBroModel,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let id = model.id
        if let existing = downloadTasks[id] { return try await existing.value }

        let task = Task<URL, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            do {
                let progressHandler: @Sendable (Progress) -> Void = { progress in
                    Task { @MainActor in
                        self.loadProgress[id] = progress.fractionCompleted
                        onProgress?(progress.fractionCompleted)
                    }
                }
                // `resolve` is the same call `loadContainer` makes internally, minus the part
                // that builds the model. It returns the directory it downloaded into, which is
                // the only trustworthy answer to "what would removing this delete".
                let resolved = try await MLXLMCommon.resolve(
                    configuration: model.configuration,
                    from: #hubDownloader(),
                    useLatest: false,
                    progressHandler: progressHandler
                )
                await MainActor.run {
                    self.recordDownload(id, directory: resolved.modelDirectory)
                    self.loadProgress[id] = 1.0
                    self.loadErrors[id] = nil
                    self.downloadTasks[id] = nil
                    self.stateChanged()
                }
                return resolved.modelDirectory
            } catch {
                await MainActor.run {
                    self.loadErrors[id] = error.localizedDescription
                    self.downloadTasks[id] = nil
                    self.stateChanged()
                }
                throw error
            }
        }
        downloadTasks[id] = task
        stateChanged()
        return try await task.value
    }

    /// Materializes a model's weights into memory so it can answer requests. Downloads first
    /// if needed.
    @discardableResult
    func run(
        _ model: BigBroModel,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> ModelContainer {
        let id = model.id
        if let container = containers[id] { return container }
        if let existing = runTasks[id] { return try await existing.value }

        let task = Task<ModelContainer, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            do {
                // Always through `download` first, even when the files are already cached: it
                // is a fast no-op in that case, and it is what records the directory that
                // `remove` later deletes.
                try await self.download(model, onProgress: onProgress)

                let progressHandler: @Sendable (Progress) -> Void = { progress in
                    Task { @MainActor in
                        self.loadProgress[id] = progress.fractionCompleted
                        onProgress?(progress.fractionCompleted)
                    }
                }
                let container: ModelContainer
                switch model.family {
                case .language:
                    container = try await LLMModelFactory.shared.loadContainer(
                        from: #hubDownloader(),
                        using: #huggingFaceTokenizerLoader(),
                        configuration: model.configuration,
                        progressHandler: progressHandler
                    )
                case .vision:
                    container = try await VLMModelFactory.shared.loadContainer(
                        from: #hubDownloader(),
                        using: #huggingFaceTokenizerLoader(),
                        configuration: model.configuration,
                        progressHandler: progressHandler
                    )
                }
                await MainActor.run {
                    self.containers[id] = container
                    self.loadProgress[id] = 1.0
                    self.loadErrors[id] = nil
                    self.runTasks[id] = nil
                    self.stateChanged()
                }
                return container
            } catch {
                await MainActor.run {
                    self.loadErrors[id] = error.localizedDescription
                    self.runTasks[id] = nil
                    self.stateChanged()
                }
                throw error
            }
        }
        runTasks[id] = task
        stateChanged()
        return try await task.value
    }

    /// Unloads a model from memory, keeping the download. Starting it again is fast — the
    /// weights are still on disk, only the materialization is repeated.
    func stop(_ id: String) {
        guard containers.removeValue(forKey: id) != nil else { return }
        loadProgress.removeValue(forKey: id)
        stateChanged()
        print("[MLXEngine] stopped \(id)")
        // Reclaim what the model was holding. MLX caches buffers between requests, and those
        // survive the container going away unless the cache is cleared.
        MLX.GPU.clearCache()
    }

    /// Deletes a model's downloaded weights. Stops it first if it is running.
    ///
    /// Only ever deletes a directory the downloader itself reported. A model whose path was
    /// never recorded — downloaded by a build before paths were tracked — has nothing safe to
    /// delete, so it is forgotten rather than guessed at, and the next run re-resolves it.
    func remove(_ model: BigBroModel) throws {
        let id = model.id
        stop(id)
        loadErrors.removeValue(forKey: id)
        loadProgress.removeValue(forKey: id)

        guard let path = downloadedPaths[id] else {
            print("[MLXEngine] remove \(id): no recorded download path, nothing deleted")
            forgetDownload(id)
            stateChanged()
            return
        }
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(at: url)
            print("[MLXEngine] removed \(id) from \(path)")
        }
        forgetDownload(id)
        stateChanged()
    }

    // MARK: - Download bookkeeping

    /// Catalog id → the directory the downloader put the weights in. Persisted because it is
    /// what makes removal possible across launches.
    private static let downloadedPathsKey = "bigbro.downloadedPaths"

    private var downloadedPaths: [String: String] {
        UserDefaults.standard.dictionary(forKey: Self.downloadedPathsKey) as? [String: String] ?? [:]
    }

    private func recordDownload(_ id: String, directory: URL) {
        var paths = downloadedPaths
        paths[id] = directory.path
        UserDefaults.standard.set(paths, forKey: Self.downloadedPathsKey)
    }

    private func forgetDownload(_ id: String) {
        var paths = downloadedPaths
        paths.removeValue(forKey: id)
        UserDefaults.standard.set(paths, forKey: Self.downloadedPathsKey)
        // Clear the flag older builds wrote, so a model removed here doesn't come back as
        // "downloaded" if that key is ever consulted again.
        UserDefaults.standard.removeObject(forKey: "bigbro.modelReady.\(id)")
    }

    // MARK: - Routing

    /// Picks the model for a request, honouring what the client asked for where possible.
    ///
    /// Images override the request's model choice. A language model handed an image cannot
    /// describe it — it has no vision tower and the image never reaches the prompt — so
    /// silently answering from the text alone would be worse than substituting a model that
    /// can actually see, which is what happens here.
    func resolve(
        requestedModel name: String?,
        messages: [[String: Any]],
        toolCount: Int = 0,
        reasoningEffort: String? = nil
    ) -> ResolvedRequest {
        let hasImages = messages.contains { ($0["images"] as? [String])?.isEmpty == false }
        let requested = name.flatMap { $0.isEmpty ? nil : ModelCatalog.resolve($0) }

        var model = requested ?? (hasImages ? defaultVisionModel : defaultTextModel)
        var substituted = false
        if hasImages && !model.supportsImages {
            model = defaultVisionModel
            substituted = true
        }
        return ResolvedRequest(
            model: model,
            droppedTools: toolCount > 0 && !model.supportsTools,
            droppedReasoningEffort: reasoningEffort != nil && !model.reasoning.acceptsEffort,
            substitutedForImages: substituted
        )
    }

    /// True if the capability a request would need is ready without first triggering a
    /// multi-gigabyte download. Used for the `hello` missing-model check, where a client
    /// declares the models it expects.
    func isRequiredModelSatisfied(_ name: String) -> Bool {
        guard let model = ModelCatalog.resolve(name) else {
            // A name matching nothing in the catalog cannot be "missing" in a way the user
            // could fix by downloading, so don't report it and don't offer to pull it.
            return true
        }
        return isDownloaded(model.id)
    }

    // MARK: - Chat

    /// Runs one request, adapting it to what the chosen model can actually do.
    ///
    /// Three capabilities are negotiated here rather than assumed, because getting any of
    /// them wrong fails quietly rather than loudly:
    ///
    ///   - **Tools.** A model whose chat template has no tools slot either throws when handed
    ///     tool definitions or drops them. Neither tells the caller anything, so tools are
    ///     removed before templating and the omission is reported back.
    ///   - **Reasoning effort.** `reasoning_effort` is meaningful only to harmony models. Put
    ///     into any other template it is an unused variable at best; for Qwen3 the equivalent
    ///     lever is `enable_thinking`, a different key with different semantics.
    ///   - **Output framing.** Each model's reasoning style decides how the raw stream is
    ///     parsed back apart. See `ResponseParser`.
    func chatStream(
        model: BigBroModel,
        messages rawMessages: [[String: Any]],
        tools rawTools: [[String: Any]],
        options: [String: Any]?,
        reasoningEffort: String? = nil,
        wantsThinking: Bool = true
    ) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let chatMessages = try Self.chatMessages(from: rawMessages)
                    let toolSpecs = model.supportsTools ? Self.toolSpecs(from: rawTools) : nil
                    if !model.supportsTools && !rawTools.isEmpty {
                        print("[MLXEngine] \(model.id) cannot call tools — dropped \(rawTools.count)")
                    }

                    let container = try await self.run(model)
                    let context = Self.templateContext(
                        for: model,
                        reasoningEffort: reasoningEffort,
                        wantsThinking: wantsThinking
                    )
                    let userInput = UserInput(chat: chatMessages, tools: toolSpecs, additionalContext: context)
                    let parameters = Self.generateParameters(from: options)

                    let stream: AsyncStream<Generation> = try await container.perform { (ctx: ModelContext) in
                        let lmInput = try await ctx.processor.prepare(input: userInput)
                        return try MLXLMCommon.generate(input: lmInput, parameters: parameters, context: ctx)
                    }

                    let parser = model.reasoning.makeParser()
                    for await generation in stream {
                        switch generation {
                        case .chunk(let text):
                            for event in parser.feed(text) {
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
                    for event in parser.finish() {
                        continuation.yield(Self.inferenceEvent(from: event))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Extra variables handed to the chat template, chosen per model.
    ///
    /// Passing the wrong key is not harmless. Templates are Jinja, and an unexpected variable
    /// is ignored — so a `reasoning_effort` sent to Qwen3 does nothing at all while looking
    /// like it worked. Each style gets only the key its own template defines.
    private static func templateContext(
        for model: BigBroModel,
        reasoningEffort: String?,
        wantsThinking: Bool
    ) -> [String: any Sendable]? {
        switch model.reasoning {
        case .harmony:
            // A string, because the harmony template interpolates it into the system message
            // as text: `Reasoning: <level>`. nil leaves the template's own default ("medium")
            // — gpt-oss always reasons, only the budget is adjustable.
            return reasoningEffort.map { ["reasoning_effort": $0] }

        case .thinkTags(let togglable):
            // A Bool, not the string "false" — these templates branch on
            // `{% if enable_thinking %}`, and Jinja treats any non-empty string as truthy, so
            // "false" would enable thinking while looking like it disabled it.
            guard togglable else { return nil }
            // Qwen3 has no effort dial, only on/off. "low" is the closest thing a caller can
            // say to "think less", so it maps onto the only lever the template has.
            let enabled = wantsThinking && reasoningEffort != "low"
            return ["enable_thinking": enabled]

        case .none:
            return nil
        }
    }

    private static func inferenceEvent(from event: ParsedResponseEvent) -> InferenceEvent {
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

    /// Maps `GenerationOptions` onto `GenerateParameters` where an equivalent exists (`topK`,
    /// `topP`, `seed`, the three penalties) and silently drops what has none (`num_ctx`,
    /// `num_thread`, `stop`) — the same "forward what maps, ignore what can't" discipline the
    /// OpenAI proxy used for its own backend extensions.
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
