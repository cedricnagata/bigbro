import Foundation

/// Turns a model's raw token stream back into the three things `AppRouter` forwards.
///
/// Necessary because models disagree about how to mark up a response, and `MLXLMCommon`
/// hands over whatever the tokenizer decoded without interpreting it. gpt-oss writes harmony
/// channel markers, Qwen3 writes `<think>` tags, Gemma and Llama write the answer and nothing
/// else. One parser cannot serve all three: running the harmony parser over plain output
/// withholds the opening of every reply while it waits for framing that never comes.
protocol ResponseParser: AnyObject {
    /// Feed newly-decoded text. Returns whatever became complete.
    func feed(_ text: String) -> [ParsedResponseEvent]
    /// Call once generation ends. Flushes anything still buffered.
    func finish() -> [ParsedResponseEvent]
}

enum ParsedResponseEvent {
    case reasoning(String)
    case delta(String)
    case toolCall(name: String, argumentsJSON: String)
}

extension ReasoningStyle {
    /// The parser this style needs. The pairing is fixed — a model's reasoning style *is* its
    /// output framing.
    func makeParser() -> ResponseParser {
        switch self {
        case .harmony:      return HarmonyStreamParser()
        case .thinkTags:    return ThinkTagParser()
        case .none:         return PlainTextParser()
        }
    }
}

// MARK: - Plain

/// Pass-through, for models with no reasoning phase and no channel markup.
///
/// Not merely a simplification — it is the correct behaviour. Everything the model emits is
/// the answer, so buffering any of it only delays the first token, which for a spoken reply
/// delays the first audible word.
final class PlainTextParser: ResponseParser {
    func feed(_ text: String) -> [ParsedResponseEvent] {
        text.isEmpty ? [] : [.delta(text)]
    }

    func finish() -> [ParsedResponseEvent] { [] }
}

// MARK: - Think tags

/// Splits a leading `<think>…</think>` block off the answer. Qwen3, DeepSeek-R1 distills.
///
/// Text inside the tags is streamed as `.reasoning` and text after them as `.delta`, both
/// incrementally — neither is held back waiting for a close tag, since the client renders
/// both as they arrive.
final class ThinkTagParser: ResponseParser {
    private static let openTag = "<think>"
    private static let closeTag = "</think>"

    private var buffer = ""
    private var insideThink = false
    /// Once the think block has closed, tag scanning stops: a later literal `<think>` in prose
    /// is content, not markup.
    private var thinkFinished = false

    func feed(_ text: String) -> [ParsedResponseEvent] {
        buffer += text
        return drain(isFinal: false)
    }

    func finish() -> [ParsedResponseEvent] {
        var events = drain(isFinal: true)
        if !buffer.isEmpty {
            events.append(insideThink ? .reasoning(buffer) : .delta(buffer))
            buffer = ""
        }
        return events
    }

    private func drain(isFinal: Bool) -> [ParsedResponseEvent] {
        var events: [ParsedResponseEvent] = []

        while !buffer.isEmpty {
            let tag = insideThink ? Self.closeTag : Self.openTag

            if thinkFinished {
                events.append(.delta(buffer))
                buffer = ""
                break
            }

            if let range = buffer.range(of: tag) {
                let before = String(buffer[buffer.startIndex..<range.lowerBound])
                if !before.isEmpty {
                    events.append(insideThink ? .reasoning(before) : .delta(before))
                }
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                if insideThink {
                    insideThink = false
                    thinkFinished = true
                } else {
                    insideThink = true
                }
                continue
            }

            // No tag in view. Emit everything that cannot be the start of one, and keep the
            // tail — a tag can straddle two chunks, and splitting it would leak `<thi` into
            // the answer and then fail to recognize the tag at all.
            let keep = Self.longestSuffixThatCouldStart(tag, in: buffer)
            let emitCount = buffer.count - keep
            if emitCount > 0 {
                let emitted = String(buffer.prefix(emitCount))
                events.append(insideThink ? .reasoning(emitted) : .delta(emitted))
                buffer.removeFirst(emitCount)
            }
            if isFinal { break }
            return events
        }

        return events
    }

    /// Length of the longest suffix of `text` that is a prefix of `tag`.
    private static func longestSuffixThatCouldStart(_ tag: String, in text: String) -> Int {
        let maxOverlap = min(tag.count - 1, text.count)
        guard maxOverlap > 0 else { return 0 }
        for length in stride(from: maxOverlap, through: 1, by: -1) {
            if tag.hasPrefix(text.suffix(length)) { return length }
        }
        return 0
    }
}

// MARK: - Harmony

/// Incrementally splits gpt-oss's harmony response format out of a raw text stream.
///
/// gpt-oss (like every OpenAI "harmony" model) writes its output as a sequence of channel
/// blocks rather than plain text:
///
///   <|channel|>analysis<|message|>...chain of thought...<|end|>
///   <|channel|>final<|message|>...the reply the user sees...
///   <|channel|>commentary to=functions.NAME <|constrain|>json<|message|>{...}<|call|>
///
/// `MLXLMCommon.generate` decodes tokens to text but has no gpt-oss-specific awareness of
/// these channels — mlx-swift-lm's tool-call parsers (`ToolCallFormat`) do not recognize
/// gpt-oss either (`infer()` returns nil for it), and `GPTOSSModel` itself is pure
/// transformer math with no channel logic. So the channel markers arrive as literal text in
/// `Generation.chunk`, same as any other token, and this type is what turns them back into
/// the three things `AppRouter` actually forwards: `.reasoning`, `.delta`, `.toolCall`.
///
/// This is the harmony hand-parser the design flagged as the highest-risk, most-likely-to-
/// change piece of the whole port: it depends on gpt-oss's special tokens surviving
/// detokenization as literal text. If a future mlx-swift-lm release strips them before
/// `.chunk` is emitted, this parser sees no `<|channel|>` markers at all and falls back to
/// treating everything as plain final-channel text (see `plainTextFallbackThreshold`) rather
/// than silently swallowing the whole response.
final class HarmonyStreamParser: ResponseParser {

