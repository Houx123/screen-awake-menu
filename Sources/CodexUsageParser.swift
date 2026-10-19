import Foundation

/// Which Codex JSONL record family a usage sample came from.
///
/// Codex currently writes the *same* underlying token event twice: once as a
/// `token_usage_record` line (fields under `payload.usage` /
/// `payload.thread_token_usage`) and once as an `event_msg` line whose payload
/// type is `token_count` (fields under `payload.info.last_token_usage` /
/// `payload.info.total_token_usage`). Only one family may be counted for a
/// session, otherwise every token is counted twice.
enum CodexUsageSource: Hashable {
    case tokenUsageRecord
    case tokenCount
}

/// Raw, still-unnormalized sample decoded from a single JSONL line.
struct CodexUsageSample: Equatable {
    let timestamp: Date
    let source: CodexUsageSource
    /// Per-event delta carried by the record (`usage` / `last_token_usage`).
    let usage: CodexTokenUsage
    /// Whether the record actually contained a per-event usage object.
    let hasExplicitUsage: Bool
    /// Cumulative counter for the session/turn, when the record carries one.
    let cumulativeTotal: Int64?
}

enum CodexUsageParseOutcome: Equatable {
    case sample(CodexUsageSample)
    case notUsageRecord
    case malformed
}

enum CodexUsageParser {
    static let tokenUsageRecordType = "token_usage_record"
    static let eventMessageType = "event_msg"
    static let tokenCountType = "token_count"

    /// Fast pre-filter markers so large unrelated JSONL lines (for example
    /// image/tool payloads) are never handed to the JSON decoder.
    static let tokenUsageRecordMarker = Data("\"token_usage_record\"".utf8)
    static let tokenCountMarker = Data("\"token_count\"".utf8)

    static let timestampParser = CodexTimestampParser()

    /// Parses one JSONL line. Never throws: malformed input yields `.malformed`
    /// and unrelated records yield `.notUsageRecord`.
    static func parse(line: Data) -> CodexUsageParseOutcome {
        guard !line.isEmpty else { return .notUsageRecord }
        guard let object = try? JSONSerialization.jsonObject(with: line),
              let root = object as? [String: Any],
              let type = root["type"] as? String
        else {
            return .malformed
        }

        guard type == tokenUsageRecordType || type == eventMessageType else {
            return .notUsageRecord
        }

        guard let timestampString = root["timestamp"] as? String,
              let timestamp = timestampParser.date(from: timestampString)
        else {
            return .malformed
        }

        guard let payload = root["payload"] as? [String: Any] else {
            return .malformed
        }

        switch type {
        case tokenUsageRecordType:
            let usageDictionary = payload["usage"] as? [String: Any]
            let explicit = usageDictionary != nil
            let usage = CodexTokenUsage(dictionary: usageDictionary)
            let cumulative = cumulativeTotal(from: payload["thread_token_usage"])
                ?? cumulativeTotal(from: payload["turn_token_usage"])
            return .sample(
                CodexUsageSample(
                    timestamp: timestamp,
                    source: .tokenUsageRecord,
                    usage: usage,
                    hasExplicitUsage: explicit,
                    cumulativeTotal: cumulative
                )
            )
        case eventMessageType:
            guard (payload["type"] as? String) == tokenCountType else {
                return .notUsageRecord
            }
            let info = payload["info"] as? [String: Any]
            let usageDictionary = info?["last_token_usage"] as? [String: Any]
            let explicit = usageDictionary != nil
            let usage = CodexTokenUsage(dictionary: usageDictionary)
            let cumulative = cumulativeTotal(from: info?["total_token_usage"])
            return .sample(
                CodexUsageSample(
                    timestamp: timestamp,
                    source: .tokenCount,
                    usage: usage,
                    hasExplicitUsage: explicit,
                    cumulativeTotal: cumulative
                )
            )
        default:
            return .notUsageRecord
        }
    }