    enum Channel {
        case analysis
        case final
        case commentary(recipient: String?)
    }

    private static let channelTag = "<|channel|>"
    private static let messageTag = "<|message|>"
    private static let terminators = ["<|end|>", "<|call|>", "<|return|>", "<|start|>"]

    /// If this many characters accumulate with no channel tag ever seen, give up on harmony
    /// framing and pass everything through as plain final-channel text. Guards against a
    /// future where special tokens no longer survive detokenization.
    private static let plainTextFallbackThreshold = 200

    private var buffer = ""
    private var currentChannel: Channel?
    private var sawChannelTag = false
    private var abandonedHarmonyFraming = false
    private var toolCallCounter = 0

    func feed(_ text: String) -> [ParsedResponseEvent] {
        buffer += text
        return drain(isFinal: false)
    }

    func finish() -> [ParsedResponseEvent] {
        drain(isFinal: true)
    }

    private func drain(isFinal: Bool) -> [ParsedResponseEvent] {
        var events: [ParsedResponseEvent] = []

        if abandonedHarmonyFraming {
            if !buffer.isEmpty {
                events.append(.delta(buffer))
                buffer = ""
            }
            return events
        }

        while true {
            if currentChannel == nil {
                guard let tagRange = buffer.range(of: Self.channelTag) else {
                    if !sawChannelTag, buffer.count >= Self.plainTextFallbackThreshold {
                        abandonedHarmonyFraming = true
                        events.append(.delta(buffer))
                        buffer = ""
                    }
                    break
                }
                sawChannelTag = true
                // Anything before the first channel tag isn't part of harmony framing —
                // in practice this is empty, since gpt-oss opens every turn with a tag.
                buffer.removeSubrange(buffer.startIndex..<tagRange.upperBound)

                guard let messageRange = buffer.range(of: Self.messageTag) else {
                    if isFinal { break }
                    // Header not fully arrived yet — wait for more text.
                    buffer = Self.channelTag + buffer
                    break
                }
                let header = String(buffer[buffer.startIndex..<messageRange.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                buffer.removeSubrange(buffer.startIndex..<messageRange.upperBound)
                currentChannel = Self.parseHeader(header)
                continue
            }

            guard let channel = currentChannel else { continue }

            let terminatorMatch = Self.terminators
                .compactMap { tag in buffer.range(of: tag).map { (tag, $0) } }
                .min { $0.1.lowerBound < $1.1.lowerBound }

            switch channel {
            case .analysis, .final:
                if let (_, range) = terminatorMatch {
                    let content = String(buffer[buffer.startIndex..<range.lowerBound])
                    if !content.isEmpty {
                        events.append(channel.isAnalysis ? .reasoning(content) : .delta(content))
                    }
                    buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                    currentChannel = nil
                    continue
                } else {
                    // Stream analysis/final text live rather than waiting for the
                    // terminator — these map to `.reasoning`/`.delta`, both of which the
                    // client displays incrementally as it arrives.
                    if !buffer.isEmpty {
                        events.append(channel.isAnalysis ? .reasoning(buffer) : .delta(buffer))
                        buffer = ""
                    }
                    if isFinal { currentChannel = nil }
                    return events
                }

            case .commentary(let recipient):
                if let (_, range) = terminatorMatch {
                    let content = String(buffer[buffer.startIndex..<range.lowerBound])
                    buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                    currentChannel = nil
                    if let recipient {
                        toolCallCounter += 1
                        events.append(.toolCall(name: recipient, argumentsJSON: content))
                    }
                    // Bare commentary (no `to=functions.X`) is user-visible preamble text,
                    // not a function call — drop it rather than speaking it aloud, since it
                    // isn't the model's final answer either.
                    continue
                } else if isFinal {
                    let content = buffer
                    buffer = ""
                    currentChannel = nil
                    if let recipient, !content.isEmpty {
                        toolCallCounter += 1
                        events.append(.toolCall(name: recipient, argumentsJSON: content))
                    }
                    continue
                } else {
                    // Tool call arguments must be complete, valid JSON — never emit partial.
                    return events
                }
            }
        }

        return events
    }

    private static func parseHeader(_ header: String) -> Channel {
        if header.hasPrefix("analysis") { return .analysis }
        if header.hasPrefix("final") { return .final }
        if header.hasPrefix("commentary") {
            if let range = header.range(of: "to=functions.") {
                let rest = header[range.upperBound...]
                let name = rest.prefix { !$0.isWhitespace && $0 != "<" }
                return .commentary(recipient: name.isEmpty ? nil : String(name))
            }
            return .commentary(recipient: nil)
        }
        // Unrecognized channel name — treat as final so the content isn't lost.
        return .final
    }
}

extension HarmonyStreamParser.Channel {
    var isAnalysis: Bool {
        if case .analysis = self { return true }
        return false
    }
}