    private static func cumulativeTotal(from value: Any?) -> Int64? {
        guard let dictionary = value as? [String: Any] else { return nil }
        guard let total = CodexTokenUsage.intValue(dictionary["total_tokens"]), total >= 0 else {
            return nil
        }
        return total
    }
}

/// Parses the ISO-8601 timestamps Codex writes (`...T13:40:31.993Z`), with a
/// fallback for whole-second variants. Scans are serialized on one queue, so a
/// single cached formatter pair is safe here.
final class CodexTimestampParser {
    private let fractional: ISO8601DateFormatter
    private let plain: ISO8601DateFormatter

    init() {
        fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
    }

    func date(from string: String) -> Date? {
        fractional.date(from: string) ?? plain.date(from: string)
    }
}

/// Turns decoded samples for one session file into non-negative token deltas.
///
/// Rules:
/// * A per-event usage object is already a delta, so it is used as-is.
/// * When only a cumulative counter is available, the delta is computed against
///   the previous value for that source. A decrease (truncated/rotated file or
///   a counter reset) starts a new baseline and contributes the new value,
///   which is always non-negative.
/// * `token_usage_record` and `token_count` are kept apart; the former wins when
///   present so the same event is never counted from both families.
final class CodexSessionAccumulator {
    private var lastCumulative: [CodexUsageSource: Int64] = [:]
    private(set) var tokenUsageRecordEvents: [CodexUsageEvent] = []
    private(set) var tokenCountEvents: [CodexUsageEvent] = []

    /// Events to aggregate: prefer `token_usage_record` because it is the
    /// dedicated token family and always exists in current Codex builds.
    var events: [CodexUsageEvent] {
        tokenUsageRecordEvents.isEmpty ? tokenCountEvents : tokenUsageRecordEvents
    }

    var malformedLineCount = 0

    func reset() {
        lastCumulative.removeAll()
        tokenUsageRecordEvents.removeAll()
        tokenCountEvents.removeAll()
        malformedLineCount = 0
    }

    func ingest(_ sample: CodexUsageSample) {
        let delta = deltaUsage(for: sample)
        if let cumulative = sample.cumulativeTotal {
            lastCumulative[sample.source] = cumulative
        }

        let event = CodexUsageEvent(timestamp: sample.timestamp, usage: delta)
        switch sample.source {
        case .tokenUsageRecord:
            tokenUsageRecordEvents.append(event)
        case .tokenCount:
            tokenCountEvents.append(event)
        }
    }

    func ingest(line: Data) {
        switch CodexUsageParser.parse(line: line) {
        case .sample(let sample):
            ingest(sample)
        case .notUsageRecord:
            break
        case .malformed:
            malformedLineCount += 1
        }
    }

    func prune(before date: Date) {
        tokenUsageRecordEvents.removeAll { $0.timestamp < date }
        tokenCountEvents.removeAll { $0.timestamp < date }
    }

    /// Drops events at/after the window end (future/clock-skewed records).
    func prune(after date: Date) {
        tokenUsageRecordEvents.removeAll { $0.timestamp >= date }
        tokenCountEvents.removeAll { $0.timestamp >= date }
    }

    private func deltaUsage(for sample: CodexUsageSample) -> CodexTokenUsage {
        if sample.hasExplicitUsage {
            return sample.usage
        }
        guard let cumulative = sample.cumulativeTotal else {
            return sample.usage
        }

        let deltaTotal: Int64
        if let previous = lastCumulative[sample.source] {
            if cumulative >= previous {
                deltaTotal = cumulative - previous
            } else {
                // Counter reset (new turn, truncation, rotation): adopt the new
                // value as the baseline so the delta stays non-negative.
                deltaTotal = cumulative
            }
        } else {
            deltaTotal = cumulative
        }

        var usage = sample.usage
        usage.totalTokens = deltaTotal
        return usage
    }
}
